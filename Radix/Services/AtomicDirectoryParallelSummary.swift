//
//  AtomicDirectoryParallelSummary.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated private struct AtomicSummaryWorkItem: Sendable {
    let url: URL
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
}

nonisolated private final class AtomicSummaryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingItems: [AtomicSummaryWorkItem]
    private var activeItemCount = 0
    private var failure: Error?

    init(rootItem: AtomicSummaryWorkItem) {
        pendingItems = [rootItem]
    }

    func take() throws -> AtomicSummaryWorkItem? {
        condition.lock()
        defer { condition.unlock() }

        while pendingItems.isEmpty, activeItemCount > 0, failure == nil {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            try Task.checkCancellation()
        }

        if let failure {
            throw failure
        }

        guard let item = pendingItems.popLast() else {
            return nil
        }

        activeItemCount += 1
        return item
    }

    func enqueue(_ item: AtomicSummaryWorkItem) {
        condition.lock()
        pendingItems.append(item)
        condition.signal()
        condition.unlock()
    }

    func finishCurrentItem() {
        condition.lock()
        activeItemCount -= 1
        if pendingItems.isEmpty && activeItemCount == 0 {
            condition.broadcast()
        } else {
            condition.signal()
        }
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if failure == nil {
            failure = error
        }
        pendingItems.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated private final class AtomicSummaryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedSize: Int64 = 0
    private var logicalSize: Int64 = 0
    private var descendantFileCount = 0
    private var isAccessible = true
    private var warnings: [ScanWarning] = []
    private var hardLinkClaims: [HardLinkClaim] = []
    private var visitedItemCount = 0

    func recordVisitedItem() -> Int {
        lock.lock()
        visitedItemCount += 1
        let count = visitedItemCount
        lock.unlock()
        return count
    }

    func updateAccessibility(_ readable: Bool) {
        lock.lock()
        isAccessible = isAccessible && readable
        lock.unlock()
    }

    func recordWarning(for url: URL, error: Error) {
        lock.lock()
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
        lock.unlock()
    }

    func accumulateFile(_ metadata: NodeMetadata, url: URL, ownerNodeID: String) {
        lock.lock()
        allocatedSize += metadata.allocatedSize
        logicalSize += metadata.logicalSize
        if !metadata.isSymbolicLink {
            descendantFileCount += 1
        }
        if let claim = HardLinkDeduplicator.claim(for: metadata, ownerNodeID: ownerNodeID, path: url.path) {
            hardLinkClaims.append(claim)
        }
        lock.unlock()
    }

    func makeSummary() -> AtomicDirectorySummary {
        lock.lock()
        defer { lock.unlock() }
        return AtomicDirectorySummary(
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            isAccessible: isAccessible,
            warnings: warnings,
            hardLinkClaims: hardLinkClaims
        )
    }
}

nonisolated private final class AtomicSummaryProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: ScanMetrics
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private var lastEmission = Date.distantPast
    private var hasEmitted = false

    init(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        self.metrics = metrics
        self.continuation = continuation
    }

    func emit(currentURL: URL) {
        lock.lock()
        let now = Date()
        guard !hasEmitted || now.timeIntervalSince(lastEmission) >= 0.15 else {
            lock.unlock()
            return
        }

        metrics.currentPath = currentURL.path
        lastEmission = now
        hasEmitted = true
        continuation.yield(.progress(metrics))
        lock.unlock()
    }
}

extension AtomicDirectorySummarizer {
    nonisolated static func summarizeInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> AtomicDirectorySummary? {
        try Task.checkCancellation()
        let progressReporter = AtomicSummaryProgressReporter(
            metrics: metrics,
            continuation: continuation
        )

        let accumulator = AtomicSummaryAccumulator()
        do {
            let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            accumulator.updateAccessibility(rootValues.isReadable ?? false)
        } catch {
            accumulator.recordWarning(for: url, error: error)
        }

        let queue = AtomicSummaryWorkQueue(
            rootItem: AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: ownerNodeID
            )
        )
        let workerCount = max(1, workerLimit)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        guard let item = try queue.take() else { return }

                        do {
                            try Self.processWorkItem(
                                item,
                                includeHiddenFiles: includeHiddenFiles,
                                exclusionMatcher: exclusionMatcher,
                                accumulator: accumulator,
                                queue: queue,
                                metadataLoader: metadataLoader,
                                progressReporter: progressReporter
                            )
                            queue.finishCurrentItem()
                        } catch {
                            queue.fail(error)
                            queue.finishCurrentItem()
                            throw error
                        }
                    }
                }
            }

            do {
                try await group.waitForAll()
            } catch {
                queue.fail(error)
                group.cancelAll()
                throw error
            }
        }

        return accumulator.makeSummary()
    }

    private nonisolated static func processWorkItem(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        accumulator: AtomicSummaryAccumulator,
        queue: AtomicSummaryWorkQueue,
        metadataLoader: ScanMetadataLoader,
        progressReporter: AtomicSummaryProgressReporter
    ) throws {
        try Task.checkCancellation()

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let childURLs: [URL]
        do {
            let enumerationResult = try ScanEngine.enumeratedDirectoryContents(
                url: item.url,
                keys: ScanMetadataLoader.atomicSummaryResourceKeys,
                options: options,
                cancellationCheck: { try Task.checkCancellation() },
                makeEnumerator: { url, keys, options in
                    FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: options,
                        errorHandler: { childURL, error in
                            accumulator.recordWarning(for: childURL, error: error)
                            return true
                        }
                    )
                }
            )
            childURLs = enumerationResult.urls
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accumulator.recordWarning(for: item.url, error: error)
            return
        }

        for childURL in childURLs {
            try Task.checkCancellation()
            let visitedItemCount = accumulator.recordVisitedItem()
            if visitedItemCount == 1 || visitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(currentURL: childURL)
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            guard !exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
                childMetadata = metadataLoader.metadata(for: childURL, prefetchedResourceValues: values)
            } catch {
                accumulator.recordWarning(for: childURL, error: error)
                continue
            }

            guard !exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) else {
                continue
            }

            accumulator.updateAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                accumulator.accumulateFile(childMetadata, url: childURL, ownerNodeID: item.ownerNodeID)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            queue.enqueue(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }
}
