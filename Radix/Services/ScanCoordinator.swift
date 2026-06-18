//
//  ScanCoordinator.swift
//  Radix
//

import Combine
import Foundation

enum AppModelPhase: Equatable, Sendable {
    case idle
    case scanning
    case displaying
    case failed
}

protocol ScanEventStreaming: Sendable {
    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error>
}

extension ScanEngine: ScanEventStreaming {}

enum ScanExpansionResult {
    case skipped
    case cancelled
    case expanded(replacementRootID: FileNodeRecord.ID)
    case failed(message: String)
}

@MainActor
final class ScanProgressState: ObservableObject {
    @Published var metrics: ScanMetrics

    init(metrics: ScanMetrics = ScanMetrics()) {
        self.metrics = metrics
    }
}

@MainActor
final class ScanCoordinator: ObservableObject {
    @Published var phase: AppModelPhase = .idle
    @Published var snapshot: ScanSnapshot?
    @Published var selectedTarget: ScanTarget?
    @Published var fileTreeStore: FileTreeStore?
    @Published private(set) var completedScanSnapshot: ScanSnapshot?
    @Published private(set) var scanErrorMessage: String?
    @Published private(set) var expandingNodeID: FileNodeRecord.ID?
    @Published private(set) var trashSafetyPolicy: TrashSafetyPolicy

    let progress: ScanProgressState

    private let scanService: any ScanEventStreaming
    private let snapshotTransformService: any ScanSnapshotTransforming
    private let progressThrottleDuration: Duration
    private let progressClock = ContinuousClock()

    private var scanTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var progressPublishTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var activeExpansionID: UUID?
    private var expansionCompletion: ((ScanExpansionResult) -> Void)?
    private var pendingProgressMetrics: ScanMetrics?
    private var lastProgressPublishTime: ContinuousClock.Instant?

    init(
        scanService: any ScanEventStreaming = ScanEngine(),
        snapshotTransformService: any ScanSnapshotTransforming = ScanSnapshotTransformService(),
        progressThrottleDuration: Duration = .milliseconds(100),
        progress: ScanProgressState = ScanProgressState(),
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) {
        self.scanService = scanService
        self.snapshotTransformService = snapshotTransformService
        self.progressThrottleDuration = progressThrottleDuration
        self.progress = progress
        self.trashSafetyPolicy = trashSafetyPolicy
    }

