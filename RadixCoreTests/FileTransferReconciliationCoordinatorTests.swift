import AppKit
import Combine
import Foundation
import Testing

@testable import RadixCore

@MainActor
struct FileTransferReconciliationCoordinatorTests {
    @Test(arguments: TransferExpansionOutcome.allCases)
    func deferredTransferDrainsAfterEveryExpansionOutcome(outcome: TransferExpansionOutcome) async throws {
        let fixture = makeTransferFixture(includeSummary: true)
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        let summary = try #require(fixture.summary)
        var expansionResult: ScanExpansionResult?
        harness.scan.expandSummarizedNode(summary, options: fixture.options) {
            expansionResult = $0
        }
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        await Task.yield()
        #expect(harness.service.requests.count == 1)
        #expect(harness.scan.expandingNodeID == summary.id)

        switch outcome {
        case .success:
            harness.service.finish(index: 0, snapshot: makeTransferExpansionSnapshot(summary))
        case .failure:
            harness.service.fail(index: 0)
        case .cancellation:
            harness.scan.stopScan(resetState: false)
        }
        try await waitUntil("queued transfer after expansion \(outcome)") {
            harness.service.rescanRequests.count == 1
        }
        #expect(expansionResult != nil)
        let request = try #require(harness.service.rescanRequests.first)
        #expect(request.target == fixture.snapshot.target)
        #expect(request.forcedPaths == [fixture.sourceTarget.id])
        let baseline = try #require(request.baseline)
        if outcome == .success {
            #expect(baseline.treeStore.node(id: summary.id)?.isAutoSummarized == false)
        }
        harness.service.finish(index: 1, snapshot: baseline)
        try await waitUntil("queued transfer completes") { !harness.scan.isScanOperationInProgress }
    }

    @Test
    func retainedParentRefreshUpdatesSiblingAndPreservesDisplayedChildIdentity() async throws {
        let fixture = makeTransferFixture()
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        try await harness.navigate(to: fixture.sourceTarget, options: fixture.options)
        let child = try #require(harness.scan.snapshot)
        harness.reconciliation.fileTransferDidEnd(
            FileTransfer(snapshot: child, nodes: [fixture.sourceFile], operation: .move)
        )
        try await waitUntil("parent reconciliation starts") { harness.service.rescanRequests.count == 1 }
        let request = try #require(harness.service.rescanRequests.first)
        #expect(request.target == fixture.snapshot.target)
        #expect(request.baseline?.id == fixture.snapshot.id)
        #expect(request.options == fixture.options)
        #expect(request.forcedPaths == [fixture.sourceTarget.id])

        let moved = makeTransferFixture(moved: true)
        harness.service.finish(index: 0, snapshot: moved.snapshot)
        try await waitUntil("scoped child refresh") {
            !harness.scan.isScanOperationInProgress && harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) == nil
        }
        #expect(harness.scan.snapshot?.id == child.id)
        #expect(harness.scan.snapshot?.target == fixture.sourceTarget)
        #expect(harness.scan.snapshot?.root.descendantFileCount == 0)

