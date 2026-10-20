import Foundation
import Testing

@testable import RadixCore

struct AtomicSummaryRetryProgressTests {
    @Test
    func testLocalFoundationRetryReportsEachStableEntryOnce() throws {
        let rootURL = try makeRetryFixture()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let metadataLoader = ScanMetadataLoader()
        let identity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            expectedIdentity: identity,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedFailure: .unavailable(afterBatchCount: 1)
        )
        let events = AsyncThrowingStream<ScanProgressEvent, Error>.makeStream()
        defer { events.continuation.finish() }
        let visits = RetryVisitRecorder()
        let reporter = AtomicSummaryProgressReporter(
            metrics: ScanMetrics(),
            continuation: events.continuation,
            visitHandler: visits.record
        )

        let result = try AtomicDirectorySummarizer.processPooledWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: identity,
                cursor: cursor,
                needsCursor: false
            ),
            includeHiddenFiles: true,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: reporter,
            forcesFoundationTraversal: false
        )

        #expect(result.partial.descendantFileCount == 2_048)
        #expect(result.partial.logicalSize == 14_336)
        #expect(result.partial.visitedItemCount == 2_048)
        #expect(result.partial.warnings.isEmpty)
        #expect(result.pendingItems.isEmpty)
        #expect(visits.deltas.first == 1)
        #expect(visits.deltas.allSatisfy { $0 > 0 })
        #expect(visits.deltas.reduce(0, +) == 2_048)
    }

    @Test
    func testRetryReporterRetainsLargestObservedCountWhenListingShrinks() {
        let events = AsyncThrowingStream<ScanProgressEvent, Error>.makeStream()
        defer { events.continuation.finish() }
        let visits = RetryVisitRecorder()
        let reporter = AtomicSummaryProgressReporter(
            metrics: ScanMetrics(),
            continuation: events.continuation,
            visitHandler: visits.record
        )
        let url = URL(filePath: "/summary")

        reporter.emit(currentURL: url, visitedItemCount: 64)
        reporter.emit(currentURL: url, visitedItemCount: 32)
        reporter.emit(currentURL: url, visitedItemCount: 64)
        reporter.finish(currentURL: url, visitedItemCount: 65)

        #expect(visits.deltas == [64, 1])
    }

    @Test
    func testRootFoundationRetryResetsNonzeroProbeVisitsAndKeepsFractionMonotonic() async throws {
        let rootURL = try makeRetryFixture()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let metadataLoader = ScanMetadataLoader()
        let identity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let matcher = ScanExclusionMatcher(patterns: [], rootURL: rootURL)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            expectedIdentity: identity,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedFailure: .unavailable(afterBatchCount: 2)
        )
        let firstBatch = try cursor.nextBatch(cancellationCheck: {})
        let probeBatch = try #require(firstBatch)
        #expect(probeBatch.enumeratedItemCount > 0)
        #expect(probeBatch.enumeratedItemCount < 2_048)
        let events = AsyncThrowingStream<ScanProgressEvent, Error>.makeStream()
        let probe = try AtomicDirectorySummarizer.processPooledWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: identity,
                bufferedEntries: probeBatch.entries,
                needsCursor: false
            ),
            includeHiddenFiles: true,
            exclusionMatcher: matcher,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: AtomicSummaryProgressReporter(
                metrics: ScanMetrics(),
                continuation: events.continuation
            ),
            forcesFoundationTraversal: false
        )
        let seededVisits = probe.partial.visitedItemCount
        #expect(seededVisits == probeBatch.enumeratedItemCount)
        var base = ScanMetrics()
        base.discoveredItems = 1
        base.enumeratedDirectoryCount = 1
        let pool = AtomicDirectorySummaryPool(workerLimit: 1, progressEmissionInterval: 0)
        pool.updateProgress(base, continuation: events.continuation)

        let summary = try await pool.summarize(
            AtomicSummaryPoolRequest(
                url: rootURL,
                expectedRootIdentity: identity,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: true,
                progressWeight: 1,
                progressKind: .autoSummary,
                representedItemCount: 0,
                ownerNodeID: rootURL.path,
                exclusionMatcher: matcher,
                metadataLoader: metadataLoader,
                volumeBoundaryPolicy: .unrestricted,
                cancellationCheck: {},
                metrics: base,
                continuation: events.continuation,
                resumeState: AtomicDirectoryProbeResumeState(
                    partial: probe.partial,
                    workItems: [
                        AtomicSummaryWorkItem(
                            url: rootURL,
                            treatPackagesAsDirectories: true,
                            ownerNodeID: rootURL.path,
                            expectedIdentity: identity,
                            cursor: cursor,
                            needsCursor: false,
                            requiresRootRestartOnFallback: true
                        )
                    ],
                    visitedItemCount: seededVisits
                )
            )
        )
        await pool.finish()
        events.continuation.finish()
        var progress: [ScanMetrics] = []
        for try await event in events.stream {
            if case .progress(let metrics) = event {
                progress.append(metrics)
            }
        }

        let finished = try #require(summary)
        #expect(finished.descendantFileCount == 2_048)
        #expect(finished.logicalSize == 14_336)
        #expect(finished.visitedItemCount == 2_048)
        #expect(finished.isAccessible)
        #expect(finished.warnings.isEmpty)
        let restartedIndex = try #require(progress.firstIndex {
            $0.activeAtomicSummaryCount == 1 && $0.atomicSummaryVisitedItems == 0
        })
        #expect(progress[..<restartedIndex].contains { $0.atomicSummaryVisitedItems > seededVisits })
        let restartedVisit = try #require(progress[(restartedIndex + 1)...].first {
            $0.atomicSummaryVisitedItems > 0
        })
        #expect(restartedVisit.atomicSummaryVisitedItems == 1)
        #expect(progress.last?.atomicSummaryVisitedItems == 2_048)
        for (previous, next) in zip(progress, progress.dropFirst()) {
            #expect(next.progressFraction >= previous.progressFraction)
        }
    }
}

private func makeRetryFixture() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "RadixSummaryRetry-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    do {
        for index in 0..<2_048 {
            try Data(repeating: 0x11, count: 7).write(
                to: rootURL.appending(path: "payload-\(index).bin")
            )
        }
        return rootURL
    } catch {
        try? FileManager.default.removeItem(at: rootURL)
        throw error
    }
}

private final class RetryVisitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDeltas: [Int] = []

    var deltas: [Int] {
        lock.withLock { recordedDeltas }
    }

    func record(_ delta: Int, currentURL: URL) {
        lock.withLock { recordedDeltas.append(delta) }
    }
}
