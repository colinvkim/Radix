import AppKit
import Combine
import XCTest
@testable import RadixCore

final class AppModelDependencyTests: XCTestCase {
    @MainActor
    func testInitializesFromInjectedPreferencesTargetsAndRecentStore() {
        let availableRecent = makeAppModelTarget("/recent/available")
        let missingRecent = makeAppModelTarget("/recent/missing")
        let defaultTarget = makeAppModelTarget("/default")
        let preferences = SpyAppPreferencesStore(
            preferences: AppPreferences(
                scan: AppScanPreferences(
                    showHiddenFiles: false,
                    treatPackagesAsDirectories: true,
                    maxRenderedDepth: 8,
                    autoSummarizeDirectories: false
                ),
                didCompleteOnboarding: true
            )
        )
        let recentPersistence = SpyRecentTargetPersistence(targets: [availableRecent, missingRecent])
        var actions = AppSystemActions.inert
        actions.defaultTargets = { [defaultTarget] }
        actions.preferredSmartTargetIDs = { [defaultTarget.id] }
        actions.fullDiskAccessStatus = { .notGranted }

        let model = AppModel(
            dependencies: AppDependencies(
                preferences: preferences,
                recentTargets: RecentTargetStore(
                    persistence: recentPersistence,
                    isAvailable: { $0.id == availableRecent.id }
                ),
                systemActions: actions
            )
        )

        XCTAssertFalse(model.showHiddenFiles)
        XCTAssertTrue(model.treatPackagesAsDirectories)
        XCTAssertEqual(model.maxRenderedDepth, 8)
        XCTAssertFalse(model.autoSummarizeDirectories)
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(model.availableTargets, [defaultTarget])
        XCTAssertEqual(model.smartTargets, [defaultTarget])
        XCTAssertEqual(model.recentTargets, [availableRecent])
        XCTAssertEqual(model.fullDiskAccessStatus, .notGranted)
        XCTAssertEqual(recentPersistence.savedTargets, [[availableRecent]])
    }

