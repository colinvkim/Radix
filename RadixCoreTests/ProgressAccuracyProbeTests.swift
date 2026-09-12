import Combine
import Darwin
import Foundation
import Testing

@testable import RadixCore

/// Opt-in, test-target-only measurement of the progress values Radix actually
/// publishes to `ScanProgressState`. Production progress is work-based; elapsed
/// time is used only retrospectively here to score the completed curve.
struct ProgressAccuracyProbeTests {
    @Test
    func testAccuracySummaryIntegratesHeldDisplayedValuesOverTime() {
        var halfway = ScanMetrics()
        halfway.progressFraction = 0.5
        var complete = ScanMetrics()
        complete.progressFraction = 1

        let summary = AccuracySummary(
            samples: [
                Sample(elapsed: 0, metrics: ScanMetrics()),
                Sample(elapsed: 0.5, metrics: halfway),
                Sample(elapsed: 1, metrics: complete),
            ],
            total: 1
        )

        #expect(abs((summary.timeWeightedMAE) - (0.25)) <= 0.000_001)
        #expect(abs((summary.timeWeightedRMSE) - (sqrt(1.0 / 12.0))) <= 0.000_001)
        #expect(abs((summary.signedBias) - (-0.25)) <= 0.000_001)
        #expect(abs((summary.maximumLead) - (0)) <= 0.000_001)
        #expect(abs((summary.maximumLag) - (-0.5)) <= 0.000_001)
        #expect(abs((summary.milestone(0.5)) - (0.5)) <= 0.000_001)
        #expect(abs((summary.completionJump) - (0.5)) <= 0.000_001)
        #expect(summary.monotonicViolations == 0)
        #expect(summary.boundsViolations == 0)
    }

    @Test
    func testAccuracySummaryPreservesEqualTimestampPublicationOrder() {
        var rising = ScanMetrics()
        rising.progressFraction = 0.6
        var regressed = ScanMetrics()
        regressed.progressFraction = 0.5
        var complete = ScanMetrics()
        complete.progressFraction = 1

        let summary = AccuracySummary(
            samples: [
                Sample(elapsed: 0, metrics: ScanMetrics()),
                Sample(elapsed: 0.5, metrics: rising),
                Sample(elapsed: 0.5, metrics: regressed),
                Sample(elapsed: 1, metrics: complete),
            ],
            total: 1
        )

        #expect(summary.monotonicViolations == 1)
        #expect(abs((summary.milestone(0.5)) - (0.5)) <= 0.000_001)
    }

