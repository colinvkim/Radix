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

nonisolated protocol ScanEventStreaming: Sendable {
    nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error>
    nonisolated func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
    nonisolated func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions,
        preservingMaterializedDirectoriesIn treeStore: FileTreeStore
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
    nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
    nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot,
        relistingDirectoryPaths: [String]
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
}

extension ScanEventStreaming {
    nonisolated func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions,
        preservingMaterializedDirectoriesIn treeStore: FileTreeStore
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scanSubtree(target: target, preservingBehaviorOf: scanTarget, options: options)
    }

    nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot,
        relistingDirectoryPaths: [String]
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        rescan(target: target, options: options, from: baseline)
    }

    nonisolated func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
    }
}

enum ScanExpansionResult {
    case skipped
    case cancelled
    case expanded(replacementRootID: FileNodeRecord.ID)
    case failed(message: String)
}

nonisolated enum ScanCompletionNotice: Equatable, Sendable {
    case incrementalUpdated
    case noChanges
    case fullFallback(IncrementalRescanFallbackReason)
    case folderUpdated(name: String)

    var automaticallyDismisses: Bool {
        switch self {
        case .incrementalUpdated, .noChanges, .folderUpdated: true
        case .fullFallback: false
        }
    }
}

nonisolated struct FolderRescanState: Equatable, Sendable {
    let nodeName: String
    var isBackground = false
}

nonisolated enum FolderRescanResult: Equatable, Sendable {
    case updated
    case cancelled
    case failed
}

nonisolated struct VolumeCapacityRefresh: Equatable, Sendable {
    let capacity: VolumeCapacitySnapshot?
    let reconcilesTree: Bool
}

@MainActor
final class ScanProgressState: ObservableObject {
    @Published var metrics: ScanMetrics
    @Published var executionMode: ScanExecutionMode?

    init(
        metrics: ScanMetrics = ScanMetrics(),
        executionMode: ScanExecutionMode? = nil
    ) {
        self.metrics = metrics
        self.executionMode = executionMode
    }
}

@MainActor
final class ScanCoordinator: ObservableObject {
    struct WorkspaceState {
        let snapshot: ScanSnapshot?
        let completedSnapshot: ScanSnapshot?
        let target: ScanTarget?
        let phase: AppModelPhase
        let metrics: ScanMetrics
        let executionMode: ScanExecutionMode?
        let errorMessage: String?
        let completionNotice: ScanCompletionNotice?
    }

    @Published var phase: AppModelPhase = .idle
    @Published private(set) var snapshot: ScanSnapshot?
    @Published var selectedTarget: ScanTarget?
    @Published private(set) var completedScanSnapshot: ScanSnapshot?
    @Published private(set) var scanErrorMessage: String?
    @Published private(set) var expandingNodeID: FileNodeRecord.ID? {
        didSet {
            if oldValue != nil, expandingNodeID == nil { notifyWhenIdle() }
        }
    }
    @Published private(set) var trashSafetyPolicy: TrashSafetyPolicy
    @Published private(set) var scanCompletionNotice: ScanCompletionNotice?
    @Published private(set) var folderRescanState: FolderRescanState?
    @Published private(set) var backgroundRefreshManualRescanNodeIDs: Set<FileNodeRecord.ID> = []

    let progress: ScanProgressState

    private let scanService: any ScanEventStreaming
    private let snapshotTransformService: any ScanSnapshotTransforming
    private let volumeCapacityProvider: @Sendable (URL) async -> VolumeCapacityRefresh
    private let progressThrottleDuration: Duration
    private let progressNow: () -> ContinuousClock.Instant
    private let sleepForProgress: (Duration) async throws -> Void

    private(set) var scanTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var progressPublishTask: Task<Void, Never>?
    private var completionNoticeDismissTask: Task<Void, Never>?
    private var activeScanID: UUID? {
        didSet {
            if oldValue != nil, activeScanID == nil { notifyWhenIdle() }
        }
    }
    private var activeExpansionID: UUID?
    private var expansionCompletion: ((ScanExpansionResult) -> Void)?
    private var pendingProgressMetrics: ScanMetrics?
    private var lastProgressPublishTime: ContinuousClock.Instant?
    private var snapshotContextID = UUID()
    private var snapshotRevision: UInt64 = 0
    private var activeFolderRescanNodeID: FileNodeRecord.ID?
    var onScanFinished: ((ScanSnapshot) -> Void)?
    var onBecameIdle: (() -> Void)?
    var onFolderRescanStarted: ((FileNodeRecord.ID) -> Void)?
    var onFolderRescanFinished: ((FileNodeRecord.ID, FolderRescanResult) -> Void)?
    var canApplyBackgroundRefresh: () -> Bool = { true }

