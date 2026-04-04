//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

actor ScanEngine {
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
    private struct ScanWorkItem: Sendable {
        let url: URL
        let includeVolumeDetails: Bool
        let parentKey: Int
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
        // We use a stack for DFS. Each item knows its parent key for assembly.
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(url: target.url, includeVolumeDetails: true, parentKey: -1)
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
                meta = try metadata(for: item.url)
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

                    // Enqueue children onto the stack. Each child records its parent key.
                    for childURL in childURLs {
                        workStack.append(
                            ScanWorkItem(url: childURL, includeVolumeDetails: false, parentKey: itemKey)
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
                        isSynthetic: false
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

            if completed.isTraversable, let childKeys = childrenKeysByKey[key] {
                // Traversable directory: assemble resolved children.
                let childNodes = childKeys.compactMap { resolvedNodeByKey[$0] }
                let assembled = makeDirectoryNode(
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
            fatalError("Root work item was never completed.")
        }

        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        return rootNode
    }

    // MARK: - Helpers

    private func applyLeafMetrics(_ node: FileNode, metrics: inout ScanMetrics) {
        if node.isDirectory {
            metrics.directoriesVisited += 1
            metrics.filesVisited += node.descendantFileCount
        } else if !node.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered += node.allocatedSize
        metrics.completedItems += 1
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
            isSynthetic: false
        )
    }

    private func makeLeafNode(url: URL, metadata: NodeMetadata, options: ScanOptions) -> (node: FileNode, warnings: [ScanWarning]) {
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            return (makeFileNode(url: url, metadata: metadata), [])
        }

        guard let summary = summarizeAtomicDirectory(at: url) else {
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
                isSynthetic: false
            ),
            summary.warnings
        )
    }

    private func summarizeAtomicDirectory(at url: URL) -> AtomicDirectorySummary? {
        let summaryKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isReadableKey
        ]

        let state = AtomicDirectorySummaryState()

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: summaryKeys,
            options: [],
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(Self.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        if let rootValues = try? url.resourceValues(forKeys: Set(summaryKeys)) {
            state.isAccessible = state.isAccessible && (rootValues.isReadable ?? false)
        }

        for case let childURL as URL in enumerator {
            do {
                let values = try childURL.resourceValues(forKeys: Set(summaryKeys))

                let childAllocatedSize = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                let childLogicalSize = Int64(values.fileSize ?? 0)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                state.isAccessible = state.isAccessible && (values.isReadable ?? false)

                if !isDirectory {
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

    private func makeDirectoryNode(
        id: String,
        url: URL,
        name: String,
        children: [FileNode],
        lastModified: Date?,
        isPackage: Bool,
        isAccessible: Bool
    ) -> FileNode {
        let sortedChildren = children.sorted { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }

        let allocatedSize = sortedChildren.reduce(into: Int64(0)) { result, child in
            result += child.allocatedSize
        }
        let logicalSize = sortedChildren.reduce(into: Int64(0)) { result, child in
            result += child.logicalSize
        }
        let descendantFileCount = sortedChildren.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }
        let isFullyAccessible = isAccessible && sortedChildren.allSatisfy(\.isAccessible)

        return FileNode(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            children: sortedChildren,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSynthetic: false
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
            aggregateStats: aggregateStats(for: reconciledRoot),
            isComplete: isComplete
        )
    }

    private func aggregateStats(for root: FileNode) -> ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        walk(node: root) { node in
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && node.children.isEmpty {
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

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    private func walk(node: FileNode, visit: (FileNode) -> Void) {
        visit(node)
        for child in node.children {
            walk(node: child, visit: visit)
        }
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
            isSynthetic: true
        )

        return makeDirectoryNode(
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
