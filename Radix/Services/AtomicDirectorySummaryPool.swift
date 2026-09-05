//
//  AtomicDirectorySummaryPool.swift
//  Radix
//

import Dispatch
import Foundation

nonisolated private struct AtomicSummaryGenerationInvalidated: Error {}

nonisolated enum AtomicSummaryProgressKind: Sendable {
    case package
    case autoSummary
}

nonisolated private final class AtomicSummaryGenerationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isInvalidated = false

    func check() throws {
        lock.lock()
        let invalidated = isInvalidated
        lock.unlock()
        if invalidated {
            throw AtomicSummaryGenerationInvalidated()
        }
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        lock.unlock()
    }
}

nonisolated struct AtomicSummaryPoolRequest: @unchecked Sendable {
    let url: URL
    let expectedRootIdentity: FileIdentity?
    let includeHiddenFiles: Bool
    let treatPackagesAsDirectories: Bool
    let progressWeight: Double
    let progressKind: AtomicSummaryProgressKind
    /// Direct children already included in ordinary traversal's discovered count.
    let representedItemCount: Int
    let ownerNodeID: String
    let exclusionMatcher: ScanExclusionMatcher
    let metadataLoader: ScanMetadataLoader
    let volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy
    let cancellationCheck: CancellationCheck
    let metrics: ScanMetrics
    let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    let resumeState: AtomicDirectoryProbeResumeState?
}

