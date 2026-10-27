import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppModelFolderRefreshTests {
    @Test
    func discardPileUndoPreemptsBackgroundRefresh() async throws {
        let fixture = AppFolderRefreshFixture()
        let harness = AppFolderRefreshHarness()
        defer { harness.model.cleanup() }
        let model = harness.model
        model.scanState.restoreCompletedSnapshot(fixture.snapshot)
        model.focus(nodeID: fixture.downloads.id)
        #expect(model.addNodesToDiscardPile([fixture.markedDownload]))
        #expect(model.canUndoDiscardPileChange)
        try await waitForFolderRefresh("undo watcher") { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
        try await waitForFolderRefresh("undo background scan") { harness.scanner.requests.count == 1 }
        let task = try #require(model.scanState.scanTask)
        #expect(model.canUndoDiscardPileChange)
        model.undoDiscardPileChange()
        #expect(task.isCancelled)
        #expect(model.discardPile.nodeIDs.isEmpty)
        #expect(model.canRedoDiscardPileChange)
    }

    @Test(arguments: [false, true])
    func expandFullyPreemptsBackgroundRefresh(inPublicationWait: Bool) async throws {
        let fixture = AppFolderRefreshFixture(summarizeDocuments: true)
        let harness = AppFolderRefreshHarness()
        defer { harness.model.cleanup() }
        let task: Task<Void, Never>
        var gate: AppFolderRefreshApplicationGate?
        defer { gate?.restore() }
        if inPublicationWait {
            let pending = try await stageAppFolderBackgroundReplacement(harness, fixture: fixture)
            task = pending.task
            gate = pending.gate
        } else {
            try await beginAppFolderBackgroundRefresh(harness, fixture: fixture)
            task = try #require(harness.model.scanState.scanTask)
        }
        harness.model.expandSummarizedNode(fixture.documents) {}
        #expect(harness.model.scanState.expandingNodeID == fixture.documents.id)
        #expect(harness.scanner.requests.count == 2)
        #expect(task.isCancelled)
    }

    @Test
    func nativeFileDragPausesAutomaticRefreshAndPublicationUntilSessionsEnd() async throws {
        let fixture = AppFolderRefreshFixture()
        var actions = AppSystemActions.inert
        actions.verifyTrashIdentity = { node in
            guard let scannedIdentity = node.fileIdentity else { return .missingScannedIdentity }
            guard let currentIdentity = fixture.snapshot.treeStore.node(id: node.id)?.fileIdentity else {
                return .missingCurrentItem
            }
            return scannedIdentity == currentIdentity ? .matches : .mismatch
        }
        let harness = AppFolderRefreshHarness(systemActions: actions)
        defer { harness.model.cleanup() }
        let model = harness.model
        model.scanState.restoreCompletedSnapshot(fixture.snapshot)
        model.focus(nodeID: fixture.downloads.id)
        try await waitForFolderRefresh("native drag watcher") { harness.watcher.requests.count == 1 }
        let session = try #require(model.fileDragController.prepare(nodeIDs: [fixture.keptDownload.id]))
        defer { session.end(operation: []) }
        session.begin()
        #expect(model.fileDragController.isDragging)
        try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
        try await settleFolderRefreshTasks(for: .milliseconds(1_200))
        #expect(harness.scanner.requests.isEmpty)

        session.end(operation: [])
        #expect(!model.fileDragController.isDragging)
        try await waitForFolderRefresh("native drag pending event resumes") { harness.scanner.requests.count == 1 }
        let publishingSession = try #require(model.fileDragController.prepare(nodeIDs: [fixture.keptDownload.id]))
        defer { publishingSession.end(operation: []) }
        publishingSession.begin()
        let gate = AppFolderRefreshApplicationGate(coordinator: model.scanState)
        defer { gate.restore() }
        let updatedFile = fixture.file(fixture.keptDownload, withSize: 200)
        harness.scanner.finish(
            with: fixture.folderSnapshot(fixture.downloads, children: [updatedFile, fixture.markedDownload]),
            index: 0
        )
        try await waitForFolderRefresh("native drag blocks computed replacement") { gate.blockedChecks > 0 }
        #expect(model.scanState.isScanOperationInProgress)
        #expect(model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
        publishingSession.end(operation: [])
        try await waitForFolderRefresh("native drag pending update applied") {
            model.scanState.snapshot?.treeStore.node(id: updatedFile.id)?.allocatedSize == 200
                && !model.scanState.isScanOperationInProgress
        }
    }

    @Test(arguments: [false, true])
    func manualRescanAcknowledgesEarlierChangesAndPreservesLaterEvents(hasLaterChange: Bool) async throws {
        let clock = ManualTestClock()
        let harness = AppFolderRefreshHarness(clock: clock)
        defer { harness.model.cleanup() }
        let fixture = AppFolderRefreshFixture()
        let model = harness.model
        model.scanState.restoreCompletedSnapshot(fixture.snapshot)
        model.focus(nodeID: fixture.downloads.id)
        try await waitForFolderRefresh("manual refresh watcher") { harness.watcher.requests.count == 1 }

        try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
        model.rescanFolder(id: fixture.downloads.id)
        try await waitForFolderRefresh("manual refresh begins") { harness.scanner.requests.count == 1 }
        #expect(model.scanState.folderRescanState?.isBackground == false)
        if hasLaterChange {
            try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
        }
        harness.scanner.finish(
            with: fixture.folderSnapshot(fixture.downloads, children: [fixture.keptDownload, fixture.markedDownload]),
            index: 0
        )
        try await waitForFolderRefresh("manual refresh applied") { !model.scanState.isScanOperationInProgress }
        try await harness.watcher.emitAndWaitUntilProcessed([])

        if hasLaterChange {
            try await waitForFolderRefresh("later event schedules after cooldown") { clock.pendingSleeps == 1 }
            clock.advance(by: .seconds(6))
            try await waitForFolderRefresh("later event remains pending") { harness.scanner.requests.count == 2 }
            #expect(model.scanState.folderRescanState?.isBackground == true)
            let updatedFile = fixture.file(fixture.keptDownload, withSize: 200)
            harness.scanner.finish(
                with: fixture.folderSnapshot(fixture.downloads, children: [updatedFile, fixture.markedDownload]),
                index: 1
            )
            try await waitForFolderRefresh("later event applied") {
                model.scanState.snapshot?.treeStore.node(id: updatedFile.id)?.allocatedSize == 200
                    && !model.scanState.isScanOperationInProgress
            }
        } else {
            drainFolderRefreshRunLoop()
            clock.advance(by: .seconds(6))
            try await harness.watcher.emitAndWaitUntilProcessed([])
            #expect(clock.pendingSleeps == 0)
        }
        #expect(harness.scanner.requests.count == (hasLaterChange ? 2 : 1))
    }

    @Test
    func manualRescanPreemptsBackgroundRefreshAndIgnoresItsLateCompletion() async throws {
        let harness = AppFolderRefreshHarness()
        defer { harness.model.cleanup() }
        let fixture = AppFolderRefreshFixture()
        let model = harness.model
        let pending = try await stageAppFolderBackgroundReplacement(harness, fixture: fixture)
        defer { pending.gate.restore() }
        #expect(model.canRescanCurrentFolder)
        model.rescanFolder(id: fixture.downloads.id)
        try await waitForFolderRefresh("foreground rescan replaces background scan") {
            harness.scanner.requests.count == 2
        }
        #expect(model.scanState.folderRescanState?.isBackground == false)

        try await waitForRetiredFolderRefresh(pending.task)
        #expect(pending.task.isCancelled)
        pending.gate.restore()
        #expect(model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
        let updatedFile = fixture.file(fixture.keptDownload, withSize: 200)
        harness.scanner.finish(
            with: fixture.folderSnapshot(fixture.downloads, children: [updatedFile, fixture.markedDownload]),
            index: 1
        )
        try await waitForFolderRefresh("foreground rescan applied") {
            model.scanState.snapshot?.treeStore.node(id: updatedFile.id)?.allocatedSize == 200
                && !model.scanState.isScanOperationInProgress
        }
        #expect(model.navigation.focusedNodeID == fixture.downloads.id)
        #expect(harness.scanner.requests.count == 2)
        #expect(model.scanState.scanErrorMessage == nil)
    }

    @Test
    func choosingFolderPreemptsBackgroundRefreshAndIgnoresItsLateCompletion() async throws {
        let fixture = AppFolderRefreshFixture()
        var panelRequests = 0
        var actions = AppSystemActions.inert
        actions.presentOpenPanel = {
            panelRequests += 1
            return ScanTarget(url: fixture.documents.url)
        }
        let harness = AppFolderRefreshHarness(systemActions: actions)
        defer { harness.model.cleanup() }
        let model = harness.model
        let pending = try await stageAppFolderBackgroundReplacement(harness, fixture: fixture)
        defer { pending.gate.restore() }
        model.presentOpenPanelAndScan()
        try await waitForFolderRefresh("chosen folder scan starts") {
            harness.scanner.requests.count == 2
        }
        #expect(panelRequests == 1)
        #expect(harness.scanner.requests.last?.id == fixture.documents.id)
        #expect(model.scanState.folderRescanState == nil)
        try await waitForRetiredFolderRefresh(pending.task)
        #expect(pending.task.isCancelled)
        pending.gate.restore()
        #expect(model.scanState.snapshot == nil)

        let chosenSnapshot = fixture.folderSnapshot(fixture.documents, children: [fixture.document])
        harness.scanner.finish(with: chosenSnapshot, index: 1)
        try await waitForFolderRefresh("chosen folder snapshot applied") {
            model.scanState.snapshot?.id == chosenSnapshot.id && !model.scanState.isScanOperationInProgress
        }
        #expect(model.navigation.focusedNodeID == fixture.documents.id)
        #expect(model.scanState.scanErrorMessage == nil)
    }

    @Test
    func exportPanelPreemptsBackgroundRefreshAndIgnoresItsLateCompletion() async throws {
        let panel = AppFolderRefreshExportPanel()
        defer { panel.finish(with: nil) }
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { _ in await panel.chooseDestination() }
        let harness = AppFolderRefreshHarness(systemActions: actions)
        defer { harness.model.cleanup() }
        let fixture = AppFolderRefreshFixture()
        let model = harness.model
        let pending = try await stageAppFolderBackgroundReplacement(harness, fixture: fixture)
        defer { pending.gate.restore() }
        #expect(model.canExportCurrentScan)
        #expect(model.canImportScanSnapshot)
        #expect(model.canCompareScanSnapshots)
        model.exportCurrentScan()
        try await waitForFolderRefresh("export panel opens during background refresh") {
            panel.requests == 1
        }
        #expect(model.isExportPanelPresented)
        #expect(!model.scanState.isScanOperationInProgress)
        try await waitForRetiredFolderRefresh(pending.task)
        #expect(pending.task.isCancelled)
        pending.gate.restore()
        #expect(model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
        #expect(model.navigation.focusedNodeID == fixture.downloads.id)
        #expect(model.scanState.scanErrorMessage == nil)
        panel.finish(with: nil)
        try await waitForFolderRefresh("export panel cancelled") { !model.isExportPanelPresented }
        #expect(harness.scanner.requests.count == 1)
    }

    @Test
    func activeFolderRefreshAndNavigationCatchupPreserveWorkspace() async throws {
        let harness = AppFolderRefreshHarness()
        defer { harness.model.cleanup() }
        let fixture = AppFolderRefreshFixture()
        let model = harness.model
        model.scanState.restoreCompletedSnapshot(fixture.snapshot)
        model.focus(nodeID: fixture.downloads.id)
        model.select(nodeID: fixture.keptDownload.id)
        #expect(model.addNodesToDiscardPile([fixture.markedDownload]))
        try await waitForFolderRefresh("whole scan watcher") { harness.watcher.requests.count == 1 }
        #expect(harness.watcher.requests.first?.targetURL == fixture.snapshot.target.url)
        #expect(harness.watcher.requests.first?.checkpoint == fixture.snapshot.incrementalCheckpoint)

        let newDownload = makeTestFileNode(
            id: fixture.downloads.id + "/new.zip", name: "new.zip", size: 100,
            fileIdentity: FileIdentity(device: 1, inode: 104)
        )
        try await harness.watcher.emitAndWaitUntilProcessed([
            changedAppFolderFile(newDownload.id),
            changedAppFolderFile(fixture.document.id),
        ])
        try await waitForFolderRefresh("Downloads automatic refresh") { harness.scanner.requests.count == 1 }
        #expect(harness.scanner.requests.map(\.id) == [fixture.downloads.id])
        #expect(model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)

        harness.scanner.finish(
            with: fixture.folderSnapshot(
                fixture.downloads,
                children: [fixture.keptDownload, fixture.markedDownload, newDownload]
            ),
            index: 0
        )
        try await waitForFolderRefresh("Downloads applied without workspace reset") {
            model.scanState.snapshot?.treeStore.node(id: newDownload.id) != nil
                && !model.scanState.isScanOperationInProgress
        }
        #expect(model.scanState.snapshot?.id == fixture.snapshot.id)
        #expect(model.navigation.focusedNodeID == fixture.downloads.id)
        #expect(model.navigation.selectedNodeID == fixture.keptDownload.id)
        #expect(model.discardPile.nodeIDs == [fixture.markedDownload.id])
        #expect(model.discardPile.snapshotID == fixture.snapshot.id)
        #expect(model.scanState.snapshot?.treeStore.node(id: fixture.document.id) == fixture.document)
        #expect(model.scanState.scanCompletionNotice == nil)
        #expect(harness.scanner.requests.count == 1)

        // No new filesystem event is sent after navigation. The pending
        // Documents event must survive the Downloads snapshot replacement.
        model.focus(nodeID: fixture.documents.id)
        model.select(nodeID: fixture.document.id)
        try await waitForFolderRefresh("Documents catches up on navigation") {
            harness.scanner.requests.count == 2
        }
        #expect(harness.scanner.requests.map(\.id) == [fixture.downloads.id, fixture.documents.id])
        let updatedDocument = fixture.file(fixture.document, withSize: 200)
        harness.scanner.finish(
            with: fixture.folderSnapshot(fixture.documents, children: [updatedDocument]),
            index: 1
        )
        try await waitForFolderRefresh("Documents applied") {
            model.scanState.snapshot?.treeStore.node(id: fixture.document.id)?.allocatedSize == 200
                && !model.scanState.isScanOperationInProgress
        }
        #expect(model.scanState.snapshot?.id == fixture.snapshot.id)
        #expect(model.navigation.focusedNodeID == fixture.documents.id)
        #expect(model.navigation.selectedNodeID == fixture.document.id)
        #expect(model.discardPile.nodeIDs == [fixture.markedDownload.id])
        #expect(model.scanState.snapshot?.treeStore.node(id: newDownload.id) == newDownload)
        #expect(harness.watcher.requests.count == 1)
        #expect(model.scanState.scanErrorMessage == nil)
    }

    @Test
    func disablingAutomaticRefreshCancelsInFlightWorkAndKeepsDisplayedResults() async throws {
        let harness = AppFolderRefreshHarness(isEnabled: false)
        defer { harness.model.cleanup() }
        let fixture = AppFolderRefreshFixture()
        let model = harness.model
        model.scanState.restoreCompletedSnapshot(fixture.snapshot)
        model.focus(nodeID: fixture.downloads.id)
        try await settleFolderRefreshTasks(for: .milliseconds(20))
        #expect(harness.watcher.requests.isEmpty)
        #expect(harness.scanner.requests.isEmpty)

        model.automaticallyRefreshFocusedFolder = true
        try await waitForFolderRefresh("watcher enabled") { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
        try await waitForFolderRefresh("background scan begins") { harness.scanner.requests.count == 1 }
        let refreshTask = try #require(model.scanState.scanTask)
        #expect(model.scanState.folderRescanState?.isBackground == true)
        model.automaticallyRefreshFocusedFolder = false
        try await waitForFolderRefresh("setting cancels current scan and watcher") {
            !model.scanState.isScanOperationInProgress
                && harness.scanner.cancellations == 1
                && harness.watcher.cancellations == 1
        }
        try await waitForRetiredFolderRefresh(refreshTask)
        #expect(model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
        #expect(model.navigation.focusedNodeID == fixture.downloads.id)
        #expect(model.scanState.folderRescanState == nil)
        #expect(model.scanState.scanErrorMessage == nil)
        #expect(model.scanState.scanCompletionNotice == nil)
    }
}

@MainActor
private struct AppFolderRefreshHarness {
    let watcher = TestFileSystemChangeWatcher()
    let scanner = AppFolderRefreshScanner()
    let model: AppModel

    init(
        isEnabled: Bool = true,
        systemActions: AppSystemActions = .inert,
        clock: ManualTestClock? = nil
    ) {
        var systemActions = systemActions
        systemActions.isExistingDirectory = { _ in true }
        var preferences = AppScanPreferences.defaults
        preferences.automaticallyRefreshFocusedFolder = isEnabled
        model = AppModel(dependencies: AppDependencies(
            preferences: TestAppPreferencesStore(preferences: AppPreferences(
                scan: preferences,
                didCompleteOnboarding: true
            )),
            recentTargets: RecentTargetStore(
                persistence: TestRecentTargetPersistence(),
                isAvailable: { _ in false }
            ),
            systemActions: systemActions,
            scanService: scanner,
            fileSystemChangeWatcher: watcher,
            folderRefreshClock: clock.map { clock in
                FolderRefreshClock(now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
            } ?? .continuous
        ))
    }
}

private struct AppFolderRefreshFixture {
    let keptDownload = makeTestFileNode(
        id: "/app/folder-refresh/Downloads/kept.dat", name: "kept.dat", size: 10,
        fileIdentity: FileIdentity(device: 1, inode: 101)
    )
    let markedDownload = makeTestFileNode(
        id: "/app/folder-refresh/Downloads/marked.dat", name: "marked.dat", size: 20,
        fileIdentity: FileIdentity(device: 1, inode: 102)
    )
    let document = makeTestFileNode(
        id: "/app/folder-refresh/Documents/report.pdf", name: "report.pdf", size: 30,
        fileIdentity: FileIdentity(device: 1, inode: 103)
    )
    let downloads: FileNodeRecord
    let documents: FileNodeRecord
    let snapshot: ScanSnapshot

    init(summarizeDocuments: Bool = false) {
        downloads = makeTestDirectoryNode(
            id: "/app/folder-refresh/Downloads", name: "Downloads", children: [keptDownload, markedDownload]
        )
        documents = summarizeDocuments
            ? makeTestSummarizedDirectoryNode(id: "/app/folder-refresh/Documents", name: "Documents", size: 30)
            : makeTestDirectoryNode(id: "/app/folder-refresh/Documents", name: "Documents", children: [document])
        let root = makeTestDirectoryNode(
            id: "/app/folder-refresh", name: "Home", children: [downloads, documents]
        )
        var childrenByID = [root.id: [downloads, documents], downloads.id: [keptDownload, markedDownload]]
        if !summarizeDocuments { childrenByID[documents.id] = [document] }
        snapshot = makeTestSnapshot(
            target: makeTestTarget(root.id),
            root: root,
            store: FileTreeStore(root: root, childrenByID: childrenByID),
            scanOptions: ScanOptions(),
            incrementalCheckpoint: ScanIncrementalCheckpoint(volumeUUID: "fixture-volume", eventID: 10)
        )
    }

    func folderSnapshot(_ folder: FileNodeRecord, children: [FileNodeRecord]) -> ScanSnapshot {
        let root = makeTestDirectoryNode(id: folder.id, name: folder.name, children: children)
        return makeTestSnapshot(
            target: makeTestTarget(folder.id),
            root: root,
            store: FileTreeStore(root: root, childrenByID: [root.id: children]),
            scanOptions: ScanOptions()
        )
    }

    func file(_ node: FileNodeRecord, withSize size: Int64) -> FileNodeRecord {
        makeTestFileNode(id: node.id, name: node.name, size: size, fileIdentity: node.fileIdentity)
    }
}

private func changedAppFolderFile(_ path: String) -> FileSystemEventRecord {
    FileSystemEventRecord(path: path, eventID: 11, flags: [.itemModified, .itemIsFile])
}

@MainActor
private func waitForFolderRefresh(_ description: String, condition: @escaping @MainActor () -> Bool) async throws {
    try await waitUntil(description) {
        drainFolderRefreshRunLoop()
        return condition()
    }
}

@MainActor
private func drainFolderRefreshRunLoop() {
    _ = RunLoop.main.run(mode: .default, before: Date())
}

@MainActor
private func settleFolderRefreshTasks(for duration: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: duration)
    repeat {
        drainFolderRefreshRunLoop()
        try await Task.sleep(for: .milliseconds(1))
    } while ContinuousClock.now < deadline
    drainFolderRefreshRunLoop()
}

@MainActor
private func waitForRetiredFolderRefresh(_ task: Task<Void, Never>) async throws {
    var finished = false
    let completion = Task {
        await task.value
        finished = true
    }
    defer { completion.cancel() }
    try await waitForFolderRefresh("retired folder refresh completes") { finished }
}

@MainActor
private func beginAppFolderBackgroundRefresh(
    _ harness: AppFolderRefreshHarness,
    fixture: AppFolderRefreshFixture
) async throws {
    harness.model.scanState.restoreCompletedSnapshot(fixture.snapshot)
    harness.model.focus(nodeID: fixture.downloads.id)
    try await waitForFolderRefresh("preemption watcher") { harness.watcher.requests.count == 1 }
    try await harness.watcher.emitAndWaitUntilProcessed([changedAppFolderFile(fixture.keptDownload.id)])
    try await waitForFolderRefresh("preemption background scan begins") { harness.scanner.requests.count == 1 }
    #expect(harness.model.scanState.folderRescanState?.isBackground == true)
}

@MainActor
private func stageAppFolderBackgroundReplacement(
    _ harness: AppFolderRefreshHarness,
    fixture: AppFolderRefreshFixture
) async throws -> (task: Task<Void, Never>, gate: AppFolderRefreshApplicationGate) {
    try await beginAppFolderBackgroundRefresh(harness, fixture: fixture)
    let task = try #require(harness.model.scanState.scanTask)
    let gate = AppFolderRefreshApplicationGate(coordinator: harness.model.scanState, holdsPublication: true)
    harness.scanner.finish(with: fixture.folderSnapshot(fixture.downloads, children: []), index: 0)
    do {
        try await waitForFolderRefresh("computed background replacement awaits publication") { gate.blockedChecks > 0 }
    } catch {
        gate.restore()
        throw error
    }
    #expect(harness.scanner.cancellations == 0)
    #expect(harness.model.scanState.isScanOperationInProgress)
    #expect(harness.model.scanState.snapshot?.treeStore.contentID == fixture.snapshot.treeStore.contentID)
    return (task, gate)
}

@MainActor
private final class AppFolderRefreshApplicationGate {
    private let coordinator: ScanCoordinator
    private let original: () -> Bool
    private(set) var blockedChecks = 0

    init(coordinator: ScanCoordinator, holdsPublication: Bool = false) {
        self.coordinator = coordinator
        original = coordinator.canApplyBackgroundRefresh
        coordinator.canApplyBackgroundRefresh = { [weak self] in
            guard let self else { return false }
            let canApply = original() && !holdsPublication
            if !canApply { blockedChecks += 1 }
            return canApply
        }
    }

    func restore() {
        coordinator.canApplyBackgroundRefresh = original
    }
}

@MainActor
private final class AppFolderRefreshExportPanel {
    private(set) var requests = 0
    private var continuation: CheckedContinuation<URL?, Never>?

    func chooseDestination() async -> URL? {
        await withCheckedContinuation { continuation in
            requests += 1
            self.continuation = continuation
        }
    }

    func finish(with destination: URL?) {
        continuation?.resume(returning: destination)
        continuation = nil
    }
}

private nonisolated final class AppFolderRefreshScanner: ScanEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [ScanTarget] = []
    private var storedCancellations = 0
    private var continuations: [AsyncThrowingStream<ScanProgressEvent, Error>.Continuation] = []

    var requests: [ScanTarget] { lock.withLock { storedRequests } }
    var cancellations: Int { lock.withLock { storedCancellations } }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                storedRequests.append(target)
                continuations.append(continuation)
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                self.lock.withLock { self.storedCancellations += 1 }
            }
        }
    }

    func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions,
        preservingMaterializedDirectoriesIn treeStore: FileTreeStore?
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
    }

    func rescan(target: ScanTarget, options: ScanOptions, from baseline: ScanSnapshot)
        -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
    }

    func finish(with snapshot: ScanSnapshot, index: Int) {
        let continuation = lock.withLock { continuations[index] }
        continuation.yield(.finished(snapshot))
        continuation.finish()
    }
}