        try await harness.navigate(to: fixture.snapshot.target, options: fixture.options)
        #expect(harness.scan.snapshot?.id == fixture.snapshot.id)
        #expect(harness.scan.snapshot?.treeStore.node(id: moved.sourceFile.id) != nil)
        #expect(harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) == nil)
        try await waitUntil("parent background validation") { harness.service.rescanRequests.count == 2 }
        let parentRequest = harness.service.rescanRequests[1]
        let refreshedParent = try #require(parentRequest.baseline)
        #expect(refreshedParent.id == fixture.snapshot.id)
        #expect(refreshedParent.treeStore.node(id: fixture.sourceFile.id) == nil)
        #expect(refreshedParent.treeStore.node(id: moved.sourceFile.id) != nil)
        harness.service.finish(index: 1, snapshot: refreshedParent)
        try await waitUntil("parent validation finishes") { !harness.scan.isScanOperationInProgress }
    }

    @Test(arguments: [false, true])
    func failedOrCancelledRefreshWaitsForAnExplicitRetry(cancel: Bool) async throws {
        let fixture = makeTransferFixture()
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        try await waitUntil("initial reconciliation") { harness.service.rescanRequests.count == 1 }
        let firstTask = try #require(harness.scan.scanTask)
        if cancel {
            harness.scan.stopScan(resetState: false)
        } else {
            harness.service.fail(index: 0)
        }
        await firstTask.value
        harness.reconciliation.resumeIfPossible()
        await Task.yield()
        #expect(harness.service.rescanRequests.count == 1)
        #expect(harness.scan.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
        #expect(harness.cache.fileTransferReconciliationRequest(for: fixture.snapshot) != nil)

        harness.reconciliation.applicationBecameActive()
        try await waitUntil("activation retries reconciliation") { harness.service.rescanRequests.count == 2 }
        #expect(harness.service.rescanRequests[1].forcedPaths == [fixture.sourceTarget.id])
        harness.service.finish(index: 1, snapshot: fixture.snapshot)
        try await waitUntil("explicit retry completes") { !harness.scan.isScanOperationInProgress }
    }

    @Test(arguments: [false, true])
    func navigationDuringQueuedOrActiveWorkKeepsOriginDirty(active: Bool) async throws {
        let fixture = makeTransferFixture()
        let other = makeTransferFixture(path: "/transfer/other")
        let gate = TransferStartGate(allowed: active)
        let harness = TransferReconciliationHarness(canStart: { gate.allowed })
        defer { harness.cleanup() }
        harness.store(other.snapshot)
        harness.storeAndDisplay(fixture.snapshot)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        if active {
            try await waitUntil("origin refresh begins") { harness.service.rescanRequests.count == 1 }
        } else {
            await Task.yield()
            #expect(harness.service.requests.isEmpty)
        }
        let originTask = harness.scan.scanTask
        try await harness.navigate(to: other.snapshot.target, options: other.options)
        gate.allowed = true
        harness.reconciliation.resumeIfPossible()
        if let originTask { await originTask.value }
        let otherIndex = active ? 1 : 0
        try await waitUntil("new displayed cache validates") {
            harness.service.rescanRequests.count == otherIndex + 1
        }
        #expect(harness.scan.snapshot?.target == other.snapshot.target)
        #expect(harness.service.rescanRequests[otherIndex].target == other.snapshot.target)
        #expect(harness.service.rescanRequests[otherIndex].forcedPaths.isEmpty)
        // Even late output from the cancelled origin stream cannot replace this view.
        if active { harness.service.finish(index: 0, snapshot: makeTransferFixture(moved: true).snapshot) }
        harness.service.finish(index: otherIndex, snapshot: other.snapshot)
        try await waitUntil("other cache validation finishes") { !harness.scan.isScanOperationInProgress }
        #expect(harness.scan.snapshot?.target == other.snapshot.target)
        #expect(harness.cache.fileTransferReconciliationRequest(for: fixture.snapshot) != nil)

        try await harness.navigate(to: fixture.snapshot.target, options: fixture.options)
        try await waitUntil("origin reconciles when revisited") {
            harness.service.rescanRequests.count == otherIndex + 2
        }
        #expect(harness.service.rescanRequests.last?.baseline?.id == fixture.snapshot.id)
        #expect(harness.service.rescanRequests.last?.forcedPaths == [fixture.sourceTarget.id])
        harness.service.finish(index: otherIndex + 1, snapshot: makeTransferFixture(moved: true).snapshot)
        try await waitUntil("origin refresh finishes") { !harness.scan.isScanOperationInProgress }
        #expect(harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) == nil)
    }

    @Test
    func activationRevalidatesAfterImmediateRefreshToCaptureLateReceiverChanges() async throws {
        let fixture = makeTransferFixture()
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        try await waitUntil("immediate reconciliation") { harness.service.rescanRequests.count == 1 }
        harness.service.finish(index: 0, snapshot: fixture.snapshot, mode: .incrementalNoChanges)
        try await waitUntil("immediate refresh finishes") { !harness.scan.isScanOperationInProgress }
        let immediate = try #require(harness.scan.snapshot)
        #expect(harness.cache.fileTransferReconciliationRequest(for: immediate) == nil)

        harness.reconciliation.applicationBecameActive()
        try await waitUntil("late validation begins") { harness.service.rescanRequests.count == 2 }
        #expect(harness.service.rescanRequests[1].forcedPaths == [fixture.sourceTarget.id])
        let moved = makeTransferFixture(moved: true)
        harness.service.finish(index: 1, snapshot: moved.snapshot)
        try await waitUntil("late receiver change applied") { !harness.scan.isScanOperationInProgress }
        #expect(harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) == nil)
        #expect(harness.scan.snapshot?.treeStore.node(id: moved.sourceFile.id) != nil)
    }

    @Test
    func suspendedWorkspaceKeepsNewTransferQueuedUntilReactivation() async throws {
        let fixture = makeTransferFixture()
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        try await waitUntil("refresh before suspension") { harness.service.rescanRequests.count == 1 }
        let cancelledTask = try #require(harness.scan.scanTask)
        harness.reconciliation.suspend()
        harness.scan.stopScan(resetState: false)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        await cancelledTask.value
        harness.reconciliation.displayedSnapshotDidChange()
        harness.reconciliation.resumeIfPossible()
        await Task.yield()
        #expect(harness.service.rescanRequests.count == 1)
        #expect(harness.cache.fileTransferReconciliationRequest(for: fixture.snapshot) != nil)

        harness.reconciliation.applicationBecameActive()
        try await waitUntil("queued transfer after reactivation") { harness.service.rescanRequests.count == 2 }
        #expect(harness.service.rescanRequests[1].forcedPaths == [fixture.sourceTarget.id])
        harness.service.finish(index: 1, snapshot: makeTransferFixture(moved: true).snapshot)
        try await waitUntil("reactivated refresh finishes") { !harness.scan.isScanOperationInProgress }
        #expect(harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) == nil)
    }

    @Test
    func newerTransferDuringRefreshCannotBeClearedByTheOlderResult() async throws {
        let fixture = makeTransferFixture()
        let harness = TransferReconciliationHarness()
        defer { harness.cleanup() }
        harness.storeAndDisplay(fixture.snapshot)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        try await waitUntil("first generation begins") { harness.service.rescanRequests.count == 1 }
        let firstTask = try #require(harness.scan.scanTask)
        harness.reconciliation.fileTransferDidEnd(fixture.transfer)
        harness.service.finish(index: 0, snapshot: makeTransferFixture(moved: true).snapshot)
        await firstTask.value
        try await waitUntil("newer generation drains") { harness.service.rescanRequests.count == 2 }
        #expect(harness.scan.snapshot?.treeStore.node(id: fixture.sourceFile.id) != nil)
        #expect(harness.service.rescanRequests[1].forcedPaths == [fixture.sourceTarget.id])
        #expect(harness.cache.fileTransferReconciliationRequest(for: fixture.snapshot) != nil)

        harness.service.finish(index: 1, snapshot: makeTransferFixture(moved: true).snapshot)
        try await waitUntil("newer generation completes") { !harness.scan.isScanOperationInProgress }
        let refreshed = try #require(harness.scan.snapshot)
        #expect(refreshed.treeStore.node(id: fixture.sourceFile.id) == nil)
        #expect(harness.cache.fileTransferReconciliationRequest(for: refreshed) == nil)
    }
}