nonisolated private final class AtomicSummaryProgressCoordinator: @unchecked Sendable {
    private struct JobProgress {
        let weight: Double
        let kind: AtomicSummaryProgressKind
        let representedItemCount: Int
        var generation: Int
        var visitedItems: Int
        var completedVisitedItems = 0
        var completedWorkItems = 0
        var pendingWorkItems: Int
        var visitedByActiveLease: [Int: Int] = [:]
        var latestVisitedPath: String?
        var fraction = 0.0
    }

    private let lock = NSLock()
    /// Worker progress must not call into `AsyncThrowingStream` while holding
    /// `lock`. Stream cancellation can synchronously enter the pool's task
    /// cancellation handler while Swift holds its task-status lock, creating a
    /// lock cycle with workers that are publishing progress. A serial queue
    /// preserves publication order without extending the coordinator lock
    /// across `yield`.
    private let emissionQueue = DispatchQueue(
        label: "com.colinkim.Radix.AtomicSummaryProgress",
        qos: .userInitiated
    )
    private let emissionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var baseMetrics = ScanMetrics()
    private var hasBaseMetrics = false
    private var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation?
    private var jobs: [Int: JobProgress] = [:]
    private var lastEmission = Date.distantPast
    private var progressFloor = 0.0

    init(
        emissionInterval: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.emissionInterval = max(emissionInterval, 0)
        self.now = now
    }

    func updateBase(
        _ metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        currentPath: String? = nil,
        force: Bool = false
    ) {
        lock.lock()
        var canonical = metrics
        Self.clearAtomicSummaryOverlay(in: &canonical)
        canonical.progressFraction = max(canonical.progressFraction, progressFloor)
        if let currentPath {
            canonical.currentPath = currentPath
        }
        baseMetrics = canonical
        hasBaseMetrics = true
        self.continuation = continuation
        let event = progressEventIfDueLocked(currentPath: currentPath, force: force)
        let enqueuedEmission = enqueueLocked(event, continuation: continuation)
        lock.unlock()
        if enqueuedEmission {
            flushEmissions()
        }
    }

    func reportCurrentPath(
        _ currentPath: String,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        lock.lock()
        self.continuation = continuation
        let enqueuedEmission = emitIfDueLocked(currentPath: currentPath, force: false)
        lock.unlock()
        if enqueuedEmission {
            flushEmissions()
        }
    }

    func register(
        jobID: Int,
        generation: Int,
        progressWeight: Double,
        progressKind: AtomicSummaryProgressKind,
        representedItemCount: Int,
        initialVisitedItems: Int,
        initialWorkItems: Int,
        requestMetrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        lock.lock()
        if !hasBaseMetrics {
            var canonical = requestMetrics
            Self.clearAtomicSummaryOverlay(in: &canonical)
            baseMetrics = canonical
            hasBaseMetrics = true
        }
        self.continuation = continuation
        jobs[jobID] = JobProgress(
            weight: max(progressWeight, 0),
            kind: progressKind,
            representedItemCount: max(representedItemCount, 0),
            generation: generation,
            visitedItems: max(initialVisitedItems, 0),
            pendingWorkItems: max(initialWorkItems, 0)
        )
        lock.unlock()
    }

    func workStarted(jobID: Int, generation: Int, leaseID: Int) {
        lock.lock()
        guard var job = jobs[jobID], job.generation == generation else {
            lock.unlock()
            return
        }
        job.pendingWorkItems = max(job.pendingWorkItems - 1, 0)
        job.visitedByActiveLease[leaseID] = 0
        jobs[jobID] = job
        lock.unlock()
    }

    func recordVisited(
        jobID: Int,
        generation: Int,
        leaseID: Int,
        delta: Int,
        currentPath: String
    ) {
        guard delta > 0 else { return }
        lock.lock()
        guard var job = jobs[jobID], job.generation == generation else {
            lock.unlock()
            return
        }
        job.visitedItems = Self.saturatingAdd(job.visitedItems, delta)
        job.visitedByActiveLease[leaseID] = Self.saturatingAdd(
            job.visitedByActiveLease[leaseID] ?? 0,
            delta
        )
        job.latestVisitedPath = currentPath
        jobs[jobID] = job
        _ = emitIfDueLocked(currentPath: currentPath, force: false)
        lock.unlock()
    }

    func workFinished(
        jobID: Int,
        generation: Int,
        leaseID: Int,
        discoveredWorkItems: Int,
        currentPath: String
    ) {
        lock.lock()
        guard var job = jobs[jobID], job.generation == generation else {
            lock.unlock()
            return
        }
        let visited = job.visitedByActiveLease.removeValue(forKey: leaseID) ?? 0
        job.completedVisitedItems = Self.saturatingAdd(job.completedVisitedItems, visited)
        job.completedWorkItems = Self.saturatingAdd(job.completedWorkItems, 1)
        job.pendingWorkItems = Self.saturatingAdd(
            job.pendingWorkItems,
            max(discoveredWorkItems, 0)
        )
        jobs[jobID] = job
        _ = emitIfDueLocked(currentPath: job.latestVisitedPath ?? currentPath, force: false)
        lock.unlock()
    }

    func restart(
        jobID: Int,
        generation: Int,
        pendingWorkItems: Int,
        currentPath: String
    ) {
        lock.lock()
        guard var job = jobs[jobID], generation > job.generation else {
            lock.unlock()
            return
        }
        job.generation = generation
        job.completedVisitedItems = 0
        job.completedWorkItems = 0
        job.pendingWorkItems = max(pendingWorkItems, 0)
        job.visitedByActiveLease.removeAll()
        job.latestVisitedPath = nil
        jobs[jobID] = job
        _ = emitIfDueLocked(currentPath: currentPath, force: false)
        lock.unlock()
    }

    func finish(jobID: Int, currentPath: String) -> Int? {
        lock.lock()
        guard var job = jobs[jobID] else {
            lock.unlock()
            return nil
        }
        job.pendingWorkItems = 0
        job.visitedByActiveLease.removeAll()
        job.fraction = 1
        jobs[jobID] = job
        _ = emitIfDueLocked(currentPath: currentPath, force: true)
        jobs.removeValue(forKey: jobID)
        lock.unlock()
        return job.visitedItems
    }

    func cancel(jobID: Int, currentPath: String?) {
        lock.lock()
        jobs.removeValue(forKey: jobID)
        _ = emitIfDueLocked(currentPath: currentPath, force: false)
        lock.unlock()
    }

    func flushEmissions() {
        emissionQueue.sync {}
    }

    @discardableResult
    private func emitIfDueLocked(currentPath: String?, force: Bool) -> Bool {
        guard let event = progressEventIfDueLocked(currentPath: currentPath, force: force),
              let continuation else {
            return false
        }
        return enqueueLocked(event, continuation: continuation)
    }

    private func enqueueLocked(
        _ event: ScanMetrics?,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) -> Bool {
        guard let event else { return false }
        emissionQueue.async {
            _ = continuation.yield(.progress(event))
        }
        return true
    }

    private func progressEventIfDueLocked(
        currentPath: String?,
        force: Bool
    ) -> ScanMetrics? {
        let timestamp = now()
        guard force || timestamp.timeIntervalSince(lastEmission) >= emissionInterval else {
            return nil
        }
        lastEmission = timestamp
        return makeSnapshotLocked(currentPath: currentPath)
    }

    private func makeSnapshotLocked(currentPath: String?) -> ScanMetrics {
        var snapshot = baseMetrics
        if let currentPath {
            snapshot.currentPath = currentPath
        }

        var completedWeight = 0.0
        var visitedItems = 0
        var estimatedRemainingItems = 0
        var activePackageCount = 0
        var activePackageVisitedItems = 0
        var activePackageEstimatedRemainingItems = 0
        var activeAutoSummaryRepresentedItems = 0
        for jobID in Array(jobs.keys) {
            guard var job = jobs[jobID] else { continue }
            let estimate = Self.estimate(for: job)
            job.fraction = max(job.fraction, estimate.fraction)
            jobs[jobID] = job
            completedWeight += job.weight * job.fraction
            visitedItems += job.visitedItems
            estimatedRemainingItems += estimate.remainingItems
            switch job.kind {
            case .package:
                activePackageCount += 1
                activePackageVisitedItems = Self.saturatingAdd(
                    activePackageVisitedItems,
                    job.visitedItems
                )
                activePackageEstimatedRemainingItems = Self.saturatingAdd(
                    activePackageEstimatedRemainingItems,
                    estimate.remainingItems
                )
            case .autoSummary:
                activeAutoSummaryRepresentedItems = Self.saturatingAdd(
                    activeAutoSummaryRepresentedItems,
                    job.representedItemCount
                )
            }
        }

        snapshot.atomicSummaryCompletedTraversalWeight = min(max(completedWeight, 0), 1)
        snapshot.atomicSummaryVisitedItems = max(visitedItems, 0)
        snapshot.atomicSummaryEstimatedRemainingItems = max(estimatedRemainingItems, 0)
        snapshot.activeAtomicSummaryCount = jobs.count
        snapshot.activePackageSummaryCount = activePackageCount
        snapshot.activePackageSummaryVisitedItems = activePackageVisitedItems
        snapshot.activePackageSummaryEstimatedRemainingItems = activePackageEstimatedRemainingItems
        snapshot.activeAutoSummaryRepresentedItemCount = activeAutoSummaryRepresentedItems
        snapshot.recalculateProgress()
        snapshot.progressFraction = max(snapshot.progressFraction, progressFloor)
        progressFloor = snapshot.progressFraction
        return snapshot
    }

    private static func estimate(for job: JobProgress) -> (fraction: Double, remainingItems: Int) {
        guard job.fraction < 1 else { return (1, 0) }
        let observedAverage = max(
            ScanMetrics.unobservedSummaryEstimatedItemCount,
            job.completedVisitedItems / max(job.completedWorkItems, 1)
        )
        var activeRemaining = 0
        for visited in job.visitedByActiveLease.values {
            activeRemaining = saturatingAdd(
                activeRemaining,
                max(ScanMetrics.unobservedSummaryEstimatedItemCount, visited, observedAverage)
            )
        }
        let pendingProduct = job.pendingWorkItems.multipliedReportingOverflow(by: observedAverage)
        let pendingRemaining = pendingProduct.overflow
            ? Int.max
            : max(pendingProduct.partialValue, 0)
        let remaining = saturatingAdd(activeRemaining, pendingRemaining)
        let denominator = Double(job.visitedItems) + Double(remaining)
        let rawFraction = denominator > 0 ? Double(job.visitedItems) / denominator : 0
        return (min(max(rawFraction, 0), 0.95), max(remaining, 0))
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : max(result.partialValue, 0)
    }

    private static func clearAtomicSummaryOverlay(in metrics: inout ScanMetrics) {
        metrics.atomicSummaryCompletedTraversalWeight = 0
        metrics.atomicSummaryVisitedItems = 0
        metrics.atomicSummaryEstimatedRemainingItems = 0
        metrics.activeAtomicSummaryCount = 0
        metrics.activePackageSummaryCount = 0
        metrics.activePackageSummaryVisitedItems = 0
        metrics.activePackageSummaryEstimatedRemainingItems = 0
        metrics.activeAutoSummaryRepresentedItemCount = 0
    }
}