    private func notifyWhenIdle() {
        guard !isScanOperationInProgress, expandingNodeID == nil else { return }
        onBecameIdle?()
    }

    init(
        scanService: any ScanEventStreaming = IncrementalScanService(),
        snapshotTransformService: any ScanSnapshotTransforming = ScanSnapshotTransformService(),
        volumeCapacityProvider: @escaping @Sendable (URL) async -> VolumeCapacityRefresh = { url in
            await Task.detached(priority: .utility) {
                let capacity = (try? ScanMetadataLoader().metadata(
                    for: url,
                    includeVolumeDetails: true
                ))?.volumeCapacity
                let fileSystemType = ScanEngine.defaultVolumeFileSystemType(for: url)
                return VolumeCapacityRefresh(
                    capacity: capacity,
                    reconcilesTree: fileSystemType.map {
                        ScanEngine.shouldReconcileVolumeCapacity(fileSystemType: $0)
                    } ?? false
                )
            }.value
        },
        progressThrottleDuration: Duration = .milliseconds(100),
        progressNow: @escaping () -> ContinuousClock.Instant = { .now },
        sleepForProgress: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        progress: ScanProgressState = ScanProgressState(),
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) {
        self.scanService = scanService
        self.snapshotTransformService = snapshotTransformService
        self.volumeCapacityProvider = volumeCapacityProvider
        self.progressThrottleDuration = progressThrottleDuration
        self.progressNow = progressNow
        self.sleepForProgress = sleepForProgress
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

    var isScanOperationInProgress: Bool {
        activeScanID != nil
    }

    var isForegroundScanOperationInProgress: Bool {
        isScanOperationInProgress && folderRescanState?.isBackground != true
    }

    var canRescan: Bool {
        selectedTarget != nil && !isForegroundScanOperationInProgress
    }

    var canStopScan: Bool {
        isForegroundScanOperationInProgress
    }

    var snapshotSource: ScanSnapshotSource {
        snapshot?.source ?? .live
    }

    var fileTreeStore: FileTreeStore? {
        snapshot?.treeStore
    }

    func replaceTrashSafetyPolicy(_ policy: TrashSafetyPolicy) {
        trashSafetyPolicy = policy
    }

    func canRescanFolder(id nodeID: FileNodeRecord.ID) -> Bool {
        canRefreshFolder(id: nodeID, allowsFolderRoot: false, isBackground: false)
    }

    func canRefreshFolderInBackground(id nodeID: FileNodeRecord.ID) -> Bool {
        !backgroundRefreshManualRescanNodeIDs.contains(nodeID)
            && canRefreshFolder(id: nodeID, allowsFolderRoot: true, isBackground: true)
    }

    private func canRefreshFolder(
        id nodeID: FileNodeRecord.ID,
        allowsFolderRoot: Bool,
        isBackground: Bool
    ) -> Bool {
        guard !(isBackground ? isScanOperationInProgress : isForegroundScanOperationInProgress),
              expandingNodeID == nil,
              let snapshot,
              snapshot.isComplete,
              snapshot.source.allowsFileMutation,
              let options = snapshot.scanOptions,
              let node = snapshot.treeStore.node(id: nodeID) else {
            return false
        }
        return node.isDirectory
            && !node.isSymbolicLink
            && !node.isSynthetic
            && (!node.isPackage || options.treatPackagesAsDirectories)
            && (nodeID != snapshot.root.id || (allowsFolderRoot && snapshot.target.kind == .folder))
    }

    func startScan(
        _ target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot? = nil,
        isRescan: Bool = false,
        prepare: () -> Void = {}
    ) {
        stopScan(resetState: false)
        dismissScanCompletionNotice()
        prepare()

        selectedTarget = target
        phase = .scanning
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        progress.executionMode = isRescan ? .preparingIncremental : nil
        publishSnapshot(nil, startsNewContext: true)
        completedScanSnapshot = nil
        resetProgressThrottling()

        let scanID = UUID()
        activeScanID = scanID
        let stream: AsyncThrowingStream<ScanProgressEvent, Error>
        if let baseline {
            stream = scanService.rescan(target: target, options: options, from: baseline)
        } else {
            stream = scanService.scan(target: target, options: options)
        }
        scanTask = Task { [weak self] in
            await self?.consumeScanStream(stream, scanID: scanID)
        }
    }

    @discardableResult
    func rescanFolder(id nodeID: FileNodeRecord.ID) -> Bool {
        startFolderRescan(id: nodeID, isBackground: false)
    }

    @discardableResult
    func refreshFolderInBackground(id nodeID: FileNodeRecord.ID) -> Bool {
        startFolderRescan(id: nodeID, isBackground: true)
    }

    private func startFolderRescan(id nodeID: FileNodeRecord.ID, isBackground: Bool) -> Bool {
        guard (isBackground ? canRefreshFolderInBackground(id: nodeID) : canRescanFolder(id: nodeID)),
              let baseline = snapshot,
              let node = baseline.treeStore.node(id: nodeID),
              var options = baseline.scanOptions else {
            return false
        }

        if !isBackground, folderRescanState?.isBackground == true {
            stopScan(resetState: false)
        }
        cancelExpansion(completeWith: .cancelled)
        if !isBackground {
            dismissScanCompletionNotice()
            scanErrorMessage = nil
            scanMetrics = ScanMetrics()
            progress.executionMode = nil
            resetProgressThrottling()
            backgroundRefreshManualRescanNodeIDs.remove(nodeID)
        }

        if options.exclusionRootPath == nil {
            options.exclusionRootPath = baseline.target.url.path
        }
        options = ScanEngine.subtreeScanOptions(
            options,
            at: node.url,
            scanTarget: baseline.target
        )

        let rescanID = UUID()
        let baselineContextID = snapshotContextID
        let baselineRevision = snapshotRevision
        activeScanID = rescanID
        activeFolderRescanNodeID = nodeID
        folderRescanState = FolderRescanState(nodeName: node.name, isBackground: isBackground)
        onFolderRescanStarted?(nodeID)

        let subtreeTarget = ScanTarget(url: node.url, kind: .folder)
        let stream: AsyncThrowingStream<ScanProgressEvent, Error>
        if isBackground {
            stream = scanService.scanSubtree(
                target: subtreeTarget,
                preservingBehaviorOf: baseline.target,
                options: options,
                preservingMaterializedDirectoriesIn: baseline.treeStore
            )
        } else {
            stream = scanService.scanSubtree(
                target: subtreeTarget,
                preservingBehaviorOf: baseline.target,
                options: options
            )
        }
        scanTask = Task { [weak self] in
            await self?.consumeFolderRescanStream(
                stream,
                node: node,
                baseline: baseline,
                rescanID: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            )
        }
        return true
    }

    /// Refresh a retained containing scan, then publish the current scope in place.
    /// The caller commits the containing cache before the scoped snapshot is emitted.
    @discardableResult
    func refreshAfterFileTransfer(
        snapshotID: UUID,
        from reconciliationBaseline: ScanSnapshot? = nil,
        options reconciliationOptions: ScanOptions? = nil,
        relistingDirectoryPaths: [String] = [],
        commit: @escaping (ScanSnapshot) async -> Bool = { _ in true },
        completion: @escaping () -> Void = {}
    ) -> Bool {
        guard !isScanOperationInProgress, expandingNodeID == nil,
              let displayed = snapshot, displayed.id == snapshotID,
              displayed.isComplete, displayed.source.allowsFileMutation else { return false }
        let baseline = reconciliationBaseline ?? displayed
        guard baseline.isComplete, baseline.source.allowsFileMutation,
              baseline.treeStore.node(id: displayed.target.id) != nil,
              let options = reconciliationOptions ?? baseline.scanOptions else { return false }
        dismissScanCompletionNotice()
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        resetProgressThrottling()
        progress.executionMode = .preparingIncremental
        folderRescanState = FolderRescanState(nodeName: baseline.target.displayName)
        let operationID = UUID()
        let contextID = snapshotContextID
        let revision = snapshotRevision
        activeScanID = operationID
        let stream = scanService.rescan(
            target: baseline.target, options: options, from: baseline,
            relistingDirectoryPaths: relistingDirectoryPaths
        )
        scanTask = Task { [weak self] in
            defer { completion() }
            guard let self else { return }
            do {
                var replacement: ScanSnapshot?
                for try await event in stream {
                    guard activeScanID == operationID else { return }
                    switch event {
                    case .progress(let metrics): handleProgress(metrics, operationID: operationID)
                    case .executionMode(let mode): handleExecutionMode(mode)
                    case .finished(let completed): replacement = completed
                    case .warning: break
                    }
                }
                try Task.checkCancellation()
                guard let replacement else {
                    completeFolderRescanWithoutReplacement(id: operationID)
                    return
                }
                func preservingID(_ updated: ScanSnapshot, id: UUID) -> ScanSnapshot {
                    ScanSnapshot(
                        id: id, target: updated.target, treeStore: updated.treeStore,
                        startedAt: updated.startedAt, finishedAt: updated.finishedAt,
                        scanWarnings: updated.scanWarnings, isComplete: updated.isComplete,
                        scanOptions: updated.scanOptions, volumeCapacity: updated.volumeCapacity,
                        source: updated.source, incrementalCheckpoint: updated.incrementalCheckpoint
                    )
                }
                let refreshed = preservingID(replacement, id: baseline.id)
                let scoped: ScanSnapshot?
                if refreshed.target == displayed.target {
                    scoped = refreshed
                } else {
                    scoped = try await snapshotTransformService.scopedSnapshot(refreshed, to: displayed.target)
                }
                try Task.checkCancellation()
                guard await commit(refreshed) else {
                    completeFolderRescanWithoutReplacement(id: operationID)
                    return
                }
                guard folderRescanContextIsCurrent(
                    id: operationID, snapshotContextID: contextID, snapshotRevision: revision
                ) else {
                    completeFolderRescanWithoutReplacement(id: operationID)
                    return
                }
                guard let scoped else {
                    // The displayed folder itself moved out of the containing scan.
                    clearScan()
                    return
                }
                finishFolderRescan(
                    with: preservingID(scoped, id: displayed.id),
                    nodeName: baseline.target.displayName,
                    rescanID: operationID, showsCompletionNotice: false
                )
            } catch is CancellationError {
                completeFolderRescanWithoutReplacement(id: operationID)
            } catch {
                failFolderRescan(error, nodeName: baseline.target.displayName, rescanID: operationID)
            }
        }
        return true
    }

    func stopScan(resetState: Bool = true) {
        let isBackground = folderRescanState?.isBackground == true
        let cancelledFolderNodeID = activeFolderRescanNodeID
        activeFolderRescanNodeID = nil
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        folderRescanState = nil
        resetProgressThrottling()
        cancelExpansion(completeWith: .cancelled)

        if !isBackground {
            var metrics = scanMetrics
            metrics.isFinalizing = false
            scanMetrics = metrics
        }

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
        if let cancelledFolderNodeID {
            onFolderRescanFinished?(cancelledFolderNodeID, .cancelled)
        }
    }

    func clearScan() {
        stopScan(resetState: false)
        dismissScanCompletionNotice()
        selectedTarget = nil
        publishSnapshot(nil, startsNewContext: true)
        completedScanSnapshot = nil
        scanMetrics = ScanMetrics()
        progress.executionMode = nil
        phase = .idle
    }

    func captureWorkspace() -> WorkspaceState {
        WorkspaceState(
            snapshot: snapshot, completedSnapshot: completedScanSnapshot,
            target: selectedTarget, phase: phase, metrics: scanMetrics,
            executionMode: progress.executionMode, errorMessage: scanErrorMessage,
            completionNotice: scanCompletionNotice
        )
    }

    func restoreWorkspace(_ state: WorkspaceState) {
        stopScan(resetState: false)
        dismissScanCompletionNotice()
        selectedTarget = state.target
        publishSnapshot(state.snapshot, startsNewContext: true)
        completedScanSnapshot = state.completedSnapshot
        scanMetrics = state.metrics
        progress.executionMode = state.executionMode
        scanErrorMessage = state.errorMessage
        publishCompletionNotice(state.completionNotice)
        phase = state.phase
    }

    func replaceCurrentSnapshot(_ snapshot: ScanSnapshot?) {
        cancelExpansion(completeWith: .cancelled)
        dismissScanCompletionNotice()
        publishSnapshot(snapshot, startsNewContext: true)
        if snapshot == nil {
            phase = .idle
        } else if !isScanOperationInProgress {
            phase = .displaying
        }
    }

    func restoreCompletedSnapshot(
        _ snapshot: ScanSnapshot,
        prepare: () -> Void = {}
    ) {
        guard snapshot.isComplete else { return }

        stopScan(resetState: false)
        dismissScanCompletionNotice()
        prepare()

        selectedTarget = snapshot.target
        scanErrorMessage = nil
        progress.executionMode = nil
        resetProgressThrottling()
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot.source.allowsFileMutation ? snapshot : nil

        var metrics = ScanMetrics()
        metrics.recalculateProgress(isComplete: true)
        scanMetrics = metrics
        phase = .displaying
    }

    @discardableResult
    func removeNodesFromCurrentSnapshot(ids nodeIDs: [FileNodeRecord.ID]) async -> Bool {
        guard let initialSnapshot = snapshot else { return false }
        let removalNodeIDs = initialSnapshot.treeStore.topLevelNodeIDs(from: nodeIDs)
        guard !removalNodeIDs.isEmpty else { return false }
        let removalContextID = snapshotContextID

        do {
            while snapshotContextID == removalContextID {
                try Task.checkCancellation()
                guard let currentSnapshot = snapshot else { return false }
                let currentRemovalNodeIDs = currentSnapshot.treeStore.topLevelNodeIDs(
                    from: removalNodeIDs
                )
                if currentRemovalNodeIDs.isEmpty {
                    return true
                }

                if let expandingNodeID,
                   currentRemovalNodeIDs.contains(where: {
                       currentSnapshot.treeStore.isAncestor($0, of: expandingNodeID)
                   }) {
                    cancelExpansion(completeWith: .cancelled)
                }

                let transformRevision = snapshotRevision
                guard let updatedSnapshot = try await snapshotTransformService.removingNodes(
                    in: currentSnapshot,
                    ids: currentRemovalNodeIDs
                ) else { return false }
                try Task.checkCancellation()
                guard snapshotContextID == removalContextID else { return false }
                guard snapshotRevision == transformRevision else { continue }

                publishSnapshot(updatedSnapshot, startsNewContext: false)
                completedScanSnapshot = nil
                if !isScanOperationInProgress {
                    phase = .displaying
                }
                return true
            }
            return false
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
        guard !isScanOperationInProgress,
              node.isAutoSummarized else {
            completion(.skipped)
            return
        }

        cancelExpansion(completeWith: .cancelled)

        let expansionID = UUID()
        let expansionContextID = snapshotContextID
        activeExpansionID = expansionID
        expandingNodeID = node.id
        expansionCompletion = completion

        let target = ScanTarget(url: node.url)
        let stream = scanService.scan(target: target, options: options)
        expandTask = Task { [weak self] in
            await self?.consumeExpansionStream(
                stream,
                node: node,
                expansionID: expansionID,
                snapshotContextID: expansionContextID
            )
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

    private func consumeFolderRescanStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        node: FileNodeRecord,
        baseline: ScanSnapshot,
        rescanID: UUID,
        snapshotContextID baselineContextID: UUID,
        snapshotRevision baselineRevision: UInt64
    ) async {
        do {
            var replacement: ScanSnapshot?
            for try await event in stream {
                guard activeScanID == rescanID else { return }
                switch event {
                case .progress(var metrics):
                    guard folderRescanState?.isBackground != true else { continue }
                    metrics.progressFraction = min(metrics.progressFraction * 0.95, 0.95)
                    handleProgress(metrics, operationID: rescanID)
                case .finished(let snapshot):
                    replacement = snapshot
                case .executionMode, .warning:
                    break
                }
            }

            try Task.checkCancellation()
            guard folderRescanContextIsCurrent(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ),
                  let replacement else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }

            // Metadata events often leave the visible tree unchanged. Compare only
            // this subtree off the main actor before rebuilding the retained scan.
            if folderRescanState?.isBackground == true {
                let comparison = Task.detached(priority: .utility) {
                    try Self.folderContentsAreUnchanged(
                        baseline: baseline,
                        nodeID: node.id,
                        replacement: replacement
                    )
                }
                let isUnchanged = try await withTaskCancellationHandler {
                    try await comparison.value
                } onCancel: {
                    comparison.cancel()
                }
                try Task.checkCancellation()
                guard folderRescanContextIsCurrent(
                    id: rescanID,
                    snapshotContextID: baselineContextID,
                    snapshotRevision: baselineRevision
                ) else {
                    completeFolderRescanWithoutReplacement(id: rescanID)
                    return
                }
                if isUnchanged {
                    guard try await waitForBackgroundRefreshApplication(
                        id: rescanID,
                        snapshotContextID: baselineContextID,
                        snapshotRevision: baselineRevision
                    ) else {
                        completeFolderRescanWithoutReplacement(id: rescanID)
                        return
                    }
                    finishFolderRescan(with: nil, nodeName: node.name, rescanID: rescanID)
                    return
                }
            }

            let capacityRefresh: VolumeCapacityRefresh
            if baseline.target.kind == .volume {
                capacityRefresh = await volumeCapacityProvider(baseline.target.url)
            } else {
                capacityRefresh = VolumeCapacityRefresh(
                    capacity: baseline.volumeCapacity,
                    reconcilesTree: false
                )
            }

            try Task.checkCancellation()
            guard folderRescanContextIsCurrent(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ) else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }

            let updatedSnapshot = try await snapshotTransformService.replacingNodeForSubtreeRescan(
                in: baseline,
                id: node.id,
                with: replacement.treeStore,
                additionalWarnings: replacement.scanWarnings,
                volumeCapacity: capacityRefresh.capacity,
                reconcilesVolumeCapacity: capacityRefresh.reconcilesTree
            )

            try Task.checkCancellation()
            guard let updatedSnapshot,
                  try await waitForBackgroundRefreshApplication(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ) else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }

            finishFolderRescan(
                with: updatedSnapshot,
                nodeName: node.name,
                rescanID: rescanID
            )
        } catch is CancellationError {
            completeFolderRescanWithoutReplacement(id: rescanID)
        } catch ScanSnapshotTransformError.sharedAllocationRequiresFullScan {
            guard folderRescanContextIsCurrent(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ) else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }
            if folderRescanState?.isBackground == true {
                backgroundRefreshManualRescanNodeIDs.insert(node.id)
                completeFolderRescanWithoutReplacement(id: rescanID, result: .failed)
            } else {
                await continueFolderRescanAsFullScan(
                    baseline: baseline,
                    rescanID: rescanID
                )
            }
        } catch {
            guard folderRescanContextIsCurrent(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ) else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }
            failFolderRescan(error, nodeName: node.name, rescanID: rescanID)
        }
    }

    private nonisolated static func folderContentsAreUnchanged(
        baseline: ScanSnapshot,
        nodeID: FileNodeRecord.ID,
        replacement: ScanSnapshot
    ) throws -> Bool {
        guard replacement.root.id == nodeID else { return false }
        var pending = [nodeID]
        var visitedCount = 0
        while let id = pending.popLast() {
            try Task.checkCancellation()
            guard baseline.treeStore.node(id: id) == replacement.treeStore.node(id: id) else {
                return false
            }
            let oldChildren = baseline.treeStore.childIDs(of: id)
            let newChildren = replacement.treeStore.childIDs(of: id)
            guard oldChildren == newChildren else { return false }
            pending.append(contentsOf: newChildren)
            visitedCount += 1
        }
        guard visitedCount == replacement.treeStore.nodeCount else { return false }

        func warningKey(_ warning: ScanWarning) -> String {
            [warning.path, warning.category.rawValue, warning.message].joined(separator: "\u{0}")
        }
        let oldWarnings = Set(baseline.scanWarnings.filter {
            nodeID == "/" || $0.path == nodeID || $0.path.hasPrefix(nodeID + "/")
        }.map(warningKey))
        return oldWarnings == Set(replacement.scanWarnings.map(warningKey))
    }

    private func continueFolderRescanAsFullScan(
        baseline: ScanSnapshot,
        rescanID: UUID
    ) async {
        guard activeScanID == rescanID,
              let options = baseline.scanOptions else {
            completeFolderRescanWithoutReplacement(id: rescanID)
            return
        }

        progress.executionMode = .fullFallback(.sharedAllocationTopologyChanged)
        folderRescanState = FolderRescanState(nodeName: baseline.target.displayName)
        scanMetrics = ScanMetrics()
        resetProgressThrottling()
        do {
            var fullSnapshot: ScanSnapshot?
            for try await event in scanService.scan(
                target: baseline.target,
                options: options
            ) {
                guard activeScanID == rescanID else { return }
                switch event {
                case .progress(let metrics):
                    handleProgress(metrics, operationID: rescanID)
                case .finished(let snapshot):
                    fullSnapshot = snapshot
                case .executionMode, .warning:
                    break
                }
            }

            try Task.checkCancellation()
            guard activeScanID == rescanID,
                  let fullSnapshot else {
                completeFolderRescanWithoutReplacement(id: rescanID)
                return
            }
            finishScan(with: fullSnapshot, scanID: rescanID)
        } catch is CancellationError {
            completeFolderRescanWithoutReplacement(id: rescanID)
        } catch {
            failFolderRescan(
                error,
                nodeName: baseline.root.name,
                rescanID: rescanID
            )
        }
    }

    private func folderRescanContextIsCurrent(
        id rescanID: UUID,
        snapshotContextID baselineContextID: UUID,
        snapshotRevision baselineRevision: UInt64
    ) -> Bool {
        activeScanID == rescanID
            && snapshotContextID == baselineContextID
            && snapshotRevision == baselineRevision
    }

    private func waitForBackgroundRefreshApplication(
        id rescanID: UUID,
        snapshotContextID baselineContextID: UUID,
        snapshotRevision baselineRevision: UInt64
    ) async throws -> Bool {
        while folderRescanState?.isBackground == true, !canApplyBackgroundRefresh() {
            try await Task.sleep(for: .milliseconds(100))
            guard folderRescanContextIsCurrent(
                id: rescanID,
                snapshotContextID: baselineContextID,
                snapshotRevision: baselineRevision
            ) else { return false }
        }
        return folderRescanContextIsCurrent(
            id: rescanID,
            snapshotContextID: baselineContextID,
            snapshotRevision: baselineRevision
        )
    }

    private func consumeExpansionStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        node: FileNodeRecord,
        expansionID: UUID,
        snapshotContextID expansionContextID: UUID
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
                expansionID: expansionID,
                snapshotContextID: expansionContextID
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
                result: .failed(message: String(localized: "Failed to expand '\(node.name)': \(error.localizedDescription)", comment: "Error shown when expanding a summarized folder fails."))
            )
        }
    }

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .executionMode(let mode):
            handleExecutionMode(mode)
        case .progress(let metrics):
            handleProgress(metrics, operationID: scanID)
        case .warning:
            break
        case .finished(let snapshot):
            finishScan(with: snapshot, scanID: scanID)
        }
    }

    private func handleExecutionMode(_ mode: ScanExecutionMode) {
        if case .fullFallback = mode,
           progress.executionMode == .incremental || progress.executionMode == .incrementalNoChanges {
            resetProgressThrottling()
            scanMetrics = ScanMetrics()
        }
        progress.executionMode = mode
    }

    private func handleProgress(_ metrics: ScanMetrics, operationID: UUID) {
        guard activeScanID == operationID else { return }

        if shouldPublishProgressImmediately {
            publishProgress(metrics)
            return
        }

        pendingProgressMetrics = metrics
        schedulePendingProgressPublish(operationID: operationID)
    }

    private var shouldPublishProgressImmediately: Bool {
        guard progressThrottleDuration > .zero else { return true }
        guard let lastProgressPublishTime else { return true }

        return lastProgressPublishTime.duration(to: progressNow()) >= progressThrottleDuration
    }

    private func schedulePendingProgressPublish(operationID: UUID) {
        guard progressPublishTask == nil else { return }

        let delay: Duration
        if let lastProgressPublishTime {
            let elapsed = lastProgressPublishTime.duration(to: progressNow())
            delay = elapsed >= progressThrottleDuration ? .zero : progressThrottleDuration - elapsed
        } else {
            delay = .zero
        }

        progressPublishTask = Task { [weak self, sleepForProgress] in
            do {
                try await sleepForProgress(delay)
            } catch {
                return
            }

            self?.publishPendingProgress(operationID: operationID)
        }
    }

    private func publishPendingProgress(operationID: UUID) {
        guard activeScanID == operationID else { return }
        progressPublishTask = nil
        guard let pendingProgressMetrics else { return }
        publishProgress(pendingProgressMetrics)
    }

    private func publishProgress(_ metrics: ScanMetrics) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = progressNow()
        var publishedMetrics = metrics
        publishedMetrics.progressFraction = max(
            publishedMetrics.progressFraction,
            scanMetrics.progressFraction
        )
        scanMetrics = publishedMetrics
    }

    private func finishScan(with snapshot: ScanSnapshot, scanID: UUID) {
        guard activeScanID == scanID else { return }

        let folderNodeID = activeFolderRescanNodeID
        activeFolderRescanNodeID = nil
        flushPendingProgress(operationID: scanID)
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot

        var completedMetrics = scanMetrics
        completedMetrics.recalculateProgress(isComplete: true)
        publishProgress(completedMetrics)

        activeScanID = nil
        scanTask = nil
        folderRescanState = nil
        phase = .displaying
        publishCompletionNotice(for: progress.executionMode)
        onScanFinished?(snapshot)
        if let folderNodeID {
            onFolderRescanFinished?(folderNodeID, .updated)
        }
    }

    func dismissScanCompletionNotice() {
        completionNoticeDismissTask?.cancel()
        completionNoticeDismissTask = nil
        scanCompletionNotice = nil
    }

    private func publishCompletionNotice(for mode: ScanExecutionMode?) {
        let notice: ScanCompletionNotice?
        switch mode {
        case .incremental:
            notice = .incrementalUpdated
        case .incrementalNoChanges:
            notice = .noChanges
        case .fullFallback(let reason):
            notice = .fullFallback(reason)
        case .full, .preparingIncremental, .none:
            notice = nil
        }

        publishCompletionNotice(notice)
    }

    private func publishCompletionNotice(_ notice: ScanCompletionNotice?) {
        completionNoticeDismissTask?.cancel()
        completionNoticeDismissTask = nil
        scanCompletionNotice = notice
        guard notice?.automaticallyDismisses == true else { return }

        completionNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            self?.scanCompletionNotice = nil
            self?.completionNoticeDismissTask = nil
        }
    }

    private func apply(snapshot: ScanSnapshot) {
        publishSnapshot(snapshot, startsNewContext: true)
    }

    private func publishSnapshot(
        _ snapshot: ScanSnapshot?,
        startsNewContext: Bool
    ) {
        if startsNewContext {
            snapshotContextID = UUID()
            backgroundRefreshManualRescanNodeIDs.removeAll()
        }
        snapshotRevision &+= 1
        self.snapshot = snapshot
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

    private func finishFolderRescan(
        with updatedSnapshot: ScanSnapshot?,
        nodeName: String,
        rescanID: UUID,
        showsCompletionNotice: Bool = true
    ) {
        guard activeScanID == rescanID else { return }
        let folderNodeID = activeFolderRescanNodeID
        let isBackground = folderRescanState?.isBackground == true
        activeFolderRescanNodeID = nil

        if !isBackground {
            flushPendingProgress(operationID: rescanID)
        }
        if let updatedSnapshot {
            publishSnapshot(updatedSnapshot, startsNewContext: false)
            completedScanSnapshot = updatedSnapshot
        }

        if !isBackground {
            var completedMetrics = scanMetrics
            completedMetrics.recalculateProgress(isComplete: true)
            publishProgress(completedMetrics)
        }

        if let folderNodeID {
            let prefix = folderNodeID == "/" ? "/" : folderNodeID + "/"
            backgroundRefreshManualRescanNodeIDs = backgroundRefreshManualRescanNodeIDs.filter {
                $0 != folderNodeID && !$0.hasPrefix(prefix)
            }
        }

        activeScanID = nil
        scanTask = nil
        folderRescanState = nil
        phase = .displaying
        if !isBackground, showsCompletionNotice {
            publishCompletionNotice(.folderUpdated(name: nodeName))
        }
        if let folderNodeID {
            onFolderRescanFinished?(folderNodeID, .updated)
        }
    }

    private func completeFolderRescanWithoutReplacement(
        id rescanID: UUID,
        result: FolderRescanResult = .cancelled
    ) {
        guard activeScanID == rescanID else { return }
        let folderNodeID = activeFolderRescanNodeID
        activeFolderRescanNodeID = nil

        resetProgressThrottling()
        activeScanID = nil
        scanTask = nil
        folderRescanState = nil
        phase = snapshot == nil ? .idle : .displaying
        if let folderNodeID {
            onFolderRescanFinished?(folderNodeID, result)
        }
    }

    private func failFolderRescan(
        _ error: Error,
        nodeName: String,
        rescanID: UUID
    ) {
        guard activeScanID == rescanID else { return }
        if folderRescanState?.isBackground == true, let nodeID = activeFolderRescanNodeID {
            backgroundRefreshManualRescanNodeIDs.insert(nodeID)
            completeFolderRescanWithoutReplacement(id: rescanID, result: .failed)
            return
        }

        completeFolderRescanWithoutReplacement(id: rescanID, result: .failed)
        scanErrorMessage = String(
            localized: "Failed to rescan \(nodeName): \(error.localizedDescription)",
            comment: "Error shown when refreshing one folder in an existing scan fails."
        )
    }

    private func flushPendingProgress(operationID: UUID) {
        guard activeScanID == operationID else { return }
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
        expansionID: UUID,
        snapshotContextID expansionContextID: UUID
    ) async throws -> FileNodeRecord.ID? {
        while activeExpansionID == expansionID,
              snapshotContextID == expansionContextID {
            try Task.checkCancellation()
            guard let currentSnapshot = snapshot,
                  let currentNode = currentSnapshot.treeStore.node(id: oldNode.id),
                  currentNode.isAutoSummarized,
                  currentNode.fileIdentity == oldNode.fileIdentity else {
                return nil
            }

            let transformRevision = snapshotRevision
            guard let updatedSnapshot = try await snapshotTransformService.replacingNode(
                in: currentSnapshot,
                id: oldNode.id,
                with: expandedSnapshot.treeStore,
                additionalWarnings: expandedSnapshot.scanWarnings
            ) else { return nil }
            try Task.checkCancellation()
            guard activeExpansionID == expansionID,
                  snapshotContextID == expansionContextID else {
                return nil
            }
            guard snapshotRevision == transformRevision else { continue }

            publishSnapshot(updatedSnapshot, startsNewContext: false)
            completedScanSnapshot = updatedSnapshot
            return expandedSnapshot.root.id
        }
        return nil
    }
}