enum TransferExpansionOutcome: CaseIterable, Sendable {
    case success
    case failure
    case cancellation
}

@MainActor
private final class TransferStartGate {
    var allowed: Bool
    init(allowed: Bool) { self.allowed = allowed }
}

@MainActor
private final class TransferReconciliationHarness {
    let service = TransferControlledScanService()
    let scan: ScanCoordinator
    let cache = SidebarScanCacheController(maxTotalNodeCount: 1_000)
    let reconciliation: FileTransferReconciliationCoordinator
    private var completionObserver: AnyCancellable?

    init(canStart: @escaping () -> Bool = { true }) {
        scan = ScanCoordinator(scanService: service, progressThrottleDuration: .zero)
        reconciliation = FileTransferReconciliationCoordinator(
            scanCoordinator: scan, cache: cache, canStart: canStart
        )
        scan.onBecameIdle = { [weak reconciliation] in reconciliation?.resumeIfPossible() }
        completionObserver = scan.$completedScanSnapshot.compactMap { $0 }.sink { [weak cache] in
            cache?.handleCompletedScanSnapshot($0)
        }
    }

    func store(_ snapshot: ScanSnapshot) {
        cache.prepareForScanStart(target: snapshot.target, options: snapshot.scanOptions ?? ScanOptions())
        cache.handleCompletedScanSnapshot(snapshot)
    }

    func storeAndDisplay(_ snapshot: ScanSnapshot) {
        store(snapshot)
        scan.restoreCompletedSnapshot(snapshot)
        reconciliation.displayedSnapshotDidChange()
    }

    func navigate(to target: ScanTarget, options: ScanOptions) async throws {
        let needsScan = cache.applyCachedOrContainedSidebarTarget(
            target, options: options, currentSnapshot: scan.snapshot,
            isTargetActive: { _ in true }, cancelDeferredScanStart: {},
            restoreSnapshot: { [self] snapshot, _ in
                scan.restoreCompletedSnapshot(snapshot)
                reconciliation.displayedSnapshotDidChange()
            },
            startScan: { _ in Issue.record("Expected a retained cached scan") }
        )
        #expect(!needsScan)
        try await waitUntil("cached navigation to \(target.id)") { self.scan.snapshot?.target == target }
    }

