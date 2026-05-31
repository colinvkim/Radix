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

    private final class AtomicDirectorySummaryState {
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
        let children: [FileNodeRecord]    // For leaves: the leaf node. For dirs: empty (resolved in phase 2).
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
                    if options.autoSummarizeDirectories,
                       item.depth >= minDepth,
                       childEntries.count >= minFileCount,
                       let summary = shouldSummarizeAsAtomicDirectory(
                           url: item.url,
                           childEntries: childEntries,
                           metadata: meta,
                           includeHiddenFiles: options.includeHiddenFiles,
                           treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                           maxAverageFileSize: maxAvgSize
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
                            children: [atomicNode],
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
                        children: [],
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
                        children: [inaccessibleNode],
                        metadata: meta,
                        url: item.url,
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
                    isTraversable: false
                )
            }
        }

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        for key in (0..<nextKey).reversed() {
            guard let completed = completedByKey[key] else { continue }

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey[key] ?? []
                let childNodes = childKeys.compactMap { resolvedNodeByKey[$0] }
                let sortedChildren = FileTreeStore.sortedChildren(childNodes)
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
                childIDsByID[assembled.id] = sortedChildren.map(\.id)
                for child in sortedChildren {
                    parentIDByID[child.id] = assembled.id
                }
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

        let nodesByID = Dictionary(uniqueKeysWithValues: resolvedNodeByKey.values.map { ($0.id, $0) })
        return FileTreeStore(
            rootID: rootNode.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
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

    private func contents(of url: URL, includeHiddenFiles: Bool, behavior: ScanBehavior) throws -> [DirectoryEntry] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: options
        )

        return contents.compactMap { childURL in
            guard Self.includedChildURL(childURL, under: url, behavior: behavior) else {
                return nil
            }

            return DirectoryEntry(
                url: childURL,
                metadata: try? metadata(for: childURL)
            )
        }
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

    private func makeFileNode(url: URL, metadata: NodeMetadata) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: metadata.allocatedSize,
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func makeLeafNode(url: URL, metadata: NodeMetadata, options: ScanOptions) -> (node: FileNodeRecord, warnings: [ScanWarning]) {
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            return (makeFileNode(url: url, metadata: metadata), [])
        }

        guard let summary = summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true
        ) else {
            return (makeFileNode(url: url, metadata: metadata), [])
        }

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
        maxAverageFileSize: Int64
    ) -> AtomicDirectorySummary? {
        guard !childEntries.isEmpty else { return nil }

        // Quick check: sample files evenly across the directory to estimate average size.
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        let sampleEntries = stride(from: 0, to: childEntries.count, by: step)
            .prefix(sampleSize)
            .map { childEntries[$0] }

        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for childEntry in sampleEntries {
            guard let childMetadata = childEntry.metadata else {
                return nil
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
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
        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            return summarizeAtomicDirectory(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories
            )
        }

        return summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories
        )
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    private func summarizeAtomicDirectory(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool
    ) -> AtomicDirectorySummary? {
        let state = AtomicDirectorySummaryState()
        state.isAccessible = rootMetadata.isReadable

        for childEntry in childEntries {
            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadata(for: childEntry.url)
                } catch {
                    state.isAccessible = false
                    state.warnings.append(Self.makeWarning(for: childEntry.url, error: error))
                    continue
                }
            }

            accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories
            )
        }

        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings
        )
    }

    private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool
    ) {
        state.isAccessible = state.isAccessible && metadata.isReadable

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = summarizeAtomicDirectory(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        state.allocatedSize += metadata.allocatedSize
        state.logicalSize += metadata.logicalSize

        if !metadata.isSymbolicLink {
            state.descendantFileCount += 1
        }
    }

    private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += summary.allocatedSize
        state.logicalSize += summary.logicalSize
        state.descendantFileCount += summary.descendantFileCount
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    private func summarizeAtomicDirectory(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool
    ) -> AtomicDirectorySummary? {
        let summaryKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isReadableKey
        ]
        let summaryKeySet = Set(summaryKeys)

        let state = AtomicDirectorySummaryState()

        do {
            let rootValues = try url.resourceValues(forKeys: summaryKeySet)
            state.isAccessible = state.isAccessible && (rootValues.isReadable ?? false)
        } catch {
            state.isAccessible = false
            state.warnings.append(Self.makeWarning(for: url, error: error))
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
                let values = try childURL.resourceValues(forKeys: summaryKeySet)

                let isDirectory = values.isDirectory ?? false
                let isPackage = values.isPackage ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                state.isAccessible = state.isAccessible && (values.isReadable ?? false)

                if isDirectory {
                    if isPackage && !treatPackagesAsDirectories {
                        if let packageSummary = summarizeAtomicDirectory(
                            at: childURL,
                            includeHiddenFiles: includeHiddenFiles,
                            treatPackagesAsDirectories: true
                        ) {
                            merge(packageSummary, into: state)
                            enumerator.skipDescendants()
                        }
                    }
                } else {
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

        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
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

private struct NodeMetadata: Sendable {
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
