import Foundation

nonisolated struct AtomicDirectorySummarizer: Sendable {
    #if DEBUG
    typealias ProfileReporter = @Sendable (ScanAutoSummaryProfileEvent) -> Void
    #endif

    let metadataLoader: ScanMetadataLoader
    let diagnostics: ScanDiagnosticsContext?
    let summaryPool: AtomicDirectorySummaryPool
    let volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy
    #if DEBUG
    let profileReporter: ProfileReporter?
    #endif

    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        summaryPool: AtomicDirectorySummaryPool,
        volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy = .unrestricted
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.summaryPool = summaryPool
        self.volumeBoundaryPolicy = volumeBoundaryPolicy
        #if DEBUG
        self.profileReporter = nil
        #endif
    }

    #if DEBUG
    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        summaryPool: AtomicDirectorySummaryPool,
        volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy = .unrestricted,
        profileReporter: ProfileReporter?
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.summaryPool = summaryPool
        self.volumeBoundaryPolicy = volumeBoundaryPolicy
        self.profileReporter = profileReporter
    }
    #endif

    /// Cheap, synchronous pre-check mirroring `summaryDecisionIfNeeded`'s gating: whether the
    /// directory is worth probing or summarizing at all. Runs no descendant I/O, so it
    /// is safe to call on the scan scheduling loop before dispatching the (potentially
    /// slow) `summaryDecisionIfNeeded` call off it.
    func isAtomicSummaryCandidate(
        url: URL,
        childEntries: [DirectoryEntry],
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        allowsDescendantProbe: Bool = true,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        guard !childEntries.isEmpty else { return false }
        if childEntries.count >= minFileCount,
           try immediateChildrenSuggestAtomicDirectory(
               childEntries,
               maxAverageFileSize: maxAverageFileSize,
               cancellationCheck: cancellationCheck
           ) {
            return true
        }
        guard allowsDescendantProbe else { return false }
        return shouldRunDescendantAtomicProbe(
            childEntries: childEntries,
            minFileCount: minFileCount,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    func summaryDecisionIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        expectedRootIdentity: FileIdentity? = nil,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        progressWeight: Double = 0,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummaryDecision {
        try cancellationCheck()
        guard !childEntries.isEmpty else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }

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
        var probeResumeState: AtomicDirectoryProbeResumeState? = nil
        var reusableDirectoryListings: [String: AtomicDirectoryProbeListing] = [:]
        var descendantProbeFullyExhausted = false
        if immediateCandidate {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return AtomicDirectorySummaryDecision(
                    summary: nil,
                    reusableDirectoryListings: [:],
                    descendantProbeFullyExhausted: false
                )
            }
            let outcome = try descendantAtomicProbeProfile(
                at: url,
                rootEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = outcome.profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
            #if DEBUG
            profileReporter?(.probeCompleted(
                visitedItemCount: outcome.visitedItemCount,
                wasAccepted: deepCandidate
            ))
            #endif
            probeResumeState = deepCandidate ? outcome.resumeState : nil
            if !deepCandidate {
                reusableDirectoryListings = outcome.reusableDirectoryListings
                descendantProbeFullyExhausted = outcome.fullyExhausted
            }
        }

        guard deepCandidate else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: reusableDirectoryListings,
                descendantProbeFullyExhausted: descendantProbeFullyExhausted
            )
        }

        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            var partial = AtomicDirectorySummaryPartial()
            partial.updateAccessibility(metadata.isReadable)
            let resumeState = AtomicDirectoryProbeResumeState(
                partial: partial,
                workItems: [AtomicSummaryWorkItem(
                    url: url,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    ownerNodeID: url.path,
                    expectedIdentity: expectedRootIdentity,
                    volumeBoundaryPolicy: volumeBoundaryPolicy,
                    bufferedEntries: childEntries,
                    needsCursor: false,
                    reloadsMissingBufferedMetadata: true
                )],
                visitedItemCount: 0
            )
            let summary = try await summarize(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                progressWeight: progressWeight,
                progressKind: .autoSummary,
                representedItemCount: childEntries.count,
                ownerNodeID: url.path,
                expectedRootIdentity: expectedRootIdentity,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                resumeState: resumeState
            )
            #if DEBUG
            reportCreatedSummary(summary)
            #endif
            return AtomicDirectorySummaryDecision(
                summary: summary,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            progressWeight: progressWeight,
            progressKind: .autoSummary,
            representedItemCount: childEntries.count,
            ownerNodeID: url.path,
            expectedRootIdentity: expectedRootIdentity,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            resumeState: probeResumeState
        ) else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }
        #if DEBUG
        reportCreatedSummary(summary)
        #endif
        return AtomicDirectorySummaryDecision(
            summary: summary,
            reusableDirectoryListings: [:],
            descendantProbeFullyExhausted: false
        )
    }

    #if DEBUG
    private func reportCreatedSummary(_ summary: AtomicDirectorySummary?) {
        guard let summary else { return }
        profileReporter?(.directorySummarized(
            descendantFileCount: summary.descendantFileCount
        ))
    }
    #endif

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    func summarize(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        progressWeight: Double = 0,
        progressKind: AtomicSummaryProgressKind = .autoSummary,
        representedItemCount: Int = 0,
        ownerNodeID: String,
        expectedRootIdentity: FileIdentity? = nil,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        resumeState: AtomicDirectoryProbeResumeState? = nil
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let summary = try await summaryPool.summarize(
            AtomicSummaryPoolRequest(
                url: url,
                expectedRootIdentity: expectedRootIdentity,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                progressWeight: progressWeight,
                progressKind: progressKind,
                representedItemCount: representedItemCount,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                volumeBoundaryPolicy: volumeBoundaryPolicy,
                cancellationCheck: cancellationCheck,
                metrics: metrics,
                continuation: continuation,
                resumeState: resumeState
            )
        )
        #if DEBUG
        diagnostics?.record(
            operation: "atomic.summary.pool",
            url: url,
            startedAt: summaryStart,
            itemCount: summary?.descendantFileCount
        )
        #endif
        return summary
    }
}
