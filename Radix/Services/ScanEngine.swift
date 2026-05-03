//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

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

    private final class AtomicDirectorySummaryState: @unchecked Sendable {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var isAccessible = true
        var warnings: [ScanWarning] = []
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
    }

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    private struct ScanWorkItem: Sendable {
        let url: URL
        let includeVolumeDetails: Bool
        let parentKey: Int
        let depth: Int
    }

    /// A completed directory scan awaiting parent assembly.
    private struct CompletedDirScan {
        let children: [FileNode]    // For leaves: the leaf node. For dirs: empty (resolved in phase 2).
        let metadata: NodeMetadata
        let url: URL
        let includeVolumeDetails: Bool
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
        .isReadableKey
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
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey
    ]

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
        var metrics = ScanMetrics(startedAt: startedAt)
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )

        let rootNode = try scanDirectory(
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
            root: rootNode,
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

    /// Scans a directory iteratively (no recursion) and returns a fully assembled `FileNode`.
    private func scanDirectory(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanBehavior,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> FileNode {
        try Task.checkCancellation()

        let rootMetadata = try metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()

        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, options: options) else {
            let leafResult = makeLeafNode(url: target.url, metadata: rootMetadata, options: options)
            applyLeafMetrics(leafResult.node, metrics: &metrics)
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            continuation.yield(.progress(metrics))
            return leafResult.node
        }

        // Phase 1: Walk the tree iteratively, collecting completed nodes by key.
        // We use a stack for DFS. Each item knows its parent key and depth for assembly.
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(url: target.url, includeVolumeDetails: true, parentKey: -1, depth: 0)
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
            if item.includeVolumeDetails {
                meta = rootMetadata // Already fetched for root
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
                    let childURLs = try contents(
                        of: item.url,
                        includeHiddenFiles: options.includeHiddenFiles,
                        behavior: behavior
                    )
                    metrics.discoveredItems += childURLs.count
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    // Check if this directory should be summarized as atomic (many small files)
                    let minFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
                    let maxAvgSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
                    let minDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
                    if options.autoSummarizeDirectories,
                       item.depth >= minDepth,
                       childURLs.count >= minFileCount,
                       let summary = try shouldSummarizeAsAtomicDirectory(
                           url: item.url,
                           childURLs: childURLs,
                           metadata: meta,
                           includeHiddenFiles: options.includeHiddenFiles,
                           maxAverageFileSize: maxAvgSize
                       ) {
                        // Treat as atomic: create a leaf node with summary stats
                        let atomicNode = FileNode(
                            id: item.url.path,
                            url: item.url,
                            name: displayName(for: item.url),
                            isDirectory: true,
                            isSymbolicLink: false,
                            allocatedSize: max(meta.allocatedSize, summary.allocatedSize),
                            logicalSize: max(meta.logicalSize, summary.logicalSize),
                            children: [],
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
                            children: [atomicNode],
                            metadata: meta,
                            url: item.url,
                            includeVolumeDetails: item.includeVolumeDetails,
                            isTraversable: false
                        )
                        continue
                    }

                    // Enqueue children onto the stack. Each child records its parent key.
                    for childURL in childURLs {
                        workStack.append(
                            ScanWorkItem(url: childURL, includeVolumeDetails: false, parentKey: itemKey, depth: item.depth + 1)
                        )
                    }
                    // Register this directory so phase 2 can assemble it.
                    // childrenKeysByKey will be populated after the loop by scanning parentKey references.
                    completedByKey[itemKey] = CompletedDirScan(
                        children: [],
                        metadata: meta,
                        url: item.url,
                        includeVolumeDetails: item.includeVolumeDetails,
                        isTraversable: true
                    )
                } catch {
                    let warning = makeWarning(for: item.url, error: error)
                    warnings.append(warning)
                    continuation.yield(.warning(warning))
                    metrics.inaccessibleDirectories += 1
                    metrics.completedItems += 1
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    let inaccessibleNode = FileNode(
                        id: item.url.path,
                        url: item.url,
                        name: displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: meta.isSymbolicLink,
                        allocatedSize: 0,
                        logicalSize: 0,
                        children: [],
                        descendantFileCount: 0,
                        lastModified: meta.lastModified,
                        isPackage: meta.isPackage,
                        isAccessible: false,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                    completedByKey[itemKey] = CompletedDirScan(
                        children: [inaccessibleNode],
                        metadata: meta,
                        url: item.url,
                        includeVolumeDetails: item.includeVolumeDetails,
                        isTraversable: false
                    )
                    continue
                }
            } else {
                // Leaf node (file, symlink, or package-as-directory).
                let leafResult = makeLeafNode(url: item.url, metadata: meta, options: options)
                applyLeafMetrics(leafResult.node, metrics: &metrics)
                if !leafResult.warnings.isEmpty {
                    warnings.append(contentsOf: leafResult.warnings)
                    for warning in leafResult.warnings {
                        continuation.yield(.warning(warning))
                    }
                }
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                completedByKey[itemKey] = CompletedDirScan(
                    children: [leafResult.node],
                    metadata: meta,
                    url: item.url,
                    includeVolumeDetails: item.includeVolumeDetails,
                    isTraversable: false
                )
            }
        }

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        var resolvedNodeByKey: [Int: FileNode] = [:]
        for key in (0..<nextKey).reversed() {
            guard let completed = completedByKey[key] else { continue }

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey[key] ?? []
                let childNodes = childKeys.compactMap { resolvedNodeByKey[$0] }
                let assembled = FileNode.directory(
                    id: completed.url.path,
                    url: completed.url,
                    name: displayName(for: completed.url),
                    children: childNodes,
                    lastModified: completed.metadata.lastModified,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable
                )
                resolvedNodeByKey[key] = assembled
            } else if let onlyChild = completed.children.first {
                // Leaf node or inaccessible directory: use the child directly.
                resolvedNodeByKey[key] = onlyChild
            }
        }

        guard let rootNode = resolvedNodeByKey[0] else {
            throw ScanEngineError.missingRootNode
        }

        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        return rootNode
    }

    // MARK: - Helpers

    private func applyLeafMetrics(_ node: FileNode, metrics: inout ScanMetrics) {
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
            children: [makeUnavailableNode(for: item.url)],
            metadata: NodeMetadata(
                isDirectory: item.url.hasDirectoryPath,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: 0,
                allocatedSize: 0,
                lastModified: nil,
                isReadable: false,
                volumeUsedCapacity: nil
            ),
            url: item.url,
            includeVolumeDetails: item.includeVolumeDetails,
            isTraversable: false
        )
    }

    private func makeUnavailableNode(for url: URL) -> FileNode {
        FileNode(
            id: url.path,
            url: url,
            name: displayName(for: url),
            isDirectory: url.hasDirectoryPath,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            children: [],
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
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        let isReadable = values.isReadable ?? false
        let volumeUsedCapacity: Int64?
        if let totalCapacity = values.volumeTotalCapacity,
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
            volumeUsedCapacity: volumeUsedCapacity
        )
    }

    private func contents(of url: URL, includeHiddenFiles: Bool, behavior: ScanBehavior) throws -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: options
        )

        return contents.filter { Self.includedChildURL($0, under: url, behavior: behavior) }
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        if parentURL.path == "/" && [".nofollow", ".resolve"].contains(childURL.lastPathComponent) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentURL.path == "/" &&
            childURL.lastPathComponent == "Volumes" {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentURL.path == "/System" &&
            childURL.lastPathComponent == "Volumes" {
            return false
        }

        return true
    }

    private func makeFileNode(url: URL, metadata: NodeMetadata) -> FileNode {
        FileNode(
            id: url.path,
            url: url,
            name: displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: metadata.allocatedSize,
            logicalSize: metadata.logicalSize,
            children: [],
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func makeLeafNode(url: URL, metadata: NodeMetadata, options: ScanOptions) -> (node: FileNode, warnings: [ScanWarning]) {
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            return (makeFileNode(url: url, metadata: metadata), [])
        }

        guard let summary = summarizeAtomicDirectory(at: url, includeHiddenFiles: options.includeHiddenFiles) else {
            return (makeFileNode(url: url, metadata: metadata), [])
        }

        return (
            FileNode(
                id: url.path,
                url: url,
                name: displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                children: [],
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
    /// Sampling uses the prefetched resource values on each `childURL` (set by `contentsOfDirectory`
    /// via `includingPropertiesForKeys`), so no additional per-file syscalls are needed.
    private func shouldSummarizeAsAtomicDirectory(
        url: URL,
        childURLs: [URL],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        maxAverageFileSize: Int64
    ) throws -> AtomicDirectorySummary? {
        // Quick check: sample files evenly across the directory to estimate average size.
        // childURLs already have scanResourceKeys prefetched by contentsOfDirectory,
        // so resourceValues(forKeys:) reads from the cached values without extra syscalls.
        let sampleSize = min(100, childURLs.count)
        let step = max(1, childURLs.count / sampleSize)
        let sampleURLs = stride(from: 0, to: childURLs.count, by: step).prefix(sampleSize).map { childURLs[$0] }

        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for childURL in sampleURLs {
            let values = try childURL.resourceValues(forKeys: scanResourceKeys)
            if !(values.isDirectory ?? false) {
                let fileSize = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)
                sampleTotalSize += fileSize
                sampleFileCount += 1
            }
        }

        // If sample suggests files are large on average, don't summarize
        guard sampleFileCount > 0 else { return nil }
        let avgFileSize = sampleTotalSize / Int64(sampleFileCount)
        guard avgFileSize <= maxAverageFileSize else {
            return nil
        }

        // Sample suggests atomic treatment - do a fast full summary
        return summarizeAtomicDirectory(at: url, includeHiddenFiles: includeHiddenFiles)
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    private func summarizeAtomicDirectory(
        at url: URL,
        includeHiddenFiles: Bool = true
    ) -> AtomicDirectorySummary? {
        let summaryKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isReadableKey
        ]

        let state = AtomicDirectorySummaryState()

        if let rootValues = try? url.resourceValues(forKeys: Set(summaryKeys)) {
            state.isAccessible = state.isAccessible && (rootValues.isReadable ?? false)
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: summaryKeys,
            options: enumeratorOptions,
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(Self.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        for case let childURL as URL in enumerator {
            do {
                let values = try childURL.resourceValues(forKeys: Set(summaryKeys))

                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                state.isAccessible = state.isAccessible && (values.isReadable ?? false)

                if !isDirectory {
                    let childAllocatedSize = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                    let childLogicalSize = Int64(values.fileSize ?? 0)

                    state.allocatedSize += childAllocatedSize
                    state.logicalSize += childLogicalSize

                    if !isSymbolicLink {
                        state.descendantFileCount += 1
                    }
                }
            } catch {
                state.isAccessible = false
                state.warnings.append(Self.makeWarning(for: childURL, error: error))
            }
        }

        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings
        )
    }

    private func makeSnapshot(
        target: ScanTarget,
        root: FileNode,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        expectedTotalBytes: Int64 = 0
    ) -> ScanSnapshot {
        let reconciledRoot = reconcileVolumeRoot(root, for: target, expectedTotalBytes: expectedTotalBytes)

        return ScanSnapshot(
            target: target,
            root: reconciledRoot,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: reconciledRoot.aggregateStats,
            isComplete: isComplete
        )
    }

    private func reconcileVolumeRoot(_ root: FileNode, for target: ScanTarget, expectedTotalBytes: Int64) -> FileNode {
        guard target.kind == .volume, expectedTotalBytes > root.allocatedSize else {
            return root
        }

        let missingBytes = expectedTotalBytes - root.allocatedSize
        guard missingBytes >= 64 * 1_024 * 1_024 else {
            return root
        }

        let unattributedNode = FileNode(
            id: "\(root.id)#system-unattributed",
            url: target.url,
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: missingBytes,
            children: [],
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )

        return FileNode.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: root.children + [unattributedNode],
            lastModified: root.lastModified,
            isPackage: root.isPackage,
            isAccessible: root.isAccessible
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

    private func displayName(for url: URL) -> String {
        if url.path == "/" {
            let values = try? url.resourceValues(forKeys: [.volumeNameKey])
            return values?.volumeName ?? "Startup Disk"
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
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

private struct NodeMetadata {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeUsedCapacity: Int64?
}

private struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
