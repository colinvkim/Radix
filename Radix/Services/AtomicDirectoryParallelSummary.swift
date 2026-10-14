import Foundation

nonisolated struct AtomicSummaryRootFallbackRequired: Error {}

nonisolated final class AtomicSummaryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedSize: Int64 = 0
    private var logicalSize: Int64 = 0
    private var descendantFileCount = 0
    private var visitedItemCount = 0
    private var isAccessible = true
    private var warnings: [ScanWarning] = []
    private var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()

    init(seed: AtomicDirectorySummaryPartial? = nil) {
        guard let seed else { return }
        allocatedSize = seed.allocatedSize
        logicalSize = seed.logicalSize
        descendantFileCount = seed.descendantFileCount
        visitedItemCount = seed.visitedItemCount
        isAccessible = seed.isAccessible
        warnings = seed.warnings
        sharedAllocationAccumulator = seed.sharedAllocationAccumulator
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

    func merge(_ partial: AtomicDirectorySummaryPartial) {
        lock.lock()
        allocatedSize = ScanIntegerMath.addingClamped(allocatedSize, partial.allocatedSize)
        logicalSize = ScanIntegerMath.addingClamped(logicalSize, partial.logicalSize)
        descendantFileCount = ScanIntegerMath.addingClamped(
            descendantFileCount,
            partial.descendantFileCount
        )
        visitedItemCount = ScanIntegerMath.addingClamped(
            visitedItemCount,
            partial.visitedItemCount
        )
        isAccessible = isAccessible && partial.isAccessible
        warnings.append(contentsOf: partial.warnings)
        sharedAllocationAccumulator.merge(partial.sharedAllocationAccumulator)
        lock.unlock()
    }

    func makeSummary(visitedItemCount overrideVisitedItemCount: Int? = nil) -> AtomicDirectorySummary {
        lock.lock()
        defer { lock.unlock() }
        return AtomicDirectorySummary(
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            visitedItemCount: max(overrideVisitedItemCount ?? visitedItemCount, 0),
            isAccessible: isAccessible,
            warnings: warnings,
            sharedAllocationAccumulator: sharedAllocationAccumulator
        )
    }
}