nonisolated struct AtomicSummaryWorkerObserver: Sendable {
    let didStart: @Sendable (_ ownerNodeID: String, _ itemURL: URL) -> Void
    let didFinish: @Sendable (_ ownerNodeID: String, _ itemURL: URL) -> Void
    let didShutdown: @Sendable () -> Void

    init(
        didStart: @escaping @Sendable (_ ownerNodeID: String, _ itemURL: URL) -> Void,
        didFinish: @escaping @Sendable (_ ownerNodeID: String, _ itemURL: URL) -> Void,
        didShutdown: @escaping @Sendable () -> Void = {}
    ) {
        self.didStart = didStart
        self.didFinish = didFinish
        self.didShutdown = didShutdown
    }
}

/// A scan-scoped worker pool shared by every package and atomic-summary job.
///
/// The pool owns exactly `workerLimit` workers. Jobs keep independent work
/// stacks and accumulators, while runnable jobs are selected round-robin so a
/// deep package cannot starve newly discovered small bundles.
nonisolated final class AtomicDirectorySummaryPool: @unchecked Sendable {
    private struct Lease: @unchecked Sendable {
        let jobID: Int
        let generation: Int
        let leaseID: Int
        let token: AtomicSummaryGenerationToken
        let item: AtomicSummaryWorkItem
        let request: AtomicSummaryPoolRequest
        let forcesFoundationTraversal: Bool
    }

    private final class Job {
        let id: Int
        let request: AtomicSummaryPoolRequest
        let continuation: CheckedContinuation<AtomicDirectorySummary?, Error>
        var generation = 0
        var token = AtomicSummaryGenerationToken()
        var accumulator: AtomicSummaryAccumulator
        var pendingItems: [AtomicSummaryWorkItem]
        var activeCountByGeneration: [Int: Int] = [:]
        var forcesFoundationTraversal = false
        var isRunnable = false

        init(
            id: Int,
            request: AtomicSummaryPoolRequest,
            continuation: CheckedContinuation<AtomicDirectorySummary?, Error>,
            accumulator: AtomicSummaryAccumulator,
            pendingItems: [AtomicSummaryWorkItem]
        ) {
            self.id = id
            self.request = request
            self.continuation = continuation
            self.accumulator = accumulator
            self.pendingItems = pendingItems
        }
    }

    private enum CompletionAction {
        case success(
            CheckedContinuation<AtomicDirectorySummary?, Error>,
            AtomicSummaryAccumulator
        )
        case failure(
            CheckedContinuation<AtomicDirectorySummary?, Error>,
            Error
        )

        func resume(visitedItemCount: Int? = nil) {
            switch self {
            case .success(let continuation, let accumulator):
                continuation.resume(returning: accumulator.makeSummary(
                    visitedItemCount: visitedItemCount
                ))
            case .failure(let continuation, let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private let condition = NSCondition()
    private let workerLimit: Int
    private let workerObserver: AtomicSummaryWorkerObserver?
    private let progressCoordinator: AtomicSummaryProgressCoordinator
    private var nextJobID = 0
    private var nextLeaseID = 0
    private var jobs: [Int: Job] = [:]
    private var cancelledJobIDs: Set<Int> = []
    private var runnableJobIDs: [Int] = []
    private var waitingWorkers: [CheckedContinuation<Lease?, Never>] = []
    private var workerTasks: [Task<Void, Never>] = []
    private var hasStarted = false
    private var acceptsJobs = true
    private var shutdownError: Error?
    private var hasNotifiedShutdown = false

    init(
        workerLimit: Int,
        workerObserver: AtomicSummaryWorkerObserver? = nil,
        progressEmissionInterval: TimeInterval = 0.15,
        progressNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.workerLimit = max(1, workerLimit)
        self.workerObserver = workerObserver
        self.progressCoordinator = AtomicSummaryProgressCoordinator(
            emissionInterval: progressEmissionInterval,
            now: progressNow
        )
    }

    func updateProgress(
        _ metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        currentPath: String? = nil,
        force: Bool = false
    ) {
        progressCoordinator.updateBase(
            metrics,
            continuation: continuation,
            currentPath: currentPath,
            force: force
        )
    }

    func reportCurrentPath(
        _ currentPath: String,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        progressCoordinator.reportCurrentPath(
            currentPath,
            continuation: continuation
        )
    }

    /// Starts the fixed worker set. Calling this more than once has no effect.
    func start() {
        condition.lock()
        guard !hasStarted else {
            condition.unlock()
            return
        }
        hasStarted = true
        let tasks = (0..<workerLimit).map { _ in
            Task {
                await self.workerLoop()
            }
        }
        workerTasks = tasks
        condition.unlock()
    }

    /// Stops accepting jobs, drains registered jobs, and awaits every worker.
    func finish() async {
        let tasks = finishAcceptingJobs()
        for task in tasks {
            await task.value
        }
        progressCoordinator.flushEmissions()
        notifyShutdownOnce()
    }

    /// Fails all registered jobs, wakes workers, and awaits their termination.
    func cancelAndFinish(with error: Error) async {
        let tasks = cancelAll(with: error)
        for task in tasks {
            await task.value
        }
        progressCoordinator.flushEmissions()
        notifyShutdownOnce()
    }

    /// Convenience structured lifetime for callers that do not need to mutate
    /// inout scan state from the operation closure.
    func run<T: Sendable>(
        operation: () async throws -> T
    ) async throws -> T {
        start()
        do {
            let result = try await operation()
            await finish()
            return result
        } catch {
            await cancelAndFinish(with: error)
            throw error
        }
    }

    func summarize(_ request: AtomicSummaryPoolRequest) async throws -> AtomicDirectorySummary? {
        start()
        try request.cancellationCheck()
        let jobID = reserveJobID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerJob(id: jobID, request: request, continuation: continuation)
            }
        } onCancel: {
            self.cancelJob(id: jobID, error: CancellationError())
        }
    }

    private func reserveJobID() -> Int {
        condition.lock()
        let id = nextJobID
        nextJobID += 1
        condition.unlock()
        return id
    }

    private func registerJob(
        id: Int,
        request: AtomicSummaryPoolRequest,
        continuation: CheckedContinuation<AtomicDirectorySummary?, Error>
    ) {
        let accumulator = makeInitialAccumulator(for: request, usesResumeState: true)
        let initialItems = request.resumeState?.workItems ?? [
            AtomicSummaryWorkItem(
                url: request.url,
                treatPackagesAsDirectories: request.treatPackagesAsDirectories,
                ownerNodeID: request.ownerNodeID,
                expectedIdentity: request.expectedRootIdentity,
                volumeBoundaryPolicy: request.volumeBoundaryPolicy
            )
        ]

        var rejection: Error?
        var completion: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if cancelledJobIDs.remove(id) != nil {
            rejection = CancellationError()
        } else if let shutdownError {
            rejection = shutdownError
        } else if !acceptsJobs {
            rejection = CancellationError()
        } else {
            let job = Job(
                id: id,
                request: request,
                continuation: continuation,
                accumulator: accumulator,
                pendingItems: initialItems
            )
            jobs[id] = job
            progressCoordinator.register(
                jobID: id,
                generation: job.generation,
                progressWeight: request.progressWeight,
                progressKind: request.progressKind,
                representedItemCount: request.representedItemCount,
                initialVisitedItems: request.resumeState?.visitedItemCount ?? 0,
                initialWorkItems: initialItems.count,
                requestMetrics: request.metrics,
                continuation: request.continuation
            )
            makeRunnableLocked(job)
            completion = completeJobIfNeededLocked(job)
            wakeups = wakeWorkersLocked()
        }
        condition.unlock()
        resumeWorkerWakeups(wakeups)

        if let rejection {
            continuation.resume(throwing: rejection)
        } else {
            let visitedItemCount = completion == nil
                ? nil
                : progressCoordinator.finish(jobID: id, currentPath: request.url.path)
            completion?.resume(visitedItemCount: visitedItemCount)
        }
    }

    private func makeInitialAccumulator(
        for request: AtomicSummaryPoolRequest,
        usesResumeState: Bool
    ) -> AtomicSummaryAccumulator {
        if usesResumeState, let partial = request.resumeState?.partial {
            return AtomicSummaryAccumulator(seed: partial)
        }

        let accumulator = AtomicSummaryAccumulator()
        do {
            // Seed accessibility without invoking unrelated package classification.
            let values = try request.url.resourceValues(forKeys: [.isReadableKey])
            accumulator.updateAccessibility(values.isReadable ?? false)
        } catch {
            accumulator.recordWarning(for: request.url, error: error)
        }
        return accumulator
    }

    private func workerLoop() async {
        while let lease = await takeWork() {
            workerObserver?.didStart(lease.item.ownerNodeID, lease.item.url)
            let progressReporter = AtomicSummaryProgressReporter(
                metrics: lease.request.metrics,
                continuation: lease.request.continuation,
                visitHandler: { delta, currentURL in
                    self.progressCoordinator.recordVisited(
                        jobID: lease.jobID,
                        generation: lease.generation,
                        leaseID: lease.leaseID,
                        delta: delta,
                        currentPath: currentURL.path
                    )
                }
            )
            do {
                let result = try AtomicDirectorySummarizer.processPooledWorkItem(
                    lease.item,
                    includeHiddenFiles: lease.request.includeHiddenFiles,
                    exclusionMatcher: lease.request.exclusionMatcher,
                    metadataLoader: lease.request.metadataLoader,
                    cancellationCheck: {
                        try lease.request.cancellationCheck()
                        try lease.token.check()
                    },
                    progressReporter: progressReporter,
                    forcesFoundationTraversal: lease.forcesFoundationTraversal
                )
                workerObserver?.didFinish(lease.item.ownerNodeID, lease.item.url)
                complete(lease, result: result)
            } catch is AtomicSummaryRootFallbackRequired {
                workerObserver?.didFinish(lease.item.ownerNodeID, lease.item.url)
                restartUsingFoundation(lease)
            } catch is AtomicSummaryGenerationInvalidated {
                workerObserver?.didFinish(lease.item.ownerNodeID, lease.item.url)
                discard(lease)
            } catch {
                workerObserver?.didFinish(lease.item.ownerNodeID, lease.item.url)
                fail(lease, error: error)
            }
        }
    }

    private func takeWork() async -> Lease? {
        await withCheckedContinuation { continuation in
            condition.lock()
            if let lease = nextLeaseLocked() {
                condition.unlock()
                continuation.resume(returning: lease)
            } else if workersShouldStopLocked {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingWorkers.append(continuation)
                condition.unlock()
            }
        }
    }

    private func complete(_ lease: Lease, result: AtomicSummaryWorkResult) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            decrementActiveLocked(job, generation: lease.generation)
            if job.generation == lease.generation {
                job.accumulator.merge(result.partial)
                job.pendingItems.append(contentsOf: result.pendingItems)
                makeRunnableLocked(job)
                action = completeJobIfNeededLocked(job)
            }
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        progressCoordinator.workFinished(
            jobID: lease.jobID,
            generation: lease.generation,
            leaseID: lease.leaseID,
            discoveredWorkItems: result.pendingItems.count,
            currentPath: lease.item.url.path
        )
        resumeWorkerWakeups(wakeups)
        let visitedItemCount = action == nil
            ? nil
            : progressCoordinator.finish(jobID: lease.jobID, currentPath: lease.item.url.path)
        action?.resume(visitedItemCount: visitedItemCount)
    }

    private func restartUsingFoundation(_ lease: Lease) {
        var cursorsToInvalidate: AtomicDirectoryProbeResumeState?
        var restartRequest: AtomicSummaryPoolRequest?
        var restartGeneration: Int?
        condition.lock()
        if let job = jobs[lease.jobID] {
            decrementActiveLocked(job, generation: lease.generation)
            if job.generation == lease.generation {
                job.token.invalidate()
                job.generation += 1
                job.token = AtomicSummaryGenerationToken()
                job.pendingItems.removeAll(keepingCapacity: true)
                cursorsToInvalidate = job.request.resumeState
                restartRequest = job.request
                restartGeneration = job.generation
            }
        }
        condition.unlock()
        cursorsToInvalidate?.invalidateCursors()

        guard let restartRequest, let restartGeneration else { return }
        let accumulator = makeInitialAccumulator(for: restartRequest, usesResumeState: false)
        // Advance progress bookkeeping before the restarted item can be leased.
        // Otherwise `workStarted` can race against the previous generation and
        // reject the new lease's first visits.
        progressCoordinator.restart(
            jobID: lease.jobID,
            generation: restartGeneration,
            pendingWorkItems: 1,
            currentPath: restartRequest.url.path
        )
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID], job.generation == restartGeneration {
            job.accumulator = accumulator
            job.forcesFoundationTraversal = true
            job.pendingItems.append(
                AtomicSummaryWorkItem(
                    url: job.request.url,
                    treatPackagesAsDirectories: job.request.treatPackagesAsDirectories,
                    ownerNodeID: job.request.ownerNodeID,
                    expectedIdentity: job.request.expectedRootIdentity,
                    volumeBoundaryPolicy: job.request.volumeBoundaryPolicy
                )
            )
            makeRunnableLocked(job)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
    }

    private func discard(_ lease: Lease) {
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            decrementActiveLocked(job, generation: lease.generation)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
    }

    private func fail(_ lease: Lease, error: Error) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            decrementActiveLocked(job, generation: lease.generation)
            if job.generation == lease.generation {
                job.token.invalidate()
                jobs.removeValue(forKey: job.id)
                runnableJobIDs.removeAll { $0 == job.id }
                action = .failure(job.continuation, error)
            }
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        if action != nil {
            progressCoordinator.cancel(jobID: lease.jobID, currentPath: lease.item.url.path)
        }
        resumeWorkerWakeups(wakeups)
        action?.resume()
    }

    private func cancelJob(id: Int, error: Error) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs.removeValue(forKey: id) {
            job.token.invalidate()
            runnableJobIDs.removeAll { $0 == id }
            action = .failure(job.continuation, error)
        } else if acceptsJobs, shutdownError == nil {
            // Cancellation can race registration while the submitter prepares
            // root metadata. Retain a tombstone so a late registration cannot
            // create orphaned work after its awaiting task has been cancelled.
            cancelledJobIDs.insert(id)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        progressCoordinator.cancel(jobID: id, currentPath: nil)
        resumeWorkerWakeups(wakeups)
        action?.resume()
    }

    private func finishAcceptingJobs() -> [Task<Void, Never>] {
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        acceptsJobs = false
        let tasks = workerTasks
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        return tasks
    }

    private func notifyShutdownOnce() {
        condition.lock()
        let shouldNotify = !hasNotifiedShutdown
        hasNotifiedShutdown = true
        condition.unlock()
        if shouldNotify {
            workerObserver?.didShutdown()
        }
    }

    private func cancelAll(with error: Error) -> [Task<Void, Never>] {
        var actions: [CompletionAction] = []
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        shutdownError = error
        acceptsJobs = false
        for job in jobs.values {
            job.token.invalidate()
            actions.append(.failure(job.continuation, error))
            progressCoordinator.cancel(jobID: job.id, currentPath: nil)
        }
        jobs.removeAll()
        cancelledJobIDs.removeAll()
        runnableJobIDs.removeAll()
        let tasks = workerTasks
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        actions.forEach { $0.resume() }
        return tasks
    }

    private func makeRunnableLocked(_ job: Job) {
        guard !job.pendingItems.isEmpty, !job.isRunnable else { return }
        job.isRunnable = true
        runnableJobIDs.append(job.id)
    }

    private func decrementActiveLocked(_ job: Job, generation: Int) {
        let count = max(job.activeCountByGeneration[generation, default: 0] - 1, 0)
        if count == 0 {
            job.activeCountByGeneration.removeValue(forKey: generation)
        } else {
            job.activeCountByGeneration[generation] = count
        }
    }

    private func completeJobIfNeededLocked(_ job: Job) -> CompletionAction? {
        guard job.pendingItems.isEmpty,
              job.activeCountByGeneration[job.generation, default: 0] == 0 else {
            return nil
        }
        jobs.removeValue(forKey: job.id)
        runnableJobIDs.removeAll { $0 == job.id }
        return .success(job.continuation, job.accumulator)
    }

    private func nextLeaseLocked() -> Lease? {
        while let jobID = runnableJobIDs.first {
            runnableJobIDs.removeFirst()
            guard let job = jobs[jobID], !job.pendingItems.isEmpty else {
                continue
            }
            job.isRunnable = false
            let item = job.pendingItems.removeLast()
            let leaseID = nextLeaseID
            nextLeaseID += 1
            job.activeCountByGeneration[job.generation, default: 0] += 1
            makeRunnableLocked(job)
            let lease = Lease(
                jobID: job.id,
                generation: job.generation,
                leaseID: leaseID,
                token: job.token,
                item: item,
                request: job.request,
                forcesFoundationTraversal: job.forcesFoundationTraversal
            )
            progressCoordinator.workStarted(
                jobID: job.id,
                generation: job.generation,
                leaseID: leaseID
            )
            return lease
        }
        return nil
    }

    private var workersShouldStopLocked: Bool {
        shutdownError != nil || (!acceptsJobs && jobs.isEmpty)
    }

    private func wakeWorkersLocked() -> [(CheckedContinuation<Lease?, Never>, Lease?)] {
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        while !waitingWorkers.isEmpty {
            if let lease = nextLeaseLocked() {
                wakeups.append((waitingWorkers.removeFirst(), lease))
            } else if workersShouldStopLocked {
                while !waitingWorkers.isEmpty {
                    wakeups.append((waitingWorkers.removeFirst(), nil))
                }
                break
            } else {
                break
            }
        }
        return wakeups
    }

    private func resumeWorkerWakeups(
        _ wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)]
    ) {
        for (continuation, lease) in wakeups {
            continuation.resume(returning: lease)
        }
    }
}
