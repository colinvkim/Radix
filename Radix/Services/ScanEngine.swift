//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

actor ScanEngine {
    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
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

        let rootNode = try scanRootNode(
            target: target,
            options: options,
            behavior: behavior,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            startedAt: startedAt,
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

    private func scanRootNode(
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanBehavior,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        startedAt: Date,
        emissionState: inout ScanEmissionState
    ) throws -> FileNode {
        try Task.checkCancellation()

        let metadata = try metadata(for: target.url, includeVolumeDetails: true)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: metadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()

        if !shouldTraverseDirectory(metadata: metadata, options: options) {
            let fileNode = makeFileNode(url: target.url, metadata: metadata)
            if !fileNode.isSymbolicLink {
                metrics.filesVisited += 1
            }
            metrics.bytesDiscovered += fileNode.allocatedSize
            metrics.completedItems += 1
            metrics.recalculateProgress()
            continuation.yield(.progress(metrics))
            return fileNode
        }

        metrics.directoriesVisited += 1
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        do {
            let childURLs = try contents(
                of: target.url,
                includeHiddenFiles: options.includeHiddenFiles,
                behavior: behavior
            )
            metrics.discoveredItems += childURLs.count
            metrics.recalculateProgress()
            maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
            var children: [FileNode] = []

            for childURL in childURLs {
                try Task.checkCancellation()
                let child = try scanNode(
                    at: childURL,
                    options: options,
                    behavior: behavior,
                    metrics: &metrics,
                    warnings: &warnings,
                    continuation: continuation,
                    emissionState: &emissionState
                )
                children.append(child)

                let partialRoot = makeDirectoryNode(
                    url: target.url,
                    metadata: metadata,
                    children: children
                )
                maybeEmitPartialSnapshot(
                    target: target,
                    root: partialRoot,
                    metrics: metrics,
                    warnings: warnings,
                    startedAt: startedAt,
                    continuation: continuation,
                    emissionState: &emissionState,
                    isFinalChild: children.count == childURLs.count
                )
            }

            metrics.completedItems += 1
            metrics.recalculateProgress()
            maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
            return makeDirectoryNode(url: target.url, metadata: metadata, children: children)
        } catch {
            let warning = makeWarning(for: target.url, error: error)
            warnings.append(warning)
            continuation.yield(.warning(warning))
            metrics.inaccessibleDirectories += 1
            metrics.completedItems += 1
            metrics.recalculateProgress()
            continuation.yield(.progress(metrics))

            return FileNode(
                id: target.url.path,
                url: target.url,
                name: displayName(for: target.url),
                isDirectory: true,
                isSymbolicLink: metadata.isSymbolicLink,
                allocatedSize: 0,
                logicalSize: 0,
                children: [],
                descendantFileCount: 0,
                lastModified: metadata.lastModified,
                isPackage: metadata.isPackage,
                isAccessible: false,
                isSynthetic: false
            )
        }
    }

    private func scanNode(
        at url: URL,
        options: ScanOptions,
        behavior: ScanBehavior,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> FileNode {
        try Task.checkCancellation()

        let metadata = try metadata(for: url)
        metrics.currentPath = url.path

        if shouldTraverseDirectory(metadata: metadata, options: options) {
            metrics.directoriesVisited += 1
            metrics.recalculateProgress()
            maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

            do {
                let childURLs = try contents(
                    of: url,
                    includeHiddenFiles: options.includeHiddenFiles,
                    behavior: behavior
                )
                metrics.discoveredItems += childURLs.count
                metrics.recalculateProgress()
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
                var children: [FileNode] = []

                for childURL in childURLs {
                    let child = try scanNode(
                        at: childURL,
                        options: options,
                        behavior: behavior,
                        metrics: &metrics,
                        warnings: &warnings,
                        continuation: continuation,
                        emissionState: &emissionState
                    )
                    children.append(child)
                }

                metrics.completedItems += 1
                metrics.recalculateProgress()
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
                return makeDirectoryNode(url: url, metadata: metadata, children: children)
            } catch {
                let warning = makeWarning(for: url, error: error)
                warnings.append(warning)
                continuation.yield(.warning(warning))
                metrics.inaccessibleDirectories += 1
                metrics.completedItems += 1
                metrics.recalculateProgress()
                maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                return FileNode(
                    id: url.path,
                    url: url,
                    name: displayName(for: url),
                    isDirectory: true,
                    isSymbolicLink: metadata.isSymbolicLink,
                    allocatedSize: 0,
                    logicalSize: 0,
                    children: [],
                    descendantFileCount: 0,
                    lastModified: metadata.lastModified,
                    isPackage: metadata.isPackage,
                    isAccessible: false,
                    isSynthetic: false
                )
            }
        }

        let fileNode = makeFileNode(url: url, metadata: metadata)
        if !fileNode.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered += fileNode.allocatedSize
        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
        return fileNode
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
            parentURL.path == "/System/Volumes" &&
            childURL.lastPathComponent == "Data" {
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

    private func makeDirectoryNode(url: URL, metadata: NodeMetadata, children: [FileNode]) -> FileNode {
        makeDirectoryNode(
            id: url.path,
            url: url,
            name: displayName(for: url),
            children: children,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable
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

    private func makePartialSnapshot(
        target: ScanTarget,
        root: FileNode,
        startedAt: Date,
        warnings: [ScanWarning],
        metrics: ScanMetrics
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: target,
            root: root,
            startedAt: startedAt,
            finishedAt: nil,
            scanWarnings: warnings,
            aggregateStats: partialAggregateStats(for: root, metrics: metrics),
            isComplete: false
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

    private func partialAggregateStats(for root: FileNode, metrics: ScanMetrics) -> ScanAggregateStats {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let inaccessibleItems = metrics.inaccessibleDirectories

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: metrics.filesVisited,
            directoryCount: metrics.directoriesVisited,
            accessibleItemCount: max(visitedItems - inaccessibleItems, 0),
            inaccessibleItemCount: inaccessibleItems
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
            isAccessible: false,
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

    private func maybeEmitPartialSnapshot(
        target: ScanTarget,
        root: FileNode,
        metrics: ScanMetrics,
        warnings: [ScanWarning],
        startedAt: Date,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        isFinalChild: Bool
    ) {
        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastPartialSnapshotEmission)
        let shouldEmit = isFinalChild ||
            root.children.count <= 2 ||
            root.children.count.isMultiple(of: 8) ||
            elapsed >= 0.25
        guard shouldEmit else { return }

        emissionState.lastPartialSnapshotEmission = now
        continuation.yield(
            .snapshot(
                makePartialSnapshot(
                    target: target,
                    root: root,
                    startedAt: startedAt,
                    warnings: warnings,
                    metrics: metrics
                )
            )
        )
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

    private func makeWarning(for url: URL, error: Error) -> ScanWarning {
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
    var lastPartialSnapshotEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast,
        lastPartialSnapshotEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
        self.lastPartialSnapshotEmission = lastPartialSnapshotEmission
    }
}