    func cleanup() {
        reconciliation.cleanup()
        completionObserver?.cancel()
        scan.onBecameIdle = nil
        scan.stopScan(resetState: false)
        cache.clearCache()
    }
}

private final class TransferControlledScanService: ScanEventStreaming, @unchecked Sendable {
    struct Request {
        let target: ScanTarget
        let baseline: ScanSnapshot?
        let options: ScanOptions
        let forcedPaths: [String]
    }

    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var continuations: [Continuation] = []

    var requests: [Request] { lock.withLock { storedRequests } }
    var rescanRequests: [Request] { requests.filter { $0.baseline != nil } }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        stream(Request(target: target, baseline: nil, options: options, forcedPaths: []))
    }

    func rescan(
        target: ScanTarget, options: ScanOptions, from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        rescan(target: target, options: options, from: baseline, relistingDirectoryPaths: [])
    }

    func rescan(
        target: ScanTarget, options: ScanOptions, from baseline: ScanSnapshot,
        relistingDirectoryPaths: [String]
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        stream(Request(target: target, baseline: baseline, options: options, forcedPaths: relistingDirectoryPaths))
    }

    private func stream(_ request: Request) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                storedRequests.append(request)
                continuations.append(continuation)
            }
        }
    }

    func finish(index: Int, snapshot: ScanSnapshot, mode: ScanExecutionMode = .incremental) {
        let continuation = lock.withLock { continuations[index] }
        continuation.yield(.executionMode(mode))
        continuation.yield(.finished(snapshot))
        continuation.finish()
    }

    func fail(index: Int) {
        lock.withLock { continuations[index] }.finish(throwing: TransferTestError.failed)
    }
}

private enum TransferTestError: Error {
    case failed
}

private struct TransferFixture {
    let snapshot: ScanSnapshot
    let sourceTarget: ScanTarget
    let sourceFile: FileNodeRecord
    let summary: FileNodeRecord?
    let options: ScanOptions

    var transfer: FileTransfer { FileTransfer(snapshot: snapshot, nodes: [sourceFile], operation: .move) }
}

private func makeTransferFixture(
    path: String = "/transfer/root", moved: Bool = false, includeSummary: Bool = false
) -> TransferFixture {
    let sourceTarget = makeTestTarget(path + "/Source")
    let destinationID = path + "/Destination"
    let file = makeTestFileNode(
        id: (moved ? destinationID : sourceTarget.id) + "/file.dat", name: "file.dat", size: 50
    )
    let source = makeTestDirectoryNode(id: sourceTarget.id, name: "Source", children: moved ? [] : [file])
    let destination = makeTestDirectoryNode(id: destinationID, name: "Destination", children: moved ? [file] : [])
    let summary = includeSummary
        ? makeTestSummarizedDirectoryNode(id: path + "/Summary", name: "Summary", size: 20, descendantFileCount: 1)
        : nil
    let rootChildren = [source, destination] + (summary.map { [$0] } ?? [])
    let root = makeTestDirectoryNode(id: path, name: "root", children: rootChildren)
    let store = FileTreeStore(root: root, childrenByID: [
        root.id: rootChildren,
        source.id: moved ? [] : [file],
        destination.id: moved ? [file] : [],
    ])
    let options = ScanOptions(includeHiddenFiles: true)
    return TransferFixture(
        snapshot: makeTransferSnapshot(target: makeTestTarget(path), store: store, options: options),
        sourceTarget: sourceTarget, sourceFile: file, summary: summary, options: options
    )
}

private func makeTransferExpansionSnapshot(_ summary: FileNodeRecord) -> ScanSnapshot {
    let file = makeTestFileNode(id: summary.id + "/expanded.dat", name: "expanded.dat", size: 20)
    let root = makeTestDirectoryNode(id: summary.id, name: summary.name, children: [file])
    return makeTransferSnapshot(
        target: makeTestTarget(summary.id),
        store: FileTreeStore(root: root, childrenByID: [root.id: [file]]),
        options: ScanOptions(autoSummarizeDirectories: false)
    )
}

private func makeTransferSnapshot(target: ScanTarget, store: FileTreeStore, options: ScanOptions) -> ScanSnapshot {
    ScanSnapshot(
        target: target, treeStore: store, startedAt: .now, finishedAt: .now,
        scanWarnings: [], isComplete: true, scanOptions: options,
        incrementalCheckpoint: ScanIncrementalCheckpoint(volumeUUID: "transfer", eventID: 10)
    )
}
