import Foundation

/// Coalesces transfer work while preserving dirty cache entries across cancellation
/// and navigation. Readiness is evaluated after synchronous scan mutations finish.
@MainActor
final class FileTransferReconciliationCoordinator {
    private let scanCoordinator: ScanCoordinator
    private let cache: SidebarScanCacheController
    private let canStart: () -> Bool
    private var drainTask: Task<Void, Never>?
    private var hasPendingRequest = false
    private var isRunning = false
    private var isStopped = false
    private var isSuspended = false

    init(
        scanCoordinator: ScanCoordinator,
        cache: SidebarScanCacheController,
        canStart: @escaping () -> Bool = { true }
    ) {
        self.scanCoordinator = scanCoordinator
        self.cache = cache
        self.canStart = canStart
    }

    func fileTransferDidEnd(_ transfer: FileTransfer) {
        guard !isStopped else { return }
        cache.markExternalFileTransfer(
            sourceDirectoryPaths: transfer.sourceDirectoryPaths,
            currentSnapshot: transfer.snapshot
        )
        hasPendingRequest = true
        resumeIfPossible()
    }

    func displayedSnapshotDidChange() {
        guard !isStopped else { return }
        hasPendingRequest = true
        resumeIfPossible()
    }

    func applicationBecameActive() {
        guard !isStopped else { return }
        isSuspended = false
        guard cache.markForValidationOnActivation(currentSnapshot: scanCoordinator.snapshot) else { return }
        hasPendingRequest = true
        resumeIfPossible()
    }

    func resumeIfPossible() {
        guard !isStopped, hasPendingRequest, drainTask == nil else { return }
        // @Published observers run in willSet. Defer before reading scan state.
        drainTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            drainTask = nil
            drain()
        }
    }

    func suspend() {
        isSuspended = true
        drainTask?.cancel()
        drainTask = nil
        hasPendingRequest = false
    }

    func cleanup() {
        isStopped = true
        suspend()
    }

    private func drain() {
        guard !isStopped, !isSuspended, hasPendingRequest, !isRunning, canStart(),
              !scanCoordinator.isScanOperationInProgress,
              scanCoordinator.expandingNodeID == nil else { return }
        guard let displayed = scanCoordinator.snapshot,
              let request = cache.fileTransferReconciliationRequest(for: displayed) else {
            hasPendingRequest = false
            return
        }
        hasPendingRequest = false
        isRunning = true
        let accepted = scanCoordinator.refreshAfterFileTransfer(
            snapshotID: displayed.id, from: request.snapshot, options: request.options,
            relistingDirectoryPaths: request.forcedDirectoryPaths,
            commit: { [weak cache] refreshed in
                await cache?.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed) == true
            },
            completion: { [weak self] in
                guard let self else { return }
                isRunning = false
                // Failure/cancellation leaves the cache dirty for a future explicit
                // trigger. Only requests received during this operation drain now.
                resumeIfPossible()
            }
        )
        if !accepted {
            isRunning = false
            hasPendingRequest = true
        }
    }
}
