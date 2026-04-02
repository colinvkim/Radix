//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

actor ScanEngine {
    private let fileManager = FileManager.default
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .isRegularFileKey,
        .volumeNameKey
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

        let rootNode = try scanRootNode(
            target: target,
            options: options,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            startedAt: startedAt
        )

        return makeSnapshot(
            target: target,
            root: rootNode,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true
        )
    }

    private func scanRootNode(
        target: ScanTarget,
        options: ScanOptions,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        startedAt: Date
    ) throws -> FileNode {
        try Task.checkCancellation()

        let metadata = try metadata(for: target.url)
        metrics.currentPath = target.url.path

        if !shouldTraverseDirectory(metadata: metadata, options: options) {
            let fileNode = makeFileNode(url: target.url, metadata: metadata)
            metrics.filesVisited += 1
            metrics.bytesDiscovered += fileNode.allocatedSize
            continuation.yield(.progress(metrics))
            return fileNode
        }

        metrics.directoriesVisited += 1
        continuation.yield(.progress(metrics))

        do {
            let childURLs = try contents(of: target.url, includeHiddenFiles: options.includeHiddenFiles)
            var children: [FileNode] = []

            for childURL in childURLs {
                try Task.checkCancellation()
                let child = try scanNode(
                    at: childURL,
                    options: options,
                    metrics: &metrics,
                    warnings: &warnings,
                    continuation: continuation
                )
                children.append(child)

                let partialRoot = makeDirectoryNode(
                    url: target.url,
                    metadata: metadata,
                    children: children
                )
                let partialSnapshot = makeSnapshot(
                    target: target,
                    root: partialRoot,
                    startedAt: startedAt,
                    finishedAt: nil,
                    warnings: warnings,
                    isComplete: false
                )
                continuation.yield(.snapshot(partialSnapshot))
            }

            return makeDirectoryNode(url: target.url, metadata: metadata, children: children)
        } catch {
            let warning = makeWarning(for: target.url, error: error)
            warnings.append(warning)
            continuation.yield(.warning(warning))
            metrics.inaccessibleDirectories += 1
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
                isAccessible: false
            )
        }
    }

    private func scanNode(
        at url: URL,
        options: ScanOptions,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) throws -> FileNode {
        try Task.checkCancellation()

        let metadata = try metadata(for: url)
        metrics.currentPath = url.path

        if shouldTraverseDirectory(metadata: metadata, options: options) {
            metrics.directoriesVisited += 1
            maybeEmitProgress(metrics: metrics, continuation: continuation)

            do {
                let childURLs = try contents(of: url, includeHiddenFiles: options.includeHiddenFiles)
                var children: [FileNode] = []

                for childURL in childURLs {
                    let child = try scanNode(
                        at: childURL,
                        options: options,
                        metrics: &metrics,
                        warnings: &warnings,
                        continuation: continuation
                    )
                    children.append(child)
                }

                return makeDirectoryNode(url: url, metadata: metadata, children: children)
            } catch {
                let warning = makeWarning(for: url, error: error)
                warnings.append(warning)
                continuation.yield(.warning(warning))
                metrics.inaccessibleDirectories += 1
                maybeEmitProgress(metrics: metrics, continuation: continuation)

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
                    isAccessible: false
                )
            }
        }

        let fileNode = makeFileNode(url: url, metadata: metadata)
        metrics.filesVisited += 1
        metrics.bytesDiscovered += fileNode.allocatedSize
        maybeEmitProgress(metrics: metrics, continuation: continuation)
        return fileNode
    }

    private func metadata(for url: URL) throws -> NodeMetadata {
        let values = try url.resourceValues(forKeys: resourceKeys)
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        let isReadable = values.isReadable ?? false

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable
        )
    }

    private func contents(of url: URL, includeHiddenFiles: Bool) throws -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )

        return contents.sorted {
            let lhsName = displayName(for: $0)
            let rhsName = displayName(for: $1)
            let comparison = lhsName.localizedStandardCompare(rhsName)
            if comparison == .orderedSame {
                return $0.path < $1.path
            }
            return comparison == .orderedAscending
        }
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
            descendantFileCount: metadata.isDirectory ? 0 : 1,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable
        )
    }

    private func makeDirectoryNode(url: URL, metadata: NodeMetadata, children: [FileNode]) -> FileNode {
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
            result += child.isDirectory ? child.descendantFileCount : 1
        }
        let isAccessible = metadata.isReadable && sortedChildren.allSatisfy(\.isAccessible)

        return FileNode(
            id: url.path,
            url: url,
            name: displayName(for: url),
            isDirectory: true,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            children: sortedChildren,
            descendantFileCount: descendantFileCount,
            lastModified: metadata.lastModified,
            isPackage: metadata.isPackage,
            isAccessible: isAccessible
        )
    }

    private func makeSnapshot(
        target: ScanTarget,
        root: FileNode,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: target,
            root: root,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: aggregateStats(for: root),
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
            } else {
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

    private func maybeEmitProgress(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        if visitedItems == 1 || visitedItems.isMultiple(of: 200) {
            continuation.yield(.progress(metrics))
        }
    }

    private func displayName(for url: URL) -> String {
        if url.path == "/" {
            let values = try? url.resourceValues(forKeys: [.volumeNameKey])
            return values?.volumeName ?? "Startup Disk"
        }

        let lastPathComponent = url.lastPathComponent
        if lastPathComponent.isEmpty {
            return FileManager.default.displayName(atPath: url.path)
        }
        return lastPathComponent
    }

    private func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
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
}
