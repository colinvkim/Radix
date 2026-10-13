import Foundation
import Testing

@testable import RadixCore

@MainActor
struct FolderRefreshControllerTests {
    @Test
    func rejectedStartRetriesWhenScannerBecomesReadyWithoutAnotherEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.allowsRequests = false
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/pending.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }

        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        harness.allowsRequests = true
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
    }

    @Test(arguments: [false, true])
    func manualRefreshAcknowledgesOnlyChangesKnownAtStart(hasNewChange: Bool) async throws {
        let harness = FolderRefreshHarness()
        let baseline = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/before.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }

        harness.controller.refreshStarted(nodeID: downloads)
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: false)
        if hasNewChange {
            harness.watcher.emit([changedFile(downloads + "/during.zip")])
            await drainTasks()
        }
        let updated = makeFolderRefreshSnapshot(id: baseline.id, hasNewDownload: true)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        await drainTasks()
        if hasNewChange {
            try await waitUntil { harness.clock.pendingSleeps == 1 }
        } else {
            #expect(harness.clock.pendingSleeps == 0)
        }
        harness.clock.advance(by: .seconds(10))
        await drainTasks()
        #expect(harness.requests == (hasNewChange ? [downloads] : []))
    }

    @Test
    func watchesWholeScanAndCatchesUpOnNavigationAfterAnInPlaceRefresh() async throws {
        let harness = FolderRefreshHarness()
        let baseline = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        #expect(harness.watcher.requests.first?.targetURL == baseline.target.url)
        #expect(harness.watcher.requests.first?.checkpoint == baseline.incrementalCheckpoint)

        harness.watcher.emit([changedFile(downloads + "/new.zip"), changedFile(documents + "/report.pdf")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }

        // Publishing a new tree with the same scan identity must retain both
        // the watcher and the unrefreshed Documents changes.
        let updated = makeFolderRefreshSnapshot(id: baseline.id, hasNewDownload: true)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.watcher.requests.count == 1)
        #expect(harness.clock.pendingSleeps == 0)

        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: updated, focusedNodeID: documents, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, documents] }
        harness.controller.refreshFinished(nodeID: documents, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func batchesEventsDuringRefreshAndEnforcesMinimumInterval() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/archive.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests.count == 1 }

        harness.watcher.emit((0..<100).map { changedFile(downloads + "/\($0).dat") })
        // An unrelated change produces a scheduled timer only after the
        // in-flight refresh is acknowledged; it cannot start concurrently.
        await drainTasks()
        #expect(harness.requests == [downloads])
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(4_999))
        await drainTasks()
        #expect(harness.requests.count == 1)
        harness.clock.advance(by: .milliseconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func expensiveRefreshRestsForTwiceItsDurationBeforeFollowingUp() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.clock.advance(by: .seconds(20))
        harness.watcher.emit([changedFile(downloads + "/second.zip")])
        await drainTasks()
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(39_999))
        await drainTasks()
        #expect(harness.requests == [downloads])
        harness.clock.advance(by: .milliseconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test
    func trailingDebounceIsUnaffectedByChangesOutsideFocus() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/a.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(500))
        harness.watcher.emit([changedFile(downloads + "/b.zip")])
        await drainTasks()
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(500))
        harness.watcher.emit([changedFile(documents + "/report.pdf")])
        await drainTasks()
        #expect(harness.requests.isEmpty)
        harness.clock.advance(by: .milliseconds(500))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func pausesForInteractionsAndResumesWithoutAnotherFilesystemEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/a.zip")])
        await drainTasks()
        harness.clock.advance(by: .seconds(10))
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func repeatedContextUpdatesKeepTimerAndCompletionCanPrecedeGateResume() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        for _ in 0..<100 {
            harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        }
        await drainTasks()
        #expect(harness.sleepRequests == 1)
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        harness.watcher.emit([changedFile(downloads + "/second.zip")])
        await drainTasks()
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test
    func cancelledRefreshRetriesWhenTheWorkspaceReopensWithoutANewEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/new.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .cancelled)
        harness.clock.advance(by: .seconds(5))
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests == [downloads])
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func explicitStopSuppressesKnownWorkUntilANewEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        // Include changes received while the refresh was running: Stop should
        // not immediately launch those already pending writes as another scan.
        harness.watcher.emit([changedFile(downloads + "/second.zip")])
        await drainTasks()
        harness.controller.pauseCurrentRefresh()
        harness.controller.refreshFinished(nodeID: downloads, result: .cancelled)
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        await drainTasks()
        #expect(harness.requests == [downloads])
        #expect(harness.clock.pendingSleeps == 0)
        harness.watcher.emit([changedFile(downloads + "/third.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test
    func failureWaitsForANewRelevantEventRatherThanRetryingOnNavigation() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/a.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests.count == 1 }
        harness.controller.refreshFinished(nodeID: downloads, result: .failed)
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        await drainTasks()
        #expect(harness.requests.count == 1)
        #expect(harness.clock.pendingSleeps == 0)
        harness.watcher.emit([changedFile(downloads + "/b.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests.count == 2 }
    }

    @Test
    func respectsExclusionsHiddenFilesAndPathBoundaries() async throws {
        let harness = FolderRefreshHarness()
        let options = ScanOptions(exclusionPatterns: ["build/", "*.log"])
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(options: options), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([
            changedFile(downloads + "/.secret/item"),
            changedFile(downloads + "/build/item"),
            changedFile(downloads + "/trace.log"),
            changedFile(home + "-other/Downloads/file"),
            FileSystemEventRecord(path: downloads + "/read.txt", eventID: 43, flags: [.itemIsFile])
        ])
        await drainTasks()
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests.isEmpty)
        harness.watcher.emit([changedFile(downloads + "/visible.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test(arguments: [FileSystemEventFlags.itemCreated, .itemRemoved])
    func directoryOnlyExclusionsKeepSymbolicLinkChanges(mutation: FileSystemEventFlags) async throws {
        let harness = FolderRefreshHarness()
        let options = ScanOptions(exclusionPatterns: ["build/"])
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(options: options), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([
            FileSystemEventRecord(path: downloads + "/build", eventID: 43, flags: mutation.union(.itemIsSymbolicLink))
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func volumeOverviewIsManualButItsSubfoldersRefreshAutomatically() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot(kind: .volume)
        harness.controller.update(snapshot: snapshot, focusedNodeID: home, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/new.zip")])
        await drainTasks()
        harness.clock.advance(by: .seconds(10))
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func folderTargetRootCanRefreshAndSavedOrIncompleteScansNeverWatch() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(isComplete: false), focusedNodeID: home, canRefresh: true)
        harness.controller.update(
            snapshot: makeFolderRefreshSnapshot(source: .imported(ImportedSnapshotContext(
                sourceURL: URL(filePath: "/saved.radixscan"), pathMode: .absolute, liveActionCapability: .pathValidation
            ))),
            focusedNodeID: home,
            canRefresh: true
        )
        await drainTasks()
        #expect(harness.watcher.requests.isEmpty)
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: home, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(documents + "/new.pdf")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [home] }
    }

    @Test(arguments: [false, true])
    func overflowAndDroppedHistoryRemainDirtyForOtherFolders(isDroppedHistory: Bool) async throws {
        let harness = FolderRefreshHarness(maximumPendingPaths: 2)
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit(isDroppedHistory ? [
            FileSystemEventRecord(path: home, eventID: 44, flags: [.kernelDropped])
        ] : [
            changedFile(home + "/Other1/a"),
            changedFile(home + "/Other2/b"),
            changedFile(home + "/Other3/c")
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, documents] }
        harness.controller.refreshFinished(nodeID: documents, result: .updated)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func changingScansCancelsOldWatcherAndPendingRefresh() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.watcher.emit([changedFile(downloads + "/old.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 2 && harness.watcher.cancelledStreams == 1 }
        harness.clock.advance(by: .seconds(10))
        await drainTasks()
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        try await waitUntil { harness.watcher.cancelledStreams == 2 }
    }

    @Test
    func watcherStartupFailureDoesNotManufactureARefresh() async throws {
        let harness = FolderRefreshHarness()
        harness.watcher.failAtStartup = true
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        await drainTasks()
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        await drainTasks()
        #expect(harness.requests.isEmpty)
        #expect(harness.watcher.requests.count == 1)
    }

    private var home: String { "/refresh/home" }
    private var downloads: String { home + "/Downloads" }
    private var documents: String { home + "/Documents" }

    private func changedFile(_ path: String) -> FileSystemEventRecord {
        FileSystemEventRecord(path: path, eventID: 43, flags: [.itemModified, .itemIsFile])
    }

    private func makeFolderRefreshSnapshot(
        id: UUID = UUID(),
        kind: ScanTargetKind = .folder,
        isComplete: Bool = true,
        source: ScanSnapshotSource = .live,
        options: ScanOptions = ScanOptions(),
        hasNewDownload: Bool = false
    ) -> ScanSnapshot {
        let file = makeTestFileNode(id: downloads + "/new.zip", name: "new.zip", size: 100)
        let downloadChildren = hasNewDownload ? [file] : []
        let downloadNode = makeTestDirectoryNode(id: downloads, name: "Downloads", children: downloadChildren)
        let documentNode = makeTestDirectoryNode(id: documents, name: "Documents", children: [])
        let root = makeTestDirectoryNode(id: home, name: "home", children: [downloadNode, documentNode])
        return ScanSnapshot(
            id: id,
            target: ScanTarget(url: URL(filePath: home, directoryHint: .isDirectory), kind: kind),
            treeStore: FileTreeStore(root: root, childrenByID: [home: [downloadNode, documentNode], downloads: downloadChildren]),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            scanWarnings: [],
            isComplete: isComplete,
            scanOptions: options,
            source: source,
            incrementalCheckpoint: ScanIncrementalCheckpoint(volumeUUID: "test-volume", eventID: 42)
        )
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class FolderRefreshHarness {
    let watcher = ControlledFolderChangeWatcher()
    let clock = ManualTestClock()
    var requests: [String] = []
    var allowsRequests = true
    var sleepRequests = 0
    private let maximumPendingPaths: Int
    lazy var controller = FolderRefreshController(
        watcher: watcher,
        maximumPendingPaths: maximumPendingPaths,
        now: { [clock] in clock.now },
        sleep: { [weak self, clock] in
            self?.sleepRequests += 1
            try await clock.sleep(for: $0)
        },
        requestRefresh: { [weak self] nodeID in
            self?.requests.append(nodeID)
            return self?.allowsRequests == true
        }
    )

    init(maximumPendingPaths: Int = 4_096) {
        self.maximumPendingPaths = maximumPendingPaths
    }
}

private nonisolated final class ControlledFolderChangeWatcher: FileSystemChangeWatching, @unchecked Sendable {
    struct Request {
        let targetURL: URL
        let checkpoint: ScanIncrementalCheckpoint?
    }
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var continuations: [AsyncThrowingStream<[FileSystemEventRecord], Error>.Continuation] = []
    private var cancellationCount = 0
    private var shouldFail = false

    var requests: [Request] { lock.withLock { recordedRequests } }
    var cancelledStreams: Int { lock.withLock { cancellationCount } }
    var failAtStartup: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func changes(for targetURL: URL, since checkpoint: ScanIncrementalCheckpoint?) -> AsyncThrowingStream<[FileSystemEventRecord], Error> {
        AsyncThrowingStream { continuation in
            let fail = lock.withLock {
                recordedRequests.append(Request(targetURL: targetURL, checkpoint: checkpoint))
                continuations.append(continuation)
                return shouldFail
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                self.lock.withLock { self.cancellationCount += 1 }
            }
            if fail { continuation.finish(throwing: FileSystemEventHistoryError.streamStartFailed) }
        }
    }

    func emit(_ events: [FileSystemEventRecord]) {
        let continuation = lock.withLock { continuations.last }
        continuation?.yield(events)
    }
}
