//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Darwin
import Foundation

actor ScanEngine {
    private enum ScanEngineError: LocalizedError {
        case missingRootNode

        var errorDescription: String? {
            switch self {
            case .missingRootNode:
                return "The scan could not assemble a root node."
            }
        }
    }

    private final class AtomicDirectorySummaryState {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var isAccessible = true
        var warnings: [ScanWarning] = []
        var countedHardLinkIdentities: Set<FileIdentity>

        init(countedHardLinkIdentities: Set<FileIdentity>) {
            self.countedHardLinkIdentities = countedHardLinkIdentities
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
    }

    private struct AtomicDirectorySummary {
        let allocatedSize: Int64
        let logicalSize: Int64
        let descendantFileCount: Int
        let isAccessible: Bool
        let warnings: [ScanWarning]
        let countedHardLinkIdentities: Set<FileIdentity>
    }

    private struct AtomicDirectoryProbeProfile {
        var observedFileCount = 0
        var observedDirectoryCount = 0
        var totalSampledLogicalSize: Int64 = 0
        var observedNodeDependencyLayout = false

        func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
            guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
            return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
        }
    }

    private struct AggregateStatsAccumulator {
        private(set) var fileCount = 0
        private(set) var directoryCount = 0
        private(set) var accessibleItemCount = 0
        private(set) var inaccessibleItemCount = 0

        mutating func include(_ node: FileNodeRecord, hasChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !hasChildren {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        func makeStats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    private typealias CancellationCheck = () throws -> Void

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    private struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let parentKey: Int
        let depth: Int
    }

    /// A child discovered during directory enumeration.
    /// `contentsOfDirectory` prefetches resource values, so carrying decoded metadata forward
    /// avoids asking each URL for the same values again when the child is scanned.
    private struct DirectoryEntry: Sendable {
        let url: URL
        let metadata: NodeMetadata?
    }

    /// A completed directory scan awaiting parent assembly.
    private struct CompletedDirScan {
        let node: FileNodeRecord?     // Leaves carry a node; traversable dirs are resolved in phase 2.
        let metadata: NodeMetadata
        let url: URL
        let isTraversable: Bool     // True if this was a directory we intended to traverse.
    }

    private let fileManager = FileManager.default
    private let scanResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    private let rootResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey
    ]
    private static let atomicSummaryResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    private static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)

    /// Thresholds for automatically summarizing directories with many small files.
    /// Directories exceeding BOTH thresholds are treated as atomic (not expanded).
    private enum AtomicDirectoryThresholds {
        /// Minimum file count to consider a directory for atomic treatment
        static let minFileCount = 5_000
        /// Maximum average file size (in bytes) to consider for atomic treatment
        /// Below this suggests files are tiny/cached/irrelevant (npm, caches, etc.)
        static let maxAverageFileSize: Int64 = 4_096  // 4 KB average
        /// Minimum depth at which atomic treatment applies
        /// (depth 0 = scan root, depth 1 = immediate children, etc.)
        static let minDepthForSummarization = 2
    }

    nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let snapshot = try await self.performScan(
                        target: target,
                        options: options,
                        continuation: continuation
                    )
                    continuation.yield(.finished(snapshot))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func performScan(
        target: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) throws -> ScanSnapshot {
        let startedAt = Date()
        var metrics = ScanMetrics()
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )

        let treeStore = try scanDirectory(
            target: target,
            includeVolumeDetails: true,
            options: options,
            behavior: behavior,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            emissionState: &emissionState
        )
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        continuation.yield(.progress(metrics))

        let snapshot = makeSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true,
            expectedTotalBytes: metrics.estimatedTotalBytes
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

    /// Scans a directory iteratively (no recursion) and returns a fully assembled flat tree.
    private func scanDirectory(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanBehavior,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> FileTreeStore {
        try Task.checkCancellation()
        let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }

        let rootMetadata = try metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()
        var countedHardLinkIdentities = Set<FileIdentity>()

        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, options: options) else {
            let leafResult = try makeLeafNode(
                url: target.url,
                metadata: rootMetadata,
                options: options,
                countedHardLinkIdentities: &countedHardLinkIdentities,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            applyLeafMetrics(leafResult.node, metrics: &metrics)
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            continuation.yield(.progress(metrics))
            return FileTreeStore(root: leafResult.node)
        }

        // Phase 1: Walk the tree iteratively, collecting completed nodes by key.
        // We use a stack for DFS. Each item knows its parent key and depth for assembly.
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(url: target.url, metadata: rootMetadata, parentKey: -1, depth: 0)
        ]
        // Maps a key to its completed result (leaf or assembled directory).
        var completedByKey: [Int: CompletedDirScan] = [:]
        // Maps parent key → child keys, built during phase 1.
        var childrenKeysByKey: [Int: [Int]] = [:]
        var nextKey = 0

        while let item = workStack.popLast() {
            try Task.checkCancellation()

            let itemKey = nextKey
            nextKey += 1

            // Register this child with its parent (skip root which has parentKey -1).
            if item.parentKey >= 0 {
                childrenKeysByKey[item.parentKey, default: []].append(itemKey)
            }

            let meta: NodeMetadata
            if let itemMetadata = item.metadata {
                meta = itemMetadata
            } else {
                do {
                    meta = try metadata(for: item.url)
                } catch {
                    recordUnavailableItem(
                        item,
                        itemKey: itemKey,
                        error: error,
                        metrics: &metrics,
                        warnings: &warnings,
                        continuation: continuation,
                        emissionState: &emissionState,
                        completedByKey: &completedByKey
                    )
                    continue
                }
            }
            metrics.currentPath = item.url.path

            if shouldTraverseDirectory(metadata: meta, options: options) {
                metrics.directoriesVisited += 1
                metrics.recalculateProgress()
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                do {
                    let childEntries = try contents(
                        of: item.url,
                        includeHiddenFiles: options.includeHiddenFiles,
                        behavior: behavior
                    )
                    metrics.discoveredItems += childEntries.count
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    // Check if this directory should be summarized as atomic (many small files)
                    let minFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
                    let maxAvgSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
                    let minDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
                    let isNodeDependencyLayout = isNodeDependencyLayoutDirectory(at: item.url)
                    let canProbeForAutoSummary =
                        item.depth >= minDepth ||
                        (item.depth >= 1 && isNodeDependencyLayout)
                    if options.autoSummarizeDirectories,
                       canProbeForAutoSummary,
                       let summary = try shouldSummarizeAsAtomicDirectory(
                           url: item.url,
                           childEntries: childEntries,
                           metadata: meta,
                           includeHiddenFiles: options.includeHiddenFiles,
                           treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                           isNodeDependencyLayout: isNodeDependencyLayout,
                           minFileCount: minFileCount,
                           maxAverageFileSize: maxAvgSize,
                           countedHardLinkIdentities: &countedHardLinkIdentities,
                           cancellationCheck: cancellationCheck,
                           metrics: &metrics,
                           continuation: continuation,
                           emissionState: &emissionState
                       ) {
                        // Treat as atomic: create a leaf node with summary stats
                        let atomicNode = FileNodeRecord(
                            id: item.url.path,
                            url: item.url,
                            name: ScanTarget.displayName(for: item.url),
                            isDirectory: true,
                            isSymbolicLink: false,
                            allocatedSize: max(meta.allocatedSize, summary.allocatedSize),
                            logicalSize: max(meta.logicalSize, summary.logicalSize),
                            descendantFileCount: summary.descendantFileCount,
                            lastModified: meta.lastModified,
                            isPackage: false,
                            isAccessible: summary.isAccessible,
                            isSynthetic: false,
                            isAutoSummarized: true
                        )
                        applyLeafMetrics(atomicNode, metrics: &metrics)
                        if !summary.warnings.isEmpty {
                            warnings.append(contentsOf: summary.warnings)
                            for warning in summary.warnings {
                                continuation.yield(.warning(warning))
                            }
                        }
                        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                        completedByKey[itemKey] = CompletedDirScan(
                            node: atomicNode,
                            metadata: meta,
                            url: item.url,
                            isTraversable: false
                        )
                        continue
                    }

                    // Enqueue children onto the stack. Each child records its parent key.
                    for childEntry in childEntries {
                        workStack.append(
                            ScanWorkItem(
                                url: childEntry.url,
                                metadata: childEntry.metadata,
                                parentKey: itemKey,
                                depth: item.depth + 1
                            )
                        )
                    }
                    // Register this directory so phase 2 can assemble it.
                    // childrenKeysByKey will be populated after the loop by scanning parentKey references.
                    completedByKey[itemKey] = CompletedDirScan(
                        node: nil,
                        metadata: meta,
                        url: item.url,
                        isTraversable: true
                    )
                } catch {
                    let warning = makeWarning(for: item.url, error: error)
                    warnings.append(warning)
                    continuation.yield(.warning(warning))
                    metrics.completedItems += 1
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    let inaccessibleNode = FileNodeRecord(
                        id: item.url.path,
                        url: item.url,
                        name: ScanTarget.displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: meta.isSymbolicLink,
                        allocatedSize: 0,
                        logicalSize: 0,
                        descendantFileCount: 0,
                        lastModified: meta.lastModified,
                        isPackage: meta.isPackage,
                        isAccessible: false,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                    completedByKey[itemKey] = CompletedDirScan(
                        node: inaccessibleNode,
                        metadata: meta,
                        url: item.url,
                        isTraversable: false
                    )
                    continue
                }
            } else {
                // Leaf node (file, symlink, or package-as-directory).
                let leafResult = try makeLeafNode(
                    url: item.url,
                    metadata: meta,
                    options: options,
                    countedHardLinkIdentities: &countedHardLinkIdentities,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
                applyLeafMetrics(leafResult.node, metrics: &metrics)
                if !leafResult.warnings.isEmpty {
                    warnings.append(contentsOf: leafResult.warnings)
                    for warning in leafResult.warnings {
                        continuation.yield(.warning(warning))
                    }
                }
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                completedByKey[itemKey] = CompletedDirScan(
                    node: leafResult.node,
                    metadata: meta,
                    url: item.url,
                    isTraversable: false
                )
            }
        }

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        let finalizationTotal = max(completedByKey.count, 1)
        let finalizationProgressInterval = 512
        var finalizedItems = 0
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var nodesByID: [String: FileNodeRecord] = [:]
        var aggregateStats = AggregateStatsAccumulator()
        resolvedNodeByKey.reserveCapacity(completedByKey.count)
        childIDsByID.reserveCapacity(completedByKey.count)
        parentIDByID.reserveCapacity(completedByKey.count)
        nodesByID.reserveCapacity(completedByKey.count)
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let completed = completedByKey.removeValue(forKey: key) else { continue }
            finalizedItems += 1

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey.removeValue(forKey: key) ?? []
                var childNodes: [FileNodeRecord] = []
                childNodes.reserveCapacity(childKeys.count)
                for (offset, childKey) in childKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    if let childNode = resolvedNodeByKey.removeValue(forKey: childKey) {
                        childNodes.append(childNode)
                    }
                }
                let sortedChildren = FileTreeStore.sortedChildren(childNodes)
                try Task.checkCancellation()
                let assembled = FileNodeRecord.directory(
                    id: completed.url.path,
                    url: completed.url,
                    name: ScanTarget.displayName(for: completed.url),
                    children: sortedChildren,
                    lastModified: completed.metadata.lastModified,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable,
                    childrenAreSorted: true
                )
                resolvedNodeByKey[key] = assembled
                if insertNode(
                    assembled,
                    into: &nodesByID,
                    warnings: &warnings,
                    continuation: continuation
                ) {
                    aggregateStats.include(assembled, hasChildren: !sortedChildren.isEmpty)
                }

                var sortedChildIDs: [String] = []
                sortedChildIDs.reserveCapacity(sortedChildren.count)
                for (offset, child) in sortedChildren.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    sortedChildIDs.append(child.id)
                    parentIDByID[child.id] = assembled.id
                }
                childIDsByID[assembled.id] = sortedChildIDs

                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            } else if let onlyChild = completed.node {
                // Leaf node or inaccessible directory: use the child directly.
                resolvedNodeByKey[key] = onlyChild
                if insertNode(
                    onlyChild,
                    into: &nodesByID,
                    warnings: &warnings,
                    continuation: continuation
                ) {
                    aggregateStats.include(onlyChild, hasChildren: false)
                }
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try Task.checkCancellation()
                metrics.recalculateProgress()
                continuation.yield(.progress(metrics))
            }
        }

        guard let rootNode = resolvedNodeByKey[0] else {
            throw ScanEngineError.missingRootNode
        }

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        return FileTreeStore(
            rootID: rootNode.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: aggregateStats.makeStats(root: rootNode)
        )
    }

    // MARK: - Helpers

    private func applyLeafMetrics(_ node: FileNodeRecord, metrics: inout ScanMetrics) {
        if node.isDirectory {
            if !node.isAutoSummarized {
                metrics.directoriesVisited += 1
            }
            metrics.filesVisited += node.descendantFileCount
        } else if !node.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered += node.allocatedSize
        metrics.completedItems += 1
    }

    private func adjustedAllocatedSize(
        for metadata: NodeMetadata,
        countedHardLinkIdentities: inout Set<FileIdentity>
    ) -> Int64 {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.linkCount > 1,
              let fileIdentity = metadata.fileIdentity else {
            return metadata.allocatedSize
        }

        guard countedHardLinkIdentities.insert(fileIdentity).inserted else {
            return 0
        }

        return metadata.allocatedSize
    }

    private func insertNode(
        _ node: FileNodeRecord,
        into nodesByID: inout [String: FileNodeRecord],
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) -> Bool {
        guard nodesByID[node.id] == nil else {
            let warning = ScanWarning(
                path: node.url.path,
                message: "A duplicate filesystem path was collapsed in the scan results.",
                category: .fileSystem
            )
            warnings.append(warning)
            continuation.yield(.warning(warning))
            return false
        }

        nodesByID[node.id] = node
        return true
    }

    private func recordUnavailableItem(
        _ item: ScanWorkItem,
        itemKey: Int,
        error: Error,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        completedByKey: inout [Int: CompletedDirScan]
    ) {
        let warning = makeWarning(for: item.url, error: error)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        completedByKey[itemKey] = CompletedDirScan(
            node: makeUnavailableNode(for: item.url),
            metadata: NodeMetadata(
                isDirectory: item.url.hasDirectoryPath,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: 0,
                allocatedSize: 0,
                lastModified: nil,
                isReadable: false,
                volumeUsedCapacity: nil,
                fileIdentity: nil,
                linkCount: 0
            ),
            url: item.url,
            isTraversable: false
        )
    }

    private func makeUnavailableNode(for url: URL) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: url.hasDirectoryPath,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? rootResourceKeys : scanResourceKeys
        let values = try url.resourceValues(forKeys: keys)
        return metadata(for: url, resourceValues: values, includeVolumeDetails: includeVolumeDetails)
    }

    private func metadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false
    ) -> NodeMetadata {
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        let isReadable = values.isReadable ?? false
        var fileIdentity = Self.fileIdentity(from: values.fileResourceIdentifier)
        var linkCount = values.linkCount.map(UInt64.init) ?? 1
        if shouldReadFileSystemIdentity(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount
        ) {
            let fileSystemInfo = fileSystemInfo(for: url)
            fileIdentity = fileIdentity ?? fileSystemInfo.identity
            linkCount = values.linkCount.map(UInt64.init) ?? fileSystemInfo.linkCount
        }
        let volumeUsedCapacity: Int64?
        if includeVolumeDetails,
           let totalCapacity = values.volumeTotalCapacity,
           let availableCapacity = values.volumeAvailableCapacity {
            volumeUsedCapacity = Int64(max(totalCapacity - availableCapacity, 0))
        } else {
            volumeUsedCapacity = nil
        }

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable,
            volumeUsedCapacity: volumeUsedCapacity,
            fileIdentity: fileIdentity,
            linkCount: linkCount
        )
    }

    private func shouldReadFileSystemIdentity(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        fileIdentity: FileIdentity?,
        linkCount: Int?
    ) -> Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        guard let linkCount else { return true }
        return linkCount > 1 && fileIdentity == nil
    }

    private func fileSystemInfo(for url: URL) -> (identity: FileIdentity?, linkCount: UInt64) {
        var fileStat = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        guard result == 0 else {
            return (nil, 0)
        }

        return (
            FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            UInt64(fileStat.st_nlink)
        )
    }

    private nonisolated static func fileIdentity(
        from resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> FileIdentity? {
        guard let identifierData = resourceIdentifier as? Data else { return nil }
        return FileIdentity(resourceIdentifier: identifierData)
    }

    private func contents(of url: URL, includeHiddenFiles: Bool, behavior: ScanBehavior) throws -> [DirectoryEntry] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let prefetchKeys = Self.shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            ? nil
            : Array(scanResourceKeys)
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: prefetchKeys,
            options: options
        )

        return contents.compactMap { childURL in
            guard Self.includedChildURL(childURL, under: url, behavior: behavior) else {
                return nil
            }

            return DirectoryEntry(
                url: childURL,
                metadata: try? metadata(
                    for: childURL,
                    resourceValues: childURL.resourceValues(forKeys: scanResourceKeys)
                )
            )
        }
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && ["/", "/System"].contains(parentURL.path)
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        let parentPath = parentURL.path
        let childName = childURL.lastPathComponent

        if parentPath == "/" && [".nofollow", ".resolve"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/" &&
            [".file", ".vol", "dev", "Volumes"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/System" &&
            childName == "Volumes" {
            return false
        }

        return true
    }

    private func makeFileNode(
        url: URL,
        metadata: NodeMetadata,
        countedHardLinkIdentities: inout Set<FileIdentity>
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: adjustedAllocatedSize(for: metadata, countedHardLinkIdentities: &countedHardLinkIdentities),
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func makeLeafNode(
        url: URL,
        metadata: NodeMetadata,
        options: ScanOptions,
        countedHardLinkIdentities: inout Set<FileIdentity>,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> (node: FileNodeRecord, warnings: [ScanWarning]) {
        try cancellationCheck()
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            return (
                makeFileNode(
                    url: url,
                    metadata: metadata,
                    countedHardLinkIdentities: &countedHardLinkIdentities
                ),
                []
            )
        }

        guard let summary = try summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            countedHardLinkIdentities: countedHardLinkIdentities,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else {
            return (
                makeFileNode(
                    url: url,
                    metadata: metadata,
                    countedHardLinkIdentities: &countedHardLinkIdentities
                ),
                []
            )
        }
        countedHardLinkIdentities = summary.countedHardLinkIdentities

        return (
            FileNodeRecord(
                id: url.path,
                url: url,
                name: ScanTarget.displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: metadata.lastModified,
                isPackage: true,
                isAccessible: metadata.isReadable && summary.isAccessible,
                isSynthetic: false,
                isAutoSummarized: false
            ),
            summary.warnings
        )
    }

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    private func shouldSummarizeAsAtomicDirectory(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        countedHardLinkIdentities: inout Set<FileIdentity>,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        guard !childEntries.isEmpty else { return nil }

        let immediateCandidate: Bool
        if childEntries.count >= minFileCount {
            immediateCandidate = try immediateChildrenSuggestAtomicDirectory(
                childEntries,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck
            )
        } else {
            immediateCandidate = false
        }

        let deepCandidate: Bool
        if immediateCandidate {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return nil
            }
            let profile = try descendantAtomicProbeProfile(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
        }

        guard deepCandidate else {
            return nil
        }

        // Sample suggests atomic treatment - do a fast full summary
        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            return try summarizeAtomicDirectory(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                countedHardLinkIdentities: &countedHardLinkIdentities,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        guard let summary = try summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            countedHardLinkIdentities: countedHardLinkIdentities,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else { return nil }
        countedHardLinkIdentities = summary.countedHardLinkIdentities
        return summary
    }

    private func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        // Sparse parents are cheaper to traverse normally; dense descendants can still summarize themselves.
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return childEntries.count >= minimumImmediateEntries
    }

    private func immediateChildrenSuggestAtomicDirectory(
        _ childEntries: [DirectoryEntry],
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        try cancellationCheck()
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        let sampleEntries = stride(from: 0, to: childEntries.count, by: step)
            .prefix(sampleSize)
            .map { childEntries[$0] }

        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for childEntry in sampleEntries {
            try cancellationCheck()
            guard let childMetadata = childEntry.metadata else {
                return false
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
                sampleFileCount += 1
            }
        }

        guard sampleFileCount > 0 else { return false }
        return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
    }

    private func descendantAtomicProbeProfile(
        at url: URL,
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()
        let probeKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: probeKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        }

        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount * 2)
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)

        for case let childURL as URL in enumerator {
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else { return profile }

            if isNodeDependencyLayoutDirectory(at: childURL) {
                profile.observedNodeDependencyLayout = true
            }

            do {
                let values = try childURL.resourceValues(forKeys: Set(probeKeys))
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                guard !isDirectory else {
                    profile.observedDirectoryCount += 1
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize += Int64(values.fileSize ?? 0)
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return profile
                }
            } catch {
                return profile
            }
        }

        return profile
    }

    private func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        let components = Self.normalizedPathComponents(for: url)
        guard let name = components.last else { return false }

        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@"), components.count >= 2 else { return false }
        let parentName = components[components.count - 2]
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    private nonisolated static func normalizedPathComponents(for url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.filter { component in
            component != "/" && !component.isEmpty
        }
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    private func summarizeAtomicDirectory(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        countedHardLinkIdentities: inout Set<FileIdentity>,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        let state = AtomicDirectorySummaryState(countedHardLinkIdentities: countedHardLinkIdentities)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)

        for (index, childEntry) in childEntries.enumerated() {
            try cancellationCheck()
            if index == 0 || index.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childEntry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            try accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }
        countedHardLinkIdentities = state.countedHardLinkIdentities

        return makeAtomicSummary(from: state)
    }

    private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws {
        try cancellationCheck()
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try summarizeAtomicDirectory(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    countedHardLinkIdentities: state.countedHardLinkIdentities,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        accumulateAtomicFile(metadata, into: state)
    }

    private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += summary.allocatedSize
        state.logicalSize += summary.logicalSize
        state.descendantFileCount += summary.descendantFileCount
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
        state.countedHardLinkIdentities = summary.countedHardLinkIdentities
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    private func summarizeAtomicDirectory(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        countedHardLinkIdentities: Set<FileIdentity>,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        let state = AtomicDirectorySummaryState(countedHardLinkIdentities: countedHardLinkIdentities)

        do {
            try cancellationCheck()
            let rootValues = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            updateAtomicAccessibility(rootValues.isReadable ?? false, in: state)
        } catch {
            recordAtomicWarning(for: url, error: error, in: state)
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.atomicSummaryResourceKeys,
            options: enumeratorOptions,
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(Self.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        var visitedItems = 0
        for case let childURL as URL in enumerator {
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            do {
                let childMetadata = try atomicSummaryMetadata(for: childURL)
                try accumulateEnumeratedAtomicSummary(
                    for: childURL,
                    metadata: childMetadata,
                    into: state,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState,
                    skipDescendants: {
                        enumerator.skipDescendants()
                    }
                )
            } catch {
                recordAtomicWarning(for: childURL, error: error, in: state)
            }
        }

        return makeAtomicSummary(from: state)
    }

    private func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
        let values = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
        return metadata(for: url, resourceValues: values)
    }

    private func accumulateEnumeratedAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        skipDescendants: () -> Void
    ) throws {
        try cancellationCheck()
        updateAtomicAccessibility(metadata.isReadable, in: state)

        guard metadata.isDirectory else {
            accumulateAtomicFile(metadata, into: state)
            return
        }

        guard metadata.isPackage, !treatPackagesAsDirectories else { return }

        if let packageSummary = try summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: true,
            countedHardLinkIdentities: state.countedHardLinkIdentities,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) {
            merge(packageSummary, into: state)
            skipDescendants()
        }
    }

    private func updateAtomicAccessibility(_ isReadable: Bool, in state: AtomicDirectorySummaryState) {
        state.isAccessible = state.isAccessible && isReadable
    }

    private func recordAtomicWarning(
        for url: URL,
        error: Error,
        in state: AtomicDirectorySummaryState
    ) {
        state.isAccessible = false
        state.warnings.append(Self.makeWarning(for: url, error: error))
    }

    private func accumulateAtomicFile(_ metadata: NodeMetadata, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += adjustedAllocatedSize(
            for: metadata,
            countedHardLinkIdentities: &state.countedHardLinkIdentities
        )
        state.logicalSize += metadata.logicalSize

        if !metadata.isSymbolicLink {
            state.descendantFileCount += 1
        }
    }

    private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings,
            countedHardLinkIdentities: state.countedHardLinkIdentities
        )
    }

    private func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        expectedTotalBytes: Int64 = 0
    ) -> ScanSnapshot {
        let reconciledStore = reconcileVolumeRoot(treeStore, for: target, expectedTotalBytes: expectedTotalBytes)

        return ScanSnapshot(
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: reconciledStore.aggregateStats,
            isComplete: isComplete
        )
    }

    private func reconcileVolumeRoot(_ treeStore: FileTreeStore, for target: ScanTarget, expectedTotalBytes: Int64) -> FileTreeStore {
        let root = treeStore.root
        guard target.kind == .volume, expectedTotalBytes > root.allocatedSize else {
            return treeStore
        }

        let missingBytes = expectedTotalBytes - root.allocatedSize
        guard missingBytes >= 64 * 1_024 * 1_024 else {
            return treeStore
        }

        let unattributedNode = FileNodeRecord(
            id: "\(root.id)#system-unattributed",
            url: target.url,
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: missingBytes,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )

        let rootChildren = treeStore.children(of: root.id) + [unattributedNode]
        let sortedRootChildren = FileTreeStore.sortedChildren(rootChildren)
        let reconciledRoot = FileNodeRecord.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: sortedRootChildren,
            lastModified: root.lastModified,
            isPackage: root.isPackage,
            isAccessible: root.isAccessible,
            childrenAreSorted: true
        )

        var nodesByID = treeStore.nodesByID
        nodesByID[reconciledRoot.id] = reconciledRoot
        nodesByID[unattributedNode.id] = unattributedNode

        var childIDsByID = treeStore.childIDsByID
        childIDsByID[root.id] = sortedRootChildren.map(\.id)

        var parentIDByID = treeStore.parentIDByID
        parentIDByID[unattributedNode.id] = root.id

        let baseStats = treeStore.aggregateStats
        let reconciledStats = ScanAggregateStats(
            totalAllocatedSize: reconciledRoot.allocatedSize,
            totalLogicalSize: reconciledRoot.logicalSize,
            fileCount: baseStats.fileCount,
            directoryCount: baseStats.directoryCount,
            accessibleItemCount: baseStats.accessibleItemCount + 1,
            inaccessibleItemCount: baseStats.inaccessibleItemCount
        )

        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: reconciledStats
        )
    }

    private func maybeEmitProgress(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000) || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }

    private func emitProgressHeartbeat(
        currentURL: URL,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        metrics.currentPath = currentURL.path
        let now = Date()
        guard now.timeIntervalSince(emissionState.lastProgressEmission) >= 0.15 else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }

    private func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
    }

    private func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        if target.kind == .volume, let volumeUsedCapacity = metadata.volumeUsedCapacity {
            return max(volumeUsedCapacity, metadata.allocatedSize)
        }
        return max(metadata.allocatedSize, 0)
    }

    private nonisolated static func makeWarning(for url: URL, error: Error) -> ScanWarning {
        let nsError = error as NSError
        let category: ScanWarningCategory

        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileReadNoPermissionError {
            category = .permissionDenied
        } else if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == EACCES || nsError.code == EPERM) {
            category = .permissionDenied
        } else {
            category = .fileSystem
        }

        return ScanWarning(
            path: url.path,
            message: nsError.localizedDescription,
            category: category
        )
    }

    private func makeWarning(for url: URL, error: Error) -> ScanWarning {
        Self.makeWarning(for: url, error: error)
    }
}

nonisolated private enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64)

    nonisolated init(device: UInt64, inode: UInt64) {
        self = .fileSystem(device: device, inode: inode)
    }

    nonisolated init(resourceIdentifier: Data) {
        self = .resourceIdentifier(resourceIdentifier)
    }
}

private struct NodeMetadata: Sendable {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeUsedCapacity: Int64?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
}

private struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