    var scanMetrics: ScanMetrics {
        get { progress.metrics }
        set { progress.metrics = newValue }
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var canRescan: Bool {
        selectedTarget != nil && !isScanning
    }

    var canStopScan: Bool {
        isScanning
    }

    func replaceTrashSafetyPolicy(_ policy: TrashSafetyPolicy) {
        trashSafetyPolicy = policy
    }

    func startScan(
        _ target: ScanTarget,
        options: ScanOptions,
        prepare: () -> Void = {}
    ) {
        stopScan(resetState: false)
        prepare()

        selectedTarget = target
        phase = .scanning
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        snapshot = nil
        fileTreeStore = nil
        completedScanSnapshot = nil
        resetProgressThrottling()

        let scanID = UUID()
        activeScanID = scanID
        let stream = scanService.scan(target: target, options: options)
        scanTask = Task { [weak self] in
            await self?.consumeScanStream(stream, scanID: scanID)
        }
    }

    func stopScan(resetState: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        resetProgressThrottling()
        cancelExpansion(completeWith: .cancelled)

        var metrics = scanMetrics
        metrics.isFinalizing = false
        scanMetrics = metrics

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
    }

    func clearScan() {
        stopScan(resetState: false)
        selectedTarget = nil
        snapshot = nil
        fileTreeStore = nil
        completedScanSnapshot = nil
        scanMetrics = ScanMetrics()
        phase = .idle
    }

    func replaceCurrentSnapshot(_ snapshot: ScanSnapshot?) {
        self.snapshot = snapshot
        fileTreeStore = snapshot?.treeStore
        if snapshot == nil {
            phase = .idle
        } else if !isScanning {
            phase = .displaying
        }
    }

    func restoreCompletedSnapshot(
        _ snapshot: ScanSnapshot,
        prepare: () -> Void = {}
    ) {
        guard snapshot.isComplete else { return }

        stopScan(resetState: false)
        prepare()

        selectedTarget = snapshot.target
        scanErrorMessage = nil
        resetProgressThrottling()
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot

        var metrics = ScanMetrics()
        metrics.recalculateProgress(isComplete: true)
        scanMetrics = metrics
        phase = .displaying
    }

    @discardableResult
    func removeNodeFromCurrentSnapshot(id nodeID: FileNodeRecord.ID) async -> Bool {
        guard let currentSnapshot = snapshot else { return false }
        let currentSnapshotID = currentSnapshot.id

        if let expandingNodeID,
           currentSnapshot.treeStore.isAncestor(nodeID, of: expandingNodeID) {
            cancelExpansion(completeWith: .cancelled)
        }

        do {
            guard let updatedSnapshot = try await snapshotTransformService.removingNode(
                in: currentSnapshot,
                id: nodeID
            ) else { return false }
            try Task.checkCancellation()
            guard snapshot?.id == currentSnapshotID else { return false }

            snapshot = updatedSnapshot
            fileTreeStore = updatedSnapshot.treeStore
            completedScanSnapshot = nil
            if !isScanning {
                phase = .displaying
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    func expandSummarizedNode(
        _ node: FileNodeRecord,
        options: ScanOptions,
        completion: @escaping (ScanExpansionResult) -> Void
    ) {
        guard node.isAutoSummarized else {
            completion(.skipped)
            return
        }

        cancelExpansion(completeWith: .cancelled)

        let expansionID = UUID()
        activeExpansionID = expansionID
        expandingNodeID = node.id
        expansionCompletion = completion

        let target = ScanTarget(url: node.url)
        let stream = scanService.scan(target: target, options: options)
        expandTask = Task { [weak self] in
            await self?.consumeExpansionStream(stream, node: node, expansionID: expansionID)
        }
    }

    private func consumeScanStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        scanID: UUID
    ) async {
        do {
            for try await event in stream {
                guard activeScanID == scanID else { break }
                handle(event, scanID: scanID)
            }
        } catch is CancellationError {
            completeCancelledScan(scanID: scanID)
            return
        } catch {
            failScan(error, scanID: scanID)
            return
        }

        completeScanIfActive(scanID: scanID)
    }

    private func consumeExpansionStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        node: FileNodeRecord,
        expansionID: UUID
    ) async {
        do {
            var expandedSnapshot: ScanSnapshot?
            for try await event in stream {
                guard activeExpansionID == expansionID else { return }
                if case .finished(let snapshot) = event {
                    expandedSnapshot = snapshot
                }
            }

            try Task.checkCancellation()
            guard activeExpansionID == expansionID else { return }
            guard let expandedSnapshot else {
                completeExpansion(id: expansionID, result: .cancelled)
                return
            }

            let replacementRootID = try await replaceNodeInTree(
                node,
                with: expandedSnapshot,
                expansionID: expansionID
            )
            guard activeExpansionID == expansionID else { return }
            if let replacementRootID {
                completeExpansion(id: expansionID, result: .expanded(replacementRootID: replacementRootID))
            } else {
                completeExpansion(id: expansionID, result: .skipped)
            }
        } catch is CancellationError {
            completeExpansion(id: expansionID, result: .cancelled)
        } catch {
            completeExpansion(
                id: expansionID,
                result: .failed(message: "Failed to expand '\(node.name)': \(error.localizedDescription)")
            )
        }
    }

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .progress(let metrics):
            handleProgress(metrics, scanID: scanID)
        case .warning:
            break
        case .finished(let snapshot):
            finishScan(with: snapshot, scanID: scanID)
        }
    }