    @MainActor
    func testSmartTargetsIncludeMountedVolumesBelowStartupDisk() {
        let startupDisk = makeAppModelTarget("/", kind: .volume)
        let externalVolume = makeAppModelTarget("/Volumes/External SSD", kind: .volume)
        let home = makeAppModelTarget("/Users/example")
        let desktop = makeAppModelTarget("/Users/example/Desktop")
        var actions = AppSystemActions.inert
        actions.defaultTargets = { [startupDisk, home, desktop, externalVolume] }
        actions.preferredSmartTargetIDs = { [startupDisk.id, home.id, desktop.id] }
        actions.targetCapacityDescriptions = {
            [
                startupDisk.id: "128 GB free of 1 TB",
                externalVolume.id: "512 GB free of 2 TB"
            ]
        }

        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.smartTargets, [startupDisk, externalVolume, home, desktop])
        XCTAssertEqual(model.sidebarSubtitle(for: startupDisk), "128 GB free of 1 TB")
        XCTAssertEqual(model.sidebarSubtitle(for: externalVolume), "512 GB free of 2 TB")
    }

    @MainActor
    func testPreferenceChangesPersistThroughInjectedStore() {
        let preferences = SpyAppPreferencesStore(preferences: .defaults)
        let model = AppModel(dependencies: makeDependencies(preferences: preferences))

        model.showHiddenFiles = false
        model.treatPackagesAsDirectories = true
        model.maxRenderedDepth = 10
        model.autoSummarizeDirectories = false

        XCTAssertEqual(
            preferences.savedScanPreferences.last,
            AppScanPreferences(
                showHiddenFiles: false,
                treatPackagesAsDirectories: true,
                maxRenderedDepth: 10,
                autoSummarizeDirectories: false
            )
        )

        model.dismissOnboarding()
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(preferences.markOnboardingCompleteCount, 1)

        model.presentOnboarding()
        XCTAssertTrue(model.showsOnboarding)
        XCTAssertEqual(preferences.markOnboardingCompleteCount, 1)
    }

    @MainActor
    func testFullDiskAccessFromOnboardingShowsWelcomeAfterRelaunch() {
        let preferences = SpyAppPreferencesStore(
            preferences: AppPreferences(
                scan: .defaults,
                didCompleteOnboarding: true
            )
        )
        var actions = AppSystemActions.inert
        var openSettingsCount = 0
        actions.prepareAndOpenFullDiskAccessSettings = {
            openSettingsCount += 1
            return true
        }
        actions.fullDiskAccessStatus = { .notGranted }
        let model = AppModel(dependencies: makeDependencies(preferences: preferences, systemActions: actions))

        XCTAssertFalse(model.showsOnboarding)

        model.presentOnboarding()
        model.prepareAndOpenFullDiskAccessSettingsFromOnboarding()

        XCTAssertTrue(model.showsOnboarding)
        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertEqual(preferences.markOnboardingIncompleteCount, 1)
        XCTAssertFalse(preferences.preferences.didCompleteOnboarding)

        let relaunchedModel = AppModel(dependencies: makeDependencies(preferences: preferences, systemActions: actions))
        XCTAssertTrue(relaunchedModel.showsOnboarding)
    }

    @MainActor
    func testSelectedFileActionsUseInjectedSystemActions() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.open = { recorder.openedURLs.append($0) }
        actions.reveal = { recorder.revealedURLs.append($0) }
        actions.copyPath = { recorder.copiedPathURLs.append($0) }
        actions.quickLook = AppQuickLookActions(
            isPreviewVisible: { false },
            isPreviewPanelKeyWindow: { false },
            present: { recorder.presentedQuickLookURLs.append($0) },
            toggle: { recorder.toggledQuickLookURLs.append($0) },
            updateVisiblePreview: { recorder.updatedQuickLookURLs.append($0) },
            close: { recorder.quickLookCloseCount += 1 }
        )
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.revealSelectedInFinder()
        model.openSelected()
        model.copySelectedPath()
        model.previewSelectedWithQuickLook()
        model.toggleQuickLookForSelected()

        XCTAssertEqual(recorder.revealedURLs, [file.url])
        XCTAssertEqual(recorder.openedURLs, [file.url])
        XCTAssertEqual(recorder.copiedPathURLs, [file.url])
        XCTAssertEqual(recorder.presentedQuickLookURLs, [file.url])
        XCTAssertEqual(recorder.toggledQuickLookURLs, [file.url])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testInstallsQuickLookKeyMonitorOnInit() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        installRecordingQuickLookMonitor(on: &actions, recorder: recorder)

        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(recorder.quickLookKeyHandlers.count, 1)
        withExtendedLifetime(model) {}
    }

    @MainActor
    func testCleanupRemovesQuickLookKeyMonitorOnce() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        installRecordingQuickLookMonitor(on: &actions, recorder: recorder)

        var model: AppModel? = AppModel(dependencies: makeDependencies(systemActions: actions))

        model?.cleanup()
        model?.cleanup()
        model = nil

        XCTAssertEqual(recorder.quickLookMonitorRemovalCount, 1)
    }

    @MainActor
    func testDeinitRemovesQuickLookKeyMonitor() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        installRecordingQuickLookMonitor(on: &actions, recorder: recorder)

        var model: AppModel? = AppModel(dependencies: makeDependencies(systemActions: actions))
        XCTAssertNotNil(model)
        XCTAssertEqual(recorder.quickLookKeyHandlers.count, 1)

        model = nil

        XCTAssertEqual(recorder.quickLookMonitorRemovalCount, 1)
    }

    @MainActor
    func testQuickLookKeyMonitorSpaceTogglesSelectedItemThroughDependency() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.quickLook = AppQuickLookActions(
            isPreviewVisible: { false },
            isPreviewPanelKeyWindow: { false },
            present: { _ in },
            toggle: { recorder.toggledQuickLookURLs.append($0) },
            updateVisiblePreview: { _ in },
            close: {}
        )
        installRecordingQuickLookMonitor(on: &actions, recorder: recorder)
        let preferences = SpyAppPreferencesStore(
            preferences: AppPreferences(
                scan: .defaults,
                didCompleteOnboarding: true
            )
        )
        let model = AppModel(dependencies: makeDependencies(preferences: preferences, systemActions: actions))
        let file = installSelection(on: model)

        let didHandleEvent = recorder.quickLookKeyHandlers.first?(makeSpaceKeyEvent())

        XCTAssertEqual(didHandleEvent, true)
        XCTAssertEqual(recorder.toggledQuickLookURLs, [file.url])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testUnavailableSelectionClearsSelectionAndSkipsInjectedAction() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in false }
        actions.open = { recorder.openedURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.openSelected()

        XCTAssertTrue(recorder.openedURLs.isEmpty)
        XCTAssertNil(model.navigation.selectedNodeID)
        XCTAssertEqual(
            model.lastErrorMessage,
            "The item at \(file.url.path) is no longer available."
        )
    }

    @MainActor
    func testZoomIntoCollapsedPackageMentionsSettingsToggle() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let payload = makeAppModelFileNode(
            id: "/selection/Sample.app/Contents/MacOS/Binary",
            name: "Binary",
            size: 42
        )
        let package = makeAppModelDirectoryNode(
            id: "/selection/Sample.app",
            name: "Sample.app",
            children: [payload],
            isPackage: true
        )
        let root = makeAppModelDirectoryNode(id: "/selection", name: "selection", children: [package])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [package]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url),
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.navigation.setFocusedNodeID(root.id)
        model.select(nodeID: package.id)

        model.zoomIntoSelection()

        XCTAssertEqual(model.errorAlertTitle, "Package Contents Hidden")
        XCTAssertEqual(
            model.lastErrorMessage,
            "Radix scanned this package as a single item. To zoom into it, turn on “Treat app bundles and packages as folders” in Settings, then rescan this location."
        )
        XCTAssertEqual(model.navigation.currentFocusNode?.id, root.id)
    }

    @MainActor
    func testQuickLookVisibleSelectionChangesUpdateAndCloseThroughDependency() {
        let recorder = AppModelActionRecorder()
        recorder.isQuickLookVisible = true
        var actions = AppSystemActions.inert
        actions.quickLook = AppQuickLookActions(
            isPreviewVisible: { recorder.isQuickLookVisible },
            isPreviewPanelKeyWindow: { false },
            present: { _ in },
            toggle: { _ in },
            updateVisiblePreview: { recorder.updatedQuickLookURLs.append($0) },
            close: { recorder.quickLookCloseCount += 1 }
        )
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model, selectNode: false)

        model.select(nodeID: file.id)
        XCTAssertEqual(recorder.updatedQuickLookURLs, [file.url])

        model.select(nodeID: nil)
        XCTAssertEqual(recorder.quickLookCloseCount, 1)
    }

    @MainActor
    func testAppModelActionsUseNarrowStateOwners() {
        let model = AppModel(dependencies: makeDependencies())
        let file = installSelection(on: model, selectNode: false)
        let target = makeAppModelTarget("/aligned")

        model.scanState.selectedTarget = target
        model.select(nodeID: file.id)

        XCTAssertEqual(model.scanState.selectedTarget, target)
        XCTAssertEqual(model.navigation.selectedNodeID, file.id)
        XCTAssertEqual(model.navigation.selectedNode?.id, file.id)
    }

    @MainActor
    func testAppModelDoesNotRebroadcastNarrowStateOwnerChanges() {
        let model = AppModel(dependencies: makeDependencies())
        let file = installSelection(on: model, selectNode: false)
        var observedAppModelChanges = 0

        let cancellable = model.objectWillChange.sink { _ in
            observedAppModelChanges += 1
        }

        var metrics = ScanMetrics()
        metrics.filesVisited = 12
        model.scanState.scanMetrics = metrics
        model.navigation.select(nodeID: file.id)

        XCTAssertEqual(observedAppModelChanges, 0)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testConfirmPendingTrashUsesInjectedFileActionsAndRefreshesTargets() {
        let recorder = AppModelActionRecorder()
        let refreshedTarget = makeAppModelTarget("/refreshed")
        recorder.defaultTargets = [refreshedTarget]
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        actions.defaultTargets = {
            recorder.defaultTargetsCallCount += 1
            return recorder.defaultTargets
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.pendingTrashNode = file
        model.confirmMovePendingNodeToTrash()

        XCTAssertEqual(recorder.movedToTrashURLs, [file.url])
        XCTAssertNil(model.pendingTrashNode)
        XCTAssertEqual(model.availableTargets, [refreshedTarget])
        XCTAssertEqual(recorder.defaultTargetsCallCount, 2)
    }

    @MainActor
    func testFullDiskAccessFailureUsesInjectedActionResult() {
        var actions = AppSystemActions.inert
        actions.prepareAndOpenFullDiskAccessSettings = { false }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        model.prepareAndOpenFullDiskAccessSettings()

        XCTAssertEqual(model.lastErrorMessage, "Radix could not open Full Disk Access settings.")
    }

    @MainActor
    func testFullDiskAccessStatusCanRefreshThroughInjectedProbe() {
        var statuses: [FullDiskAccessStatus] = [.notGranted, .granted]
        var actions = AppSystemActions.inert
        actions.fullDiskAccessStatus = {
            statuses.removeFirst()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.fullDiskAccessStatus, .notGranted)

        model.refreshFullDiskAccessStatus()

        XCTAssertEqual(model.fullDiskAccessStatus, .granted)
    }

    @MainActor
    func testAsyncFullDiskAccessRefreshAppliesLatestProbe() async throws {
        var actions = AppSystemActions.inert
        actions.asyncFullDiskAccessStatus = {
            .granted
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.fullDiskAccessStatus, .unknown)

        try await waitForAppModelCondition("async full disk access refresh applies") {
            model.fullDiskAccessStatus == .granted
        }
    }

    @MainActor
    func testAsyncCapacityDescriptionsDoNotDelayAvailableTargets() async throws {
        let probe = AsyncValueProbe<[String: String]>()
        let loadedTarget = makeAppModelTarget("/async-loaded")
        var actions = AppSystemActions.inert
        actions.defaultTargets = {
            [loadedTarget]
        }
        actions.asyncTargetCapacityDescriptions = {
            await probe.wait()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.availableTargets, [loadedTarget])
        XCTAssertTrue(model.targetCapacityDescriptions.isEmpty)

        try await waitForAsyncCondition("async capacity description refresh starts") {
            await probe.isWaiting
        }

        await probe.resume(returning: [loadedTarget.id: "1 GB free of 2 GB"])

        try await waitForAppModelCondition("async capacity descriptions apply") {
            model.targetCapacityDescriptions == [loadedTarget.id: "1 GB free of 2 GB"]
        }
    }

    @MainActor
    func testCleanupCancelsAsyncCapacityDescriptionRefresh() async throws {
        let probe = AsyncValueProbe<[String: String]>()
        let loadedTarget = makeAppModelTarget("/async-loaded")
        var actions = AppSystemActions.inert
        actions.defaultTargets = {
            [loadedTarget]
        }
        actions.asyncTargetCapacityDescriptions = {
            await probe.wait()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        try await waitForAsyncCondition("async capacity description refresh starts") {
            await probe.isWaiting
        }

        model.cleanup()
        await probe.resume(returning: [loadedTarget.id: "1 GB free of 2 GB"])

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.availableTargets, [loadedTarget])
        XCTAssertTrue(model.targetCapacityDescriptions.isEmpty)
    }
}

@MainActor
private func waitForAppModelCondition(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForAsyncCondition(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor AsyncValueProbe<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async -> Value {
        await withCheckedContinuation { pendingContinuation in
            continuation = pendingContinuation
        }
    }

    func resume(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private func makeDependencies(
    preferences: SpyAppPreferencesStore = SpyAppPreferencesStore(preferences: .defaults),
    recentPersistence: SpyRecentTargetPersistence = SpyRecentTargetPersistence(),
    availableRecentIDs: Set<String> = [],
    systemActions: AppSystemActions = .inert
) -> AppDependencies {
    AppDependencies(
        preferences: preferences,
        recentTargets: RecentTargetStore(
            persistence: recentPersistence,
            isAvailable: { availableRecentIDs.contains($0.id) }
        ),
        systemActions: systemActions
    )
}

@MainActor
private func installRecordingQuickLookMonitor(
    on actions: inout AppSystemActions,
    recorder: AppModelActionRecorder
) {
    actions.installQuickLookKeyMonitor = { handler in
        recorder.quickLookKeyHandlers.append(handler)
        return AppEventMonitorToken {
            recorder.quickLookMonitorRemovalCount += 1
        }
    }
}

private func makeSpaceKeyEvent() -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    ) else {
        fatalError("Failed to create Space key event")
    }
    return event
}

@MainActor
@discardableResult
private func installSelection(
    on model: AppModel,
    selectNode: Bool = true
) -> FileNodeRecord {
    let file = makeAppModelFileNode(id: "/selection/file.txt", name: "file.txt")
    let root = makeAppModelDirectoryNode(id: "/selection", name: "selection", children: [file])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    let snapshot = ScanSnapshot(
        target: ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: [],
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
    model.scanState.replaceCurrentSnapshot(snapshot)
    model.navigation.reconcileAfterSnapshotApplied(snapshot)
    model.navigation.setFocusedNodeID(root.id)

    if selectNode {
        model.select(nodeID: file.id)
    }

    return file
}

private func makeAppModelTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

private func makeAppModelFileNode(id: String, name: String, size: Int64 = 1) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeAppModelDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: isPackage,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private final class SpyAppPreferencesStore: AppPreferencesPersisting {
    var preferences: AppPreferences
    var savedScanPreferences: [AppScanPreferences] = []
    var markOnboardingCompleteCount = 0
    var markOnboardingIncompleteCount = 0

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppPreferences {
        preferences
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        self.preferences.scan = preferences
        savedScanPreferences.append(preferences)
    }

    func markOnboardingComplete() {
        preferences.didCompleteOnboarding = true
        markOnboardingCompleteCount += 1
    }

    func markOnboardingIncomplete() {
        preferences.didCompleteOnboarding = false
        markOnboardingIncompleteCount += 1
    }
}

private final class SpyRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget]
    var savedTargets: [[ScanTarget]] = []
    var didClear = false

    init(targets: [ScanTarget] = []) {
        self.targets = targets
    }

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
        savedTargets.append(targets)
    }

    func clearRecentTargets() {
        targets = []
        didClear = true
    }
}

@MainActor
private final class AppModelActionRecorder {
    var openedURLs: [URL] = []
    var revealedURLs: [URL] = []
    var copiedPathURLs: [URL] = []
    var movedToTrashURLs: [URL] = []
    var presentedQuickLookURLs: [URL] = []
    var toggledQuickLookURLs: [URL] = []
    var updatedQuickLookURLs: [URL?] = []
    var quickLookCloseCount = 0
    var isQuickLookVisible = false
    var quickLookKeyHandlers: [(NSEvent) -> Bool] = []
    var quickLookMonitorRemovalCount = 0
    var defaultTargets: [ScanTarget] = []
    var defaultTargetsCallCount = 0
}