    @MainActor
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_PROGRESS_PROBE"] == "1",
            "Set RADIX_PROGRESS_PROBE=1 to run the progress accuracy probe."))
    func testProgressCurve() async throws {
        let environment = ProcessInfo.processInfo.environment

        let path = environment["RADIX_PROGRESS_PROBE_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: path, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw TestFixtureError("Progress probe path does not exist: \(targetURL.path)")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let engine = ScanEngine()
        let coordinator = ScanCoordinator(
            scanService: ProgressProbeScanService(engine: engine),
            progressThrottleDuration: .milliseconds(100)
        )
        var samples = [Sample(elapsed: 0, metrics: ScanMetrics())]
        let progressObservation = coordinator.progress.$metrics
            .dropFirst()
            .sink { metrics in
                samples.append(
                    Sample(
                        elapsed: BenchmarkSupport.durationSeconds(start.duration(to: clock.now)),
                        metrics: metrics
                    ))
            }

        coordinator.startScan(
            ScanTarget(url: targetURL),
            options: ScanOptions()
        )

        let deadline = clock.now.advanced(by: .seconds(300))
        while coordinator.isScanOperationInProgress {
            guard clock.now < deadline else {
                coordinator.stopScan()
                Issue.record("Timed out measuring progress for \(targetURL.path).")
                progressObservation.cancel()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let total = BenchmarkSupport.durationSeconds(start.duration(to: clock.now))
        progressObservation.cancel()
        let snapshot = try #require(
            coordinator.snapshot, Comment(rawValue: coordinator.scanErrorMessage ?? "Scan finished without a snapshot.")
        )
        if samples.last?.fraction != 1 {
            samples.append(Sample(elapsed: total, metrics: coordinator.scanMetrics))
        }
        let summary = AccuracySummary(samples: samples, total: total)

        #expect(summary.boundsViolations == 0)
        #expect(summary.monotonicViolations == 0)
        #expect(abs((try #require(samples.last?.fraction)) - (1)) <= 0.000_001)

        if environment["RADIX_PROGRESS_PROBE_VERBOSE"] == "1" {
            print(
                "PROBE_HEADER elapsed time_fraction reported_fraction percentage weight atomic_weight files directories completed discovered enumerated pending summary_additional_visited atomic_visited atomic_remaining atomic_active finalizing"
            )
            for sample in samples {
                print(
                    String(
                        format: "PROBE %.6f %.6f %.6f %d %.6f %.6f %d %d %d %d %d %d %d %d %d %d %d",
                        sample.elapsed,
                        total > 0 ? sample.elapsed / total : 0,
                        sample.fraction,
                        sample.percentage,
                        sample.metrics.completedTraversalWeight,
                        sample.metrics.atomicSummaryCompletedTraversalWeight,
                        sample.metrics.filesVisited,
                        sample.metrics.directoriesVisited,
                        sample.metrics.completedItems,
                        sample.metrics.discoveredItems,
                        sample.metrics.enumeratedDirectoryCount,
                        sample.metrics.pendingDirectoryCount,
                        sample.metrics.completedSummaryAdditionalVisitedItemCount,
                        sample.metrics.atomicSummaryVisitedItems,
                        sample.metrics.atomicSummaryEstimatedRemainingItems,
                        sample.metrics.activeAtomicSummaryCount,
                        sample.metrics.isFinalizing ? 1 : 0
                    ))
            }
        }

        print(
            """
            RADIX_PROGRESS_ACCURACY_RESULT path=\(targetURL.path)
            total_seconds=\(BenchmarkSupport.format(total))
            displayed_samples=\(samples.count)
            time_weighted_mae=\(BenchmarkSupport.format(summary.timeWeightedMAE))
            time_weighted_rmse=\(BenchmarkSupport.format(summary.timeWeightedRMSE))
            signed_bias=\(BenchmarkSupport.format(summary.signedBias))
            max_lead=\(BenchmarkSupport.format(summary.maximumLead))
            max_lag=\(BenchmarkSupport.format(summary.maximumLag))
            milestone_25=\(BenchmarkSupport.format(summary.milestone(0.25)))
            milestone_50=\(BenchmarkSupport.format(summary.milestone(0.50)))
            milestone_75=\(BenchmarkSupport.format(summary.milestone(0.75)))
            milestone_90=\(BenchmarkSupport.format(summary.milestone(0.90)))
            milestone_95=\(BenchmarkSupport.format(summary.milestone(0.95)))
            longest_integer_stall_share=\(BenchmarkSupport.format(summary.longestIntegerStallShare))
            longest_update_gap_share=\(BenchmarkSupport.format(summary.longestUpdateGapShare))
            completion_jump=\(BenchmarkSupport.format(summary.completionJump))
            finalization_elapsed_share=\(BenchmarkSupport.format(summary.finalizationElapsedShare))
            monotonic_violations=\(summary.monotonicViolations)
            bounds_violations=\(summary.boundsViolations)
            files=\(snapshot.aggregateStats.fileCount)
            folders=\(snapshot.aggregateStats.directoryCount)
            nodes=\(snapshot.treeStore.nodeCount)
            warnings=\(snapshot.scanWarnings.count)
            warning_fingerprint=\(scanWarningFingerprint(snapshot.scanWarnings))
            warning_order_fingerprint=\(scanOrderedWarningFingerprint(snapshot.scanWarnings))
            allocated_bytes=\(snapshot.aggregateStats.totalAllocatedSize)
            fingerprint=\(scanResultFingerprint(snapshot.treeStore))
            """
        )
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_PROGRESS_PROBE_CANCEL"] == "1",
            "Set RADIX_PROGRESS_PROBE_CANCEL=1 to run the progress cancellation probe."))
    func testCancellationLatency() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            // A watchdog on a preemptive queue bounds the worker even if the
            // cooperative executor deadlocks. The parent remains able to report it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { _exit(124) }
            try await ProgressAccuracyProbeTests.measureCancellationLatency()
        }
        print(String(decoding: result.standardOutputContent, as: UTF8.self), terminator: "")
    }

    private static func measureCancellationLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["RADIX_PROGRESS_PROBE_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: path, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw TestFixtureError("Progress probe path does not exist: \(targetURL.path)")
        }
        let cancellationDelayMilliseconds = max(
            environment["RADIX_PROGRESS_PROBE_CANCEL_AFTER_MS"].flatMap(Int.init) ?? 150,
            1
        )
        let workerActivity = ProgressProbeWorkerActivity()
        let engine = ScanEngine(
            atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver(
                didStart: { _, _ in workerActivity.didStart() },
                didFinish: { _, _ in workerActivity.didFinish() },
                didShutdown: { workerActivity.didShutdown() }
            ))
        let observation = ProgressProbeCancellationObservation()
        let consumer = Task {
            var emittedFinishedSnapshot = false
            var unexpectedError: String?
            do {
                for try await event in engine.scan(
                    target: ScanTarget(url: targetURL),
                    options: ScanOptions()
                ) {
                    switch event {
                    case .progress(let metrics):
                        await observation.record(metrics)
                    case .finished:
                        emittedFinishedSnapshot = true
                    case .executionMode, .warning:
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                unexpectedError = String(describing: error)
            }
            await observation.recordTermination(
                ProgressProbeCancellationOutcome(
                    emittedFinished: emittedFinishedSnapshot,
                    unexpectedError: unexpectedError
                ))
        }

        try await Task.sleep(for: .milliseconds(cancellationDelayMilliseconds))
        let clock = ContinuousClock()
        let progressDeadline = clock.now.advanced(by: .seconds(5))
        while !(await observation.didObserveActiveProgress())
            || !workerActivity.hasActiveWorkers,
            clock.now < progressDeadline
        {
            try await Task.sleep(for: .milliseconds(1))
        }
        let progressObserved = await observation.didObserveActiveProgress()
        let workerActiveAtCancellation = workerActivity.hasActiveWorkers
        let cancellationStart = clock.now
        consumer.cancel()
        let shutdownDeadline = clock.now.advanced(by: .seconds(5))
        while (await observation.terminationOutcome()) == nil
            || !workerActivity.hasShutdown,
            clock.now < shutdownDeadline
        {
            try await Task.sleep(for: .milliseconds(1))
        }
        let outcome = await observation.terminationOutcome()
        let poolShutdown = workerActivity.hasShutdown
        let workersQuiescent = workerActivity.isQuiescent
        let shutdownLatency = BenchmarkSupport.durationSeconds(cancellationStart.duration(to: clock.now))

        #expect(progressObserved, "Cancellation probe never observed active scan work.")
        #expect(workerActiveAtCancellation, "Cancellation probe did not cancel active summary work.")
        #expect(outcome != nil, "Scan stream did not terminate within five seconds of cancellation.")
        #expect(poolShutdown, "Summary pool did not complete shutdown after cancellation.")
        #expect(workersQuiescent, "Summary workers did not quiesce after cancellation.")
        #expect(!(outcome?.emittedFinished ?? true))
        #expect(outcome?.unexpectedError == nil)
        print(
            "RADIX_PROGRESS_CANCELLATION_RESULT path=\(targetURL.path) "
                + "cancel_after_ms=\(cancellationDelayMilliseconds) "
                + "shutdown_latency_seconds=\(BenchmarkSupport.format(shutdownLatency)) "
                + "progress_observed=\(progressObserved) "
                + "worker_active=\(workerActiveAtCancellation) "
                + "pool_shutdown=\(poolShutdown) "
                + "workers_quiescent=\(workersQuiescent) "
                + "stream_terminated=\(outcome != nil) "
                + "emitted_finished=\(outcome?.emittedFinished ?? true)"
        )
    }

    private struct Sample {
        let elapsed: Double
        let metrics: ScanMetrics

        var fraction: Double { metrics.progressFraction }
        var percentage: Int { metrics.progressPercentage }
    }

    private struct AccuracySummary {
        let timeWeightedMAE: Double
        let timeWeightedRMSE: Double
        let signedBias: Double
        let maximumLead: Double
        let maximumLag: Double
        let longestIntegerStallShare: Double
        let longestUpdateGapShare: Double
        let completionJump: Double
        let finalizationElapsedShare: Double
        let monotonicViolations: Int
        let boundsViolations: Int
        private let milestoneByFraction: [Double: Double]

        init(samples: [Sample], total: Double) {
            let duration = max(total, .leastNonzeroMagnitude)
            // The coordinator publishes serially on the main actor, so capture order is
            // authoritative. Sorting by timestamp would make equal-tick samples unstable
            // and could hide a real regression.
            let orderedSamples = samples
            var absoluteErrorArea = 0.0
            var squaredErrorArea = 0.0
            var signedErrorArea = 0.0
            var maximumLead = -Double.infinity
            var maximumLag = Double.infinity
            var monotonicViolations = 0
            var boundsViolations = 0
            var longestUpdateGap = 0.0

            for (index, sample) in orderedSamples.enumerated() {
                let normalizedTime = min(max(sample.elapsed / duration, 0), 1)
                maximumLead = max(maximumLead, sample.fraction - normalizedTime)
                maximumLag = min(maximumLag, sample.fraction - normalizedTime)
                if !(0...1).contains(sample.fraction) {
                    boundsViolations += 1
                }
                guard index > 0 else { continue }
                let previous = orderedSamples[index - 1]
                if sample.fraction < previous.fraction {
                    monotonicViolations += 1
                }
                let start = min(max(previous.elapsed / duration, 0), 1)
                let end = min(max(sample.elapsed / duration, start), 1)
                let heldFraction = previous.fraction
                absoluteErrorArea += Self.absoluteErrorArea(
                    heldFraction: heldFraction,
                    from: start,
                    to: end
                )
                squaredErrorArea += Self.squaredErrorArea(
                    heldFraction: heldFraction,
                    from: start,
                    to: end
                )
                signedErrorArea += (end - start) * (heldFraction - (start + end) / 2)
                maximumLead = max(maximumLead, heldFraction - start)
                maximumLag = min(maximumLag, heldFraction - end)
                longestUpdateGap = max(longestUpdateGap, sample.elapsed - previous.elapsed)
            }

            if let last = orderedSamples.last, last.elapsed < duration {
                let start = min(max(last.elapsed / duration, 0), 1)
                absoluteErrorArea += Self.absoluteErrorArea(
                    heldFraction: last.fraction,
                    from: start,
                    to: 1
                )
                squaredErrorArea += Self.squaredErrorArea(
                    heldFraction: last.fraction,
                    from: start,
                    to: 1
                )
                signedErrorArea += (1 - start) * (last.fraction - (start + 1) / 2)
                maximumLead = max(maximumLead, last.fraction - start)
                maximumLag = min(maximumLag, last.fraction - 1)
                longestUpdateGap = max(longestUpdateGap, duration - last.elapsed)
            }

            var milestoneByFraction: [Double: Double] = [:]
            for milestone in [0.25, 0.50, 0.75, 0.90, 0.95] {
                if let sample = orderedSamples.first(where: { $0.fraction >= milestone }) {
                    milestoneByFraction[milestone] = min(max(sample.elapsed / duration, 0), 1)
                }
            }

            var stallStart = 0.0
            var currentPercentage = orderedSamples.first?.percentage ?? 0
            var longestIntegerStall = 0.0
            for sample in orderedSamples.dropFirst() where sample.percentage != currentPercentage {
                longestIntegerStall = max(longestIntegerStall, sample.elapsed - stallStart)
                stallStart = sample.elapsed
                currentPercentage = sample.percentage
            }
            longestIntegerStall = max(longestIntegerStall, duration - stallStart)

            let fractionBeforeCompletion =
                orderedSamples
                .last(where: { $0.fraction < 1 })?
                .fraction ?? 0
            let finalizationStart =
                orderedSamples
                .first(where: { $0.metrics.isFinalizing })?
                .elapsed

            self.timeWeightedMAE = absoluteErrorArea
            self.timeWeightedRMSE = sqrt(max(squaredErrorArea, 0))
            self.signedBias = signedErrorArea
            self.maximumLead = maximumLead.isFinite ? maximumLead : 0
            self.maximumLag = maximumLag.isFinite ? maximumLag : 0
            self.longestIntegerStallShare = min(max(longestIntegerStall / duration, 0), 1)
            self.longestUpdateGapShare = min(max(longestUpdateGap / duration, 0), 1)
            self.completionJump = min(max(1 - fractionBeforeCompletion, 0), 1)
            self.finalizationElapsedShare =
                finalizationStart.map {
                    min(max((duration - $0) / duration, 0), 1)
                } ?? 0
            self.monotonicViolations = monotonicViolations
            self.boundsViolations = boundsViolations
            self.milestoneByFraction = milestoneByFraction
        }

        func milestone(_ fraction: Double) -> Double {
            milestoneByFraction[fraction] ?? -1
        }

        private static func absoluteErrorArea(
            heldFraction: Double,
            from start: Double,
            to end: Double
        ) -> Double {
            guard end > start else { return 0 }
            if heldFraction <= start {
                return (end - start) * ((start + end) / 2 - heldFraction)
            }
            if heldFraction >= end {
                return (end - start) * (heldFraction - (start + end) / 2)
            }
            let leading = heldFraction - start
            let trailing = end - heldFraction
            return (leading * leading + trailing * trailing) / 2
        }

        private static func squaredErrorArea(
            heldFraction: Double,
            from start: Double,
            to end: Double
        ) -> Double {
            guard end > start else { return 0 }
            let startError = start - heldFraction
            let endError = end - heldFraction
            return (endError * endError * endError - startError * startError * startError) / 3
        }
    }

}