nonisolated final class AtomicSummaryProgressReporter: @unchecked Sendable {
    typealias VisitHandler = @Sendable (_ delta: Int, _ currentURL: URL) -> Void

    private let lock = NSLock()
    private var metrics: ScanMetrics
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let visitHandler: VisitHandler?
    private var lastEmission = Date.distantPast
    private var hasEmitted = false
    private var lastReportedVisitedItemCount = 0

    init(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        visitHandler: VisitHandler? = nil
    ) {
        self.metrics = metrics
        self.continuation = continuation
        self.visitHandler = visitHandler
    }

    func emit(currentURL: URL, visitedItemCount: Int? = nil) {
        lock.lock()
        if let visitedItemCount, let visitHandler {
            let delta = visitedItemCount >= lastReportedVisitedItemCount
                ? visitedItemCount - lastReportedVisitedItemCount
                : visitedItemCount
            lastReportedVisitedItemCount = visitedItemCount
            if delta > 0 {
                visitHandler(delta, currentURL)
            }
        }
        guard visitHandler == nil else {
            lock.unlock()
            return
        }
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

    func finish(currentURL: URL, visitedItemCount: Int) {
        emit(currentURL: currentURL, visitedItemCount: visitedItemCount)
    }

    func beginPhase() {
        lock.lock()
        lastReportedVisitedItemCount = 0
        lock.unlock()
    }
}

extension AtomicDirectorySummarizer {
    nonisolated static func processPooledWorkItem(
        _ initialItem: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: @escaping CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        forcesFoundationTraversal: Bool
    ) throws -> AtomicSummaryWorkResult {
        try cancellationCheck()
        var item = initialItem

        if forcesFoundationTraversal {
            return try processPooledWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter
            )
        }

        var partial = AtomicDirectorySummaryPartial()
        var pendingItems: [AtomicSummaryWorkItem] = []
        var visitedItemCount = 0
        if item.nextEntryIndex < item.bufferedEntries.count {
            try stageEntries(
                item.bufferedEntries[item.nextEntryIndex...],
                from: item,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                partial: &partial,
                pendingItems: &pendingItems,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter,
                workerVisitedItemCount: &visitedItemCount
            )
            item.nextEntryIndex = item.bufferedEntries.count
        }

        var cursor = item.cursor
        if cursor == nil, item.needsCursor {
            do {
                let entryInclusion = nativeEntryInclusion(
                    under: item.url,
                    exclusionMatcher: exclusionMatcher
                )
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: item.url,
                    includeHiddenFiles: includeHiddenFiles,
                    loadsPackageMetadata: !item.treatPackagesAsDirectories,
                    metadataLoader: metadataLoader,
                    entryInclusion: entryInclusion,
                    cancellationCheck: cancellationCheck
                )
            } catch {
                try cancellationCheck()
                partial.recordWarning(for: item.url, error: error)
                progressReporter.finish(
                    currentURL: item.url,
                    visitedItemCount: visitedItemCount
                )
                return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
            }
        }

        do {
            while let batch = try cursor?.nextBatch(cancellationCheck: cancellationCheck) {
                try stageEntries(
                    batch.entries[...],
                    from: item,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    partial: &partial,
                    pendingItems: &pendingItems,
                    cancellationCheck: cancellationCheck,
                    progressReporter: progressReporter,
                    workerVisitedItemCount: &visitedItemCount,
                    entryInclusionExcludedItemCount: batch.entryInclusionExcludedItemCount
                )
            }
        } catch BulkDirectoryEnumerator.StreamError.unavailable {
            progressReporter.finish(
                currentURL: item.url,
                visitedItemCount: visitedItemCount
            )
            if item.requiresRootRestartOnFallback {
                throw AtomicSummaryRootFallbackRequired()
            }
            progressReporter.beginPhase()
            return try processPooledWorkItemUsingFoundation(
                item,
                includeHiddenFiles: includeHiddenFiles,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck,
                progressReporter: progressReporter
            )
        } catch {
            try cancellationCheck()
            progressReporter.finish(
                currentURL: item.url,
                visitedItemCount: visitedItemCount
            )
            var warningOnly = AtomicDirectorySummaryPartial()
            warningOnly.visitedItemCount = visitedItemCount
            warningOnly.recordWarning(for: item.url, error: error)
            return AtomicSummaryWorkResult(partial: warningOnly, pendingItems: [])
        }

        progressReporter.finish(currentURL: item.url, visitedItemCount: visitedItemCount)
        return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
    }

    private nonisolated static func processPooledWorkItemUsingFoundation(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: @escaping CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter
    ) throws -> AtomicSummaryWorkResult {
        var visitedItemCount = 0
        let result = try processFoundationWorkItem(
            item,
            includeHiddenFiles: includeHiddenFiles,
            exclusionMatcher: exclusionMatcher,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellationCheck,
            progressReporter: progressReporter,
            progressVisitedItemCount: visitedItemCount
        )
        visitedItemCount = ScanIntegerMath.addingClamped(
            visitedItemCount,
            result.partial.visitedItemCount
        )
        progressReporter.finish(currentURL: item.url, visitedItemCount: visitedItemCount)
        return result
    }

    /// Shared classification policy for the rare path-based compatibility
    /// backend. Results remain local until the post-enumeration identity check.
    nonisolated static func processFoundationWorkItem(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: @escaping CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        progressVisitedItemCount: Int,
        directoryContents: ScanEngine.DirectoryContentsProvider = ScanEngine.defaultDirectoryContents
    ) throws -> AtomicSummaryWorkResult {
        try cancellationCheck()
        func warningResult(
            for url: URL,
            error: Error,
            visitedItemCount: Int = 0
        ) -> AtomicSummaryWorkResult {
            var partial = AtomicDirectorySummaryPartial()
            partial.visitedItemCount = visitedItemCount
            partial.recordWarning(for: url, error: error)
            return AtomicSummaryWorkResult(partial: partial, pendingItems: [])
        }

        do {
            try metadataLoader.validateFileSystemIdentity(item.expectedIdentity, at: item.url)
        } catch {
            return warningResult(for: item.url, error: error)
        }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let enumerationResult: ScanEngine.DirectoryEnumerationResult
        do {
            enumerationResult = try directoryContents(
                item.url,
                ScanMetadataLoader.atomicSummaryResourceKeys,
                options,
                cancellationCheck
            )
        } catch {
            try cancellationCheck()
            return warningResult(for: item.url, error: error)
        }

        do {
            try metadataLoader.validateFileSystemIdentity(item.expectedIdentity, at: item.url)
        } catch {
            let visitedItemCount = enumerationResult.urls.count
            let currentProgressVisitedItemCount = ScanIntegerMath.addingClamped(
                progressVisitedItemCount,
                visitedItemCount
            )
            if let currentURL = enumerationResult.urls.last {
                progressReporter.emit(
                    currentURL: currentURL,
                    visitedItemCount: currentProgressVisitedItemCount
                )
            }
            return warningResult(
                for: item.url,
                error: error,
                visitedItemCount: visitedItemCount
            )
        }

        var partial = AtomicDirectorySummaryPartial()
        var pendingItems: [AtomicSummaryWorkItem] = []
        let hasActiveExclusions = !exclusionMatcher.isEmpty
        for childURL in enumerationResult.urls {
            try cancellationCheck()
            partial.visitedItemCount = ScanIntegerMath.addingClamped(
                partial.visitedItemCount,
                1
            )
            let currentProgressVisitedItemCount = ScanIntegerMath.addingClamped(
                progressVisitedItemCount,
                partial.visitedItemCount
            )
            if currentProgressVisitedItemCount == 1 || currentProgressVisitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(
                    currentURL: childURL,
                    visitedItemCount: currentProgressVisitedItemCount
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            let childPath = hasActiveExclusions ? childURL.path : nil
            if let childPath,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childPath,
                   isDirectory: hintedIsDirectory
               ) {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(
                    forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet
                )
                childMetadata = metadataLoader.atomicSummaryMetadata(
                    for: childURL,
                    prefetchedResourceValues: values
                )
            } catch {
                partial.recordWarning(for: childURL, error: error)
                continue
            }

            if childMetadata.isDirectory != hintedIsDirectory,
               let childPath,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childPath,
                   isDirectory: childMetadata.isDirectory
               ) {
                continue
            }
            guard !childMetadata.isDataless else { continue }

            partial.updateAccessibility(childMetadata.isReadable)
            guard childMetadata.isDirectory else {
                partial.accumulateFile(
                    childMetadata,
                    url: childURL,
                    ownerNodeID: item.ownerNodeID,
                    knownPath: childPath
                )
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            let childIdentity: FileIdentity
            do {
                childIdentity = try metadataLoader.fileSystemIdentity(at: childURL)
            } catch {
                partial.recordWarning(for: childURL, error: error)
                continue
            }
            if let boundaryError = item.volumeBoundaryPolicy.descentBoundaryError(
                for: childURL,
                childDeviceID: childIdentity.fileSystemDeviceID
            ) {
                partial.recordWarning(for: childURL, error: boundaryError)
                continue
            }
            pendingItems.append(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage
                        ? true
                        : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID,
                    expectedIdentity: childIdentity,
                    volumeBoundaryPolicy: item.volumeBoundaryPolicy
                )
            )
        }

        for failure in enumerationResult.localizedFailures {
            partial.recordWarning(for: failure.url, error: failure.error)
        }
        return AtomicSummaryWorkResult(partial: partial, pendingItems: pendingItems)
    }

    private nonisolated static func nativeEntryInclusion(
        under directoryURL: URL,
        exclusionMatcher: ScanExclusionMatcher
    ) -> BulkDirectoryEnumerator.EntryInclusion? {
        guard !exclusionMatcher.isEmpty else { return nil }
        let parentPath = directoryURL.path
        return { childName, isDirectory in
            !exclusionMatcher.excludesKnownNormalizedChild(
                named: childName,
                under: parentPath,
                isDirectory: isDirectory
            )
        }
    }

    private nonisolated static func stageEntries(
        _ entries: ArraySlice<DirectoryEntry>,
        from item: AtomicSummaryWorkItem,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        partial: inout AtomicDirectorySummaryPartial,
        pendingItems: inout [AtomicSummaryWorkItem],
        cancellationCheck: CancellationCheck,
        progressReporter: AtomicSummaryProgressReporter,
        workerVisitedItemCount: inout Int,
        entryInclusionExcludedItemCount: Int? = nil
    ) throws {
        if let entryInclusionExcludedItemCount,
           entryInclusionExcludedItemCount > 0 {
            let previousVisitedItemCount = workerVisitedItemCount
            workerVisitedItemCount = ScanIntegerMath.addingClamped(
                workerVisitedItemCount,
                entryInclusionExcludedItemCount
            )
            partial.visitedItemCount = ScanIntegerMath.addingClamped(
                partial.visitedItemCount,
                entryInclusionExcludedItemCount
            )
            if previousVisitedItemCount == 0
                || previousVisitedItemCount / 64 != workerVisitedItemCount / 64 {
                progressReporter.emit(
                    currentURL: item.url,
                    visitedItemCount: workerVisitedItemCount
                )
            }
        }
        let hasActiveExclusions = entryInclusionExcludedItemCount == nil
            && !exclusionMatcher.isEmpty
        for childEntry in entries {
            try cancellationCheck()
            let childURL = childEntry.url
            workerVisitedItemCount += 1
            partial.visitedItemCount += 1
            if workerVisitedItemCount == 1 || workerVisitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(
                    currentURL: childURL,
                    visitedItemCount: workerVisitedItemCount
                )
            }

            let hintedIsDirectory = childEntry.isDirectoryHint ?? childURL.hasDirectoryPath
            let childPath = hasActiveExclusions ? childURL.path : nil
            if let childPath,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childPath,
                   isDirectory: hintedIsDirectory
               ) {
                continue
            }

            let childMetadata: NodeMetadata
            if let prefetchedMetadata = childEntry.metadata {
                childMetadata = prefetchedMetadata
            } else if item.reloadsMissingBufferedMetadata {
                do {
                    childMetadata = try metadataLoader.metadata(for: childURL)
                } catch {
                    partial.recordWarning(for: childURL, error: error)
                    continue
                }
            } else {
                partial.recordWarning(
                    for: childURL,
                    error: childEntry.localizedEnumerationError ?? NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadUnknownError,
                        userInfo: [NSURLErrorKey: childURL]
                    )
                )
                continue
            }

            if childMetadata.isDirectory != hintedIsDirectory,
               let childPath,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childPath,
                   isDirectory: childMetadata.isDirectory
               ) {
                continue
            }
            guard !childMetadata.isDataless else { continue }

            partial.updateAccessibility(childMetadata.isReadable)
            guard childMetadata.isDirectory else {
                partial.accumulateFile(
                    childMetadata,
                    url: childURL,
                    ownerNodeID: item.ownerNodeID,
                    knownPath: childPath
                )
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            if let boundaryError = item.volumeBoundaryPolicy.descentBoundaryError(
                for: childURL,
                childDeviceID: childMetadata.fileIdentity?.fileSystemDeviceID
            ) {
                partial.recordWarning(for: childURL, error: boundaryError)
                continue
            }

            pendingItems.append(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID,
                    expectedIdentity: childMetadata.fileIdentity?.isFileSystemIdentity == true
                        ? childMetadata.fileIdentity
                        : nil,
                    volumeBoundaryPolicy: item.volumeBoundaryPolicy
                )
            )
        }
    }
}
