//
//  AtomicDirectorySummarizer.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

typealias CancellationCheck = @Sendable () throws -> Void

/// A child discovered during directory enumeration.
/// Directory enumeration prefetches resource values, so carrying decoded metadata forward
/// avoids asking each URL for the same values again when the child is scanned.
nonisolated struct DirectoryEntry: Sendable {
    let url: URL
    let metadata: NodeMetadata?
}

nonisolated struct AtomicDirectorySummary: Sendable {
    let allocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let isAccessible: Bool
    let warnings: [ScanWarning]
    let hardLinkClaims: [HardLinkClaim]
}

nonisolated private final class AtomicDirectorySummaryState {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkClaims: [HardLinkClaim] = []
    let ownerNodeID: String

    init(ownerNodeID: String) {
        self.ownerNodeID = ownerNodeID
    }
}

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

nonisolated private struct AtomicDirectoryProbeProfile: Sendable {
    var observedFileCount = 0
    var observedDirectoryCount = 0
    var totalSampledLogicalSize: Int64 = 0
    var observedNodeDependencyLayout = false

    func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
        guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
        return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
    }
}

nonisolated struct AtomicDirectorySummarizer: Sendable {
    private let metadataLoader: ScanMetadataLoader
    private let diagnostics: ScanDiagnostics?

    init(metadataLoader: ScanMetadataLoader, diagnostics: ScanDiagnostics?) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
    }

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    func summaryIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
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
                exclusionMatcher: exclusionMatcher,
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

        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            return try await summarize(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: url.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else { return nil }
        return summary
    }

    nonisolated static func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@") else { return false }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    func summarize(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        if workerLimit > 1 {
            let summaryStart = diagnostics?.start()
            let summary = try await Self.summarizeInParallel(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                progressReporter: AtomicSummaryProgressReporter(
                    metrics: metrics,
                    continuation: continuation
                )
            )
            diagnostics?.record(
                operation: "atomic.summary.parallel",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount,
                detail: "workers=\(workerLimit)"
            )
            return summary
        }

        let summaryStart = diagnostics?.start()
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        var visitedItems = 0
        defer {
            diagnostics?.record(
                operation: "atomic.summary.enumerate",
                url: url,
                startedAt: summaryStart,
                itemCount: visitedItems,
                detail: "files=\(state.descendantFileCount)"
            )
        }

        do {
            try cancellationCheck()
            let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            updateAtomicAccessibility(rootValues.isReadable ?? false, in: state)
        } catch {
            recordAtomicWarning(for: url, error: error, in: state)
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicSummaryResourceKeys,
            options: enumeratorOptions,
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(ScanWarningFactory.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
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

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let childMetadata = try metadataLoader.atomicSummaryMetadata(for: childURL)
                if exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) {
                    if childMetadata.isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                try await accumulateEnumeratedAtomicSummary(
                    for: childURL,
                    metadata: childMetadata,
                    into: state,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    exclusionMatcher: exclusionMatcher,
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

    private func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        guard childEntries.contains(where: { childEntry in
            childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
        }) else {
            return false
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
        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
            try cancellationCheck()
            let childEntry = childEntries[index]
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
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()
        let probeStart = diagnostics?.start()
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        defer {
            diagnostics?.record(
                operation: "atomic.probe",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicProbeResourceKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return profile
        }

        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
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

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicProbeResourceKeySet)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                if exclusionMatcher.excludes(childURL, isDirectory: isDirectory) {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if Self.isNodeDependencyLayoutDirectory(at: childURL) {
                    profile.observedNodeDependencyLayout = true
                }

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

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    private func summarize(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        let summaryStart = diagnostics?.start()
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)
        defer {
            diagnostics?.record(
                operation: "atomic.summary.reused_entries",
                url: url,
                startedAt: summaryStart,
                itemCount: childEntries.count,
                detail: "files=\(state.descendantFileCount)"
            )
        }

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

            guard !exclusionMatcher.excludes(
                childEntry.url,
                isDirectory: childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadataLoader.metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            try await accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        return makeAtomicSummary(from: state)
    }

    private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else { return }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try await summarize(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: state.ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
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

        accumulateAtomicFile(metadata, url: url, into: state)
    }

    private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += summary.allocatedSize
        state.logicalSize += summary.logicalSize
        state.descendantFileCount += summary.descendantFileCount
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
        state.hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
    }

    private nonisolated static func summarizeInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        progressReporter: AtomicSummaryProgressReporter
    ) async throws -> AtomicDirectorySummary? {
        try Task.checkCancellation()

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
        progressReporter: AtomicSummaryProgressReporter
    ) throws {
        try Task.checkCancellation()

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let childURLs: [URL]
        do {
            childURLs = try ScanEngine.enumeratedDirectoryContents(
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
                childMetadata = ScanMetadataLoader.nodeMetadata(for: childURL, resourceValues: values)
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

    private func accumulateEnumeratedAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        skipDescendants: () -> Void
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else {
            if metadata.isDirectory {
                skipDescendants()
            }
            return
        }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        guard metadata.isDirectory else {
            accumulateAtomicFile(metadata, url: url, into: state)
            return
        }

        guard metadata.isPackage, !treatPackagesAsDirectories else { return }

        if let packageSummary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: workerLimit,
            ownerNodeID: state.ownerNodeID,
            exclusionMatcher: exclusionMatcher,
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
        state.warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    private func accumulateAtomicFile(_ metadata: NodeMetadata, url: URL, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += metadata.allocatedSize
        state.logicalSize += metadata.logicalSize

        if !metadata.isSymbolicLink {
            state.descendantFileCount += 1
        }

        if let claim = HardLinkDeduplicator.claim(for: metadata, ownerNodeID: state.ownerNodeID, path: url.path) {
            state.hardLinkClaims.append(claim)
        }
    }

    private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings,
            hardLinkClaims: state.hardLinkClaims
        )
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
}