private actor ProgressProbeCancellationObservation {
    private var observedActiveProgress = false
    private var outcome: ProgressProbeCancellationOutcome?

    func record(_ metrics: ScanMetrics) {
        guard
            metrics.filesVisited > 0
                || metrics.directoriesVisited > 0
                || metrics.completedItems > 0
                || metrics.atomicSummaryVisitedItems > 0
                || metrics.isFinalizing
        else {
            return
        }
        observedActiveProgress = true
    }

    func didObserveActiveProgress() -> Bool {
        observedActiveProgress
    }

    func recordTermination(_ outcome: ProgressProbeCancellationOutcome) {
        self.outcome = outcome
    }

    func terminationOutcome() -> ProgressProbeCancellationOutcome? {
        outcome
    }
}

private struct ProgressProbeCancellationOutcome: Sendable {
    let emittedFinished: Bool
    let unexpectedError: String?
}

private nonisolated final class ProgressProbeWorkerActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWorkerCount = 0
    private var poolDidShutdown = false

    var hasActiveWorkers: Bool {
        lock.withLock { activeWorkerCount > 0 }
    }

    var isQuiescent: Bool {
        lock.withLock { activeWorkerCount == 0 }
    }

    var hasShutdown: Bool {
        lock.withLock { poolDidShutdown }
    }

    func didStart() {
        lock.withLock {
            activeWorkerCount += 1
        }
    }

    func didFinish() {
        lock.withLock {
            activeWorkerCount = max(activeWorkerCount - 1, 0)
        }
    }

    func didShutdown() {
        lock.withLock {
            poolDidShutdown = true
        }
    }
}

private nonisolated final class ProgressProbeScanService: ScanEventStreaming, @unchecked Sendable {
    let engine: ScanEngine

    init(engine: ScanEngine) {
        self.engine = engine
    }

    func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        engine.scan(target: target, options: options)
    }

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        _ = baseline
        return scan(target: target, options: options)
    }
}