    private func handleProgress(_ metrics: ScanMetrics, scanID: UUID) {
        guard activeScanID == scanID else { return }

        if shouldPublishProgressImmediately {
            publishProgress(metrics)
            return
        }

        pendingProgressMetrics = metrics
        schedulePendingProgressPublish(scanID: scanID)
    }

    private var shouldPublishProgressImmediately: Bool {
        guard progressThrottleDuration > .zero else { return true }
        guard let lastProgressPublishTime else { return true }

        return lastProgressPublishTime.duration(to: progressClock.now) >= progressThrottleDuration
    }

    private func schedulePendingProgressPublish(scanID: UUID) {
        guard progressPublishTask == nil else { return }

        let delay: Duration
        if let lastProgressPublishTime {
            let elapsed = lastProgressPublishTime.duration(to: progressClock.now)
            delay = elapsed >= progressThrottleDuration ? .zero : progressThrottleDuration - elapsed
        } else {
            delay = .zero
        }

        progressPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            self?.publishPendingProgress(scanID: scanID)
        }
    }

    private func publishPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask = nil
        guard let pendingProgressMetrics else { return }
        publishProgress(pendingProgressMetrics)
    }

    private func publishProgress(_ metrics: ScanMetrics) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = progressClock.now
        scanMetrics = metrics
    }

    private func finishScan(with snapshot: ScanSnapshot, scanID: UUID) {
        guard activeScanID == scanID else { return }

        flushPendingProgress(scanID: scanID)
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot

        var completedMetrics = scanMetrics
        completedMetrics.recalculateProgress(isComplete: true)
        publishProgress(completedMetrics)

        activeScanID = nil
        scanTask = nil
        phase = .displaying
    }

    private func apply(snapshot: ScanSnapshot) {
        self.snapshot = snapshot
        fileTreeStore = snapshot.treeStore
    }

    private func completeCancelledScan(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        if snapshot == nil {
            phase = .idle
        }
        activeScanID = nil
        scanTask = nil
    }

    private func failScan(_ error: Error, scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        phase = .failed
        scanErrorMessage = error.localizedDescription
        activeScanID = nil
        scanTask = nil
    }

    private func completeScanIfActive(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        phase = snapshot == nil ? .idle : .displaying
        activeScanID = nil
        scanTask = nil
    }

    private func flushPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask?.cancel()
        progressPublishTask = nil

        if let pendingProgressMetrics {
            publishProgress(pendingProgressMetrics)
        }
    }

    private func resetProgressThrottling() {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = nil
    }

    private func cancelExpansion(completeWith result: ScanExpansionResult?) {
        activeExpansionID = nil
        expandingNodeID = nil
        expandTask?.cancel()
        expandTask = nil

        guard let result, let completion = expansionCompletion else {
            expansionCompletion = nil
            return
        }

        expansionCompletion = nil
        completion(result)
    }

    private func completeExpansion(id: UUID, result: ScanExpansionResult) {
        guard activeExpansionID == id else { return }

        activeExpansionID = nil
        expandingNodeID = nil
        expandTask = nil
        guard let completion = expansionCompletion else { return }
        expansionCompletion = nil
        completion(result)
    }

    @discardableResult
    private func replaceNodeInTree(
        _ oldNode: FileNodeRecord,
        with expandedSnapshot: ScanSnapshot,
        expansionID: UUID
    ) async throws -> FileNodeRecord.ID? {
        guard let currentSnapshot = snapshot else { return nil }
        let currentSnapshotID = currentSnapshot.id
        guard let updatedSnapshot = try await snapshotTransformService.replacingNode(
            in: currentSnapshot,
            id: oldNode.id,
            with: expandedSnapshot.treeStore,
            additionalWarnings: expandedSnapshot.scanWarnings
        ) else { return nil }
        try Task.checkCancellation()
        guard activeExpansionID == expansionID,
              snapshot?.id == currentSnapshotID else {
            return nil
        }

        snapshot = updatedSnapshot
        fileTreeStore = updatedSnapshot.treeStore
        return expandedSnapshot.root.id
    }
}
