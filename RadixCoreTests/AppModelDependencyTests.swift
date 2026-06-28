import AppKit
import Combine
import XCTest
@testable import RadixCore

final class AppModelDependencyTests: XCTestCase {
    @MainActor
    func testInitializesFromInjectedPreferencesTargetsAndRecentStore() {
        let availableRecent = makeTestTarget("/recent/available")
        let missingRecent = makeTestTarget("/recent/missing")
        let defaultTarget = makeTestTarget("/default")
        let preferences = SpyAppPreferencesStore(
            preferences: AppPreferences(
                scan: AppScanPreferences(
                    showHiddenFiles: false,
                    treatPackagesAsDirectories: true,
                    maxRenderedDepth: 8,
                    autoSummarizeDirectories: false,
                    showFreeSpaceInSunburst: true,
                    scanCloudStorageFolders: true,
                    useScanExclusions: true,
                    exclusionPatterns: ["*.log"]
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
        XCTAssertTrue(model.showFreeSpaceInSunburst)
        XCTAssertTrue(model.scanCloudStorageFolders)
        XCTAssertTrue(model.useScanExclusions)
        XCTAssertEqual(model.exclusionPatterns, ["*.log"])
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(model.availableTargets, [defaultTarget])
        XCTAssertEqual(model.smartTargets, [defaultTarget])
        XCTAssertEqual(model.recentTargets, [availableRecent])
        XCTAssertEqual(model.fullDiskAccessStatus, .notGranted)
        XCTAssertEqual(recentPersistence.savedTargets, [[availableRecent]])
    }

    @MainActor
    func testRemoveRecentTargetPersistsRemainingTargets() {
        let first = makeTestTarget("/recent/first")
        let removed = makeTestTarget("/recent/removed")
        let last = makeTestTarget("/recent/last")
        let recentPersistence = SpyRecentTargetPersistence(targets: [first, removed, last])
        let model = AppModel(
            dependencies: makeDependencies(
                recentPersistence: recentPersistence,
                availableRecentIDs: Set([first.id, removed.id, last.id])
            )
        )

        model.removeRecentTarget(removed)

        XCTAssertEqual(model.recentTargets, [first, last])
        XCTAssertEqual(model.recentScanTargets, [first, last])
        XCTAssertEqual(recentPersistence.savedTargets, [[first, last]])
    }

    @MainActor
    func testClearRecentTargetsClearsActiveSidebarTarget() {
        let first = makeTestTarget("/recent/first")
        let recentPersistence = SpyRecentTargetPersistence(targets: [first])
        let model = AppModel(
            dependencies: makeDependencies(
                recentPersistence: recentPersistence,
                availableRecentIDs: Set([first.id])
            )
        )

        model.sidebar.setActiveTargetID(first.id)
        model.clearRecentTargets()

        XCTAssertNil(model.sidebar.activeTargetID)
        XCTAssertTrue(model.recentTargets.isEmpty)
        XCTAssertTrue(model.recentScanTargets.isEmpty)
        XCTAssertTrue(recentPersistence.didClear)
    }

    @MainActor
    func testPreferenceChangesPersistThroughInjectedStore() async throws {
        let preferences = SpyAppPreferencesStore(preferences: .defaults)
        let model = AppModel(dependencies: makeDependencies(preferences: preferences))
        let expectedPreferences = AppScanPreferences(
            showHiddenFiles: false,
            treatPackagesAsDirectories: true,
            maxRenderedDepth: 10,
            autoSummarizeDirectories: false,
            showFreeSpaceInSunburst: true,
            scanCloudStorageFolders: true,
            useScanExclusions: true,
            exclusionPatterns: ["node_modules"]
        )

        model.showHiddenFiles = false
        model.treatPackagesAsDirectories = true
        model.maxRenderedDepth = 10
        model.autoSummarizeDirectories = false
        model.showFreeSpaceInSunburst = true
        model.scanCloudStorageFolders = true
        model.useScanExclusions = true
        model.exclusionPatterns = ["node_modules"]

        try await waitUntil("coalesced preference persistence") {
            preferences.savedScanPreferences == [expectedPreferences]
        }

        model.dismissOnboarding()
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(preferences.markOnboardingCompleteCount, 1)

        model.presentOnboarding()
        XCTAssertTrue(model.showsOnboarding)
        XCTAssertEqual(preferences.markOnboardingCompleteCount, 1)
    }

    @MainActor
    func testCleanupFlushesPendingPreferencePersistence() {
        let preferences = SpyAppPreferencesStore(preferences: .defaults)
        let model = AppModel(dependencies: makeDependencies(preferences: preferences))
        let expectedPreferences = AppScanPreferences(
            showHiddenFiles: false,
            treatPackagesAsDirectories: AppScanPreferences.defaults.treatPackagesAsDirectories,
            maxRenderedDepth: AppScanPreferences.defaults.maxRenderedDepth,
            autoSummarizeDirectories: AppScanPreferences.defaults.autoSummarizeDirectories,
            showFreeSpaceInSunburst: AppScanPreferences.defaults.showFreeSpaceInSunburst,
            scanCloudStorageFolders: AppScanPreferences.defaults.scanCloudStorageFolders,
            useScanExclusions: AppScanPreferences.defaults.useScanExclusions,
            exclusionPatterns: AppScanPreferences.defaults.exclusionPatterns
        )

        model.showHiddenFiles = false
        model.cleanup()

        XCTAssertEqual(preferences.savedScanPreferences, [expectedPreferences])
    }

    @MainActor
    func testSunburstFreeSpaceCapacityRequiresEnabledVolumeRoot() {
        var requestedURLs: [URL] = []
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            requestedURLs.append(url)
            return 123
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let child = makeTestFileNode(id: "/volume/file.txt", name: "file.txt")
        let volumeRoot = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [child])
        let store = FileTreeStore(root: volumeRoot, childrenByID: [volumeRoot.id: [child]])
        let volumeSnapshot = makeTestSnapshot(
            target: ScanTarget(url: volumeRoot.url, kind: .volume),
            root: volumeRoot,
            store: store
        )

        XCTAssertNil(model.sunburstFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot))

        model.showFreeSpaceInSunburst = true

        XCTAssertEqual(model.sunburstFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot), 123)
        XCTAssertNil(model.sunburstFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: child))

        let folderSnapshot = makeTestSnapshot(root: volumeRoot, store: store)
        XCTAssertNil(model.sunburstFreeSpaceAvailableCapacity(for: folderSnapshot, focusNode: volumeRoot))
        XCTAssertEqual(requestedURLs, [volumeRoot.url])
    }

    @MainActor
    func testUsageStatsLoadAndRecordSunburstSegmentClicksThroughInjectedStore() {
        var storedStats = AppUsageStats.empty
        storedStats.sunburstSegmentsClicked = 4
        let usageStats = SpyAppUsageStatsStore(stats: storedStats)
        let model = AppModel(dependencies: makeDependencies(usageStats: usageStats))

        XCTAssertEqual(model.usageStats.sunburstSegmentsClicked, 4)

        model.recordSunburstSegmentClick()

        XCTAssertEqual(model.usageStats.sunburstSegmentsClicked, 5)
        XCTAssertEqual(usageStats.savedStats.last?.sunburstSegmentsClicked, 5)
    }

    @MainActor
    func testCompletedScansRecordUsageStats() async throws {
        let scanService = ControlledAppModelScanService()
        let usageStats = SpyAppUsageStatsStore()
        let model = AppModel(dependencies: makeDependencies(
            scanService: scanService,
            usageStats: usageStats
        ))
        let target = makeTestTarget("/stats-scan")
        let file = makeTestFileNode(id: "/stats-scan/file.bin", name: "file.bin", size: 120)
        let root = makeTestDirectoryNode(id: "/stats-scan", name: "stats-scan", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 20),
            finishedAt: Date(timeIntervalSince1970: 23),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )

        model.startScan(target)

        try await waitUntil("deferred stats scan started") {
            scanService.requests.count == 1
        }

        scanService.yield(.finished(snapshot), scanIndex: 0)
        scanService.finish(scanIndex: 0)

        try await waitUntil("usage stats recorded completed scan") {
            model.usageStats.totalScansRun == 1
        }

        XCTAssertEqual(model.usageStats.totalBytesScanned, 120)
        XCTAssertEqual(model.usageStats.largestScanBytes, 120)
        XCTAssertEqual(model.usageStats.averageScanBytesPerSecond, 40)
        XCTAssertEqual(model.usageStats.fastestScanBytesPerSecond, 40)
        XCTAssertEqual(usageStats.savedStats.last?.totalScansRun, 1)
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
    func testMultiSelectedFileActionsUseInjectedBulkSystemActions() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.revealMany = { recorder.revealedManyURLs.append($0) }
        actions.copyPaths = { recorder.copiedPathManyURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.navigation.setFocusedNodeID(root.id)
        model.select(nodeIDs: [first.id, second.id], primaryNodeID: first.id)

        model.revealSelectedInFinder()
        model.copySelectedPath()

        XCTAssertEqual(recorder.revealedManyURLs, [[first.url, second.url]])
        XCTAssertEqual(recorder.copiedPathManyURLs, [[first.url, second.url]])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testPrimarySelectedFileActionsUseOnlyPrimarySelection() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.reveal = { recorder.revealedURLs.append($0) }
        actions.revealMany = { recorder.revealedManyURLs.append($0) }
        actions.copyPath = { recorder.copiedPathURLs.append($0) }
        actions.copyPaths = { recorder.copiedPathManyURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.navigation.setFocusedNodeID(root.id)
        model.select(nodeIDs: [first.id, second.id], primaryNodeID: first.id)

        model.revealPrimarySelectionInFinder()
        model.copyPrimarySelectionPath()
        model.requestMovePrimarySelectionToTrash()

        XCTAssertEqual(recorder.revealedURLs, [first.url])
        XCTAssertTrue(recorder.revealedManyURLs.isEmpty)
        XCTAssertEqual(recorder.copiedPathURLs, [first.url])
        XCTAssertTrue(recorder.copiedPathManyURLs.isEmpty)
        XCTAssertEqual(model.pendingTrashSelection?.nodes.map(\.id), [first.id])
        XCTAssertEqual(model.pendingTrashNode?.id, first.id)
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
        model.setWorkspaceWindowNumber(100)

        let didHandleEvent = recorder.quickLookKeyHandlers.first?(makeSpaceKeyEvent(windowNumber: 100))

        XCTAssertEqual(didHandleEvent, true)
        XCTAssertEqual(recorder.toggledQuickLookURLs, [file.url])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testQuickLookKeyMonitorIgnoresSpaceOutsideWorkspaceWindow() {
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
        installSelection(on: model)
        model.setWorkspaceWindowNumber(100)

        let didHandleEvent = recorder.quickLookKeyHandlers.first?(makeSpaceKeyEvent(windowNumber: 200))

        XCTAssertEqual(didHandleEvent, false)
        XCTAssertTrue(recorder.toggledQuickLookURLs.isEmpty)
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
        let payload = makeTestFileNode(
            id: "/selection/Sample.app/Contents/MacOS/Binary",
            name: "Binary",
            size: 42
        )
        let package = makeTestDirectoryNode(
            id: "/selection/Sample.app",
            name: "Sample.app",
            children: [payload],
            isPackage: true
        )
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [package])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [package]])
        let snapshot = makeTestSnapshot(root: root, store: store)
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
        let target = makeTestTarget("/aligned")

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
        model.sidebar.setActiveTargetID("/sidebar")
        model.sidebar.replaceTargetCapacityDescriptions(["/": "128 GB free of 1 TB"])

        XCTAssertEqual(observedAppModelChanges, 0)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testConfirmPendingTrashUsesInjectedFileActionsAndRefreshesTargets() {
        let recorder = AppModelActionRecorder()
        let refreshedTarget = makeTestTarget("/refreshed")
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
    func testConfirmPendingTrashUsesAsyncTrashActionWithoutBlockingDismissal() async throws {
        let probe = AsyncTrashActionProbe()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.asyncVerifyTrashIdentity = { _ in .matches }
        actions.asyncMoveToTrash = { url in
            await probe.move(url)
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        model.scanState.selectedTarget = ScanTarget(url: URL(filePath: "/selection", directoryHint: .isDirectory))

        model.pendingTrashNode = file
        model.confirmMovePendingNodeToTrash()

        XCTAssertNil(model.pendingTrashNode)
        XCTAssertNil(model.pendingTrashSelection)

        try await probe.waitUntilStarted()
        let movedURLs = await probe.movedURLs()
        XCTAssertEqual(movedURLs, [file.url])
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: file.id))

        await probe.finish()

        try await waitUntil("async trash completed", timeout: 2) {
            model.scanState.snapshot?.treeStore.node(id: file.id) == nil ||
                model.lastErrorMessage != nil
        }
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertNil(
            model.scanState.snapshot?.treeStore.node(id: file.id),
            "selected target: \(model.scanState.selectedTarget?.id ?? "nil")"
        )
    }

    @MainActor
    func testConfirmPendingTrashRecordsCleanupUsageStats() {
        let recorder = AppModelActionRecorder()
        let usageStats = SpyAppUsageStatsStore()
        let first = makeTestFileNode(id: "/selection/folder/first.bin", name: "first.bin", size: 40)
        let second = makeTestFileNode(id: "/selection/folder/second.bin", name: "second.bin", size: 60)
        let folder = makeTestDirectoryNode(
            id: "/selection/folder",
            name: "folder",
            children: [first, second]
        )
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [first, second]
        ])
        var actions = AppSystemActions.inert
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            usageStats: usageStats
        ))
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [folder])
        model.pendingTrashNode = folder
        model.confirmMovePendingSelectionToTrash()

        XCTAssertEqual(recorder.movedToTrashURLs, [folder.url])
        XCTAssertEqual(model.usageStats.filesDeleted, 2)
        XCTAssertEqual(model.usageStats.foldersDeleted, 1)
        XCTAssertEqual(model.usageStats.bytesMovedToTrash, 100)
        XCTAssertEqual(model.usageStats.biggestSingleCleanupBytes, 100)
        XCTAssertEqual(usageStats.savedStats.last?.filesDeleted, 2)
        XCTAssertEqual(usageStats.savedStats.last?.foldersDeleted, 1)
    }

    @MainActor
    func testConfirmPendingTrashAllowsMatchingIdentity() {
        let recorder = AppModelActionRecorder()
        let identity = FileIdentity(device: 12, inode: 34)
        let file = makeTestFileNode(
            id: "/selection/file.txt",
            name: "file.txt",
            fileIdentity: identity
        )
        var verifiedNodeIDs: [String] = []
        var actions = AppSystemActions.inert
        actions.verifyTrashIdentity = { node in
            verifiedNodeIDs.append(node.id)
            return .matches
        }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashNode = file
        model.confirmMovePendingNodeToTrash()

        XCTAssertEqual(verifiedNodeIDs, [file.id])
        XCTAssertEqual(recorder.movedToTrashURLs, [file.url])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testConfirmPendingTrashBlocksMismatchedIdentity() {
        let recorder = AppModelActionRecorder()
        let file = makeTestFileNode(
            id: "/selection/replaced.txt",
            name: "replaced.txt",
            fileIdentity: FileIdentity(device: 1, inode: 2)
        )
        var actions = AppSystemActions.inert
        actions.verifyTrashIdentity = { _ in .mismatch }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashNode = file
        model.confirmMovePendingNodeToTrash()

        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(
            model.lastErrorMessage,
            "The item at \(file.url.path) changed since this scan. Rescan before moving it to Trash."
        )
    }

    @MainActor
    func testConfirmPendingTrashBlocksMissingScannedIdentity() {
        let recorder = AppModelActionRecorder()
        let file = makeTestFileNode(id: "/selection/unverified.txt", name: "unverified.txt")
        var actions = AppSystemActions.inert
        actions.verifyTrashIdentity = { _ in .missingScannedIdentity }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashNode = file
        model.confirmMovePendingNodeToTrash()

        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(
            model.lastErrorMessage,
            "Radix could not verify the scanned identity for \(file.url.path). Rescan before moving it to Trash."
        )
    }

    @MainActor
    func testConfirmPendingTrashBatchMismatchBlocksAllMoves() {
        let recorder = AppModelActionRecorder()
        let first = makeTestFileNode(
            id: "/selection/first.txt",
            name: "first.txt",
            fileIdentity: FileIdentity(device: 1, inode: 10)
        )
        let second = makeTestFileNode(
            id: "/selection/second.txt",
            name: "second.txt",
            fileIdentity: FileIdentity(device: 1, inode: 11)
        )
        var verifiedNodeIDs: [String] = []
        var actions = AppSystemActions.inert
        actions.verifyTrashIdentity = { node in
            verifiedNodeIDs.append(node.id)
            return node.id == second.id ? .mismatch : .matches
        }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [first, second])
        model.pendingTrashNode = first
        model.confirmMovePendingNodeToTrash()

        XCTAssertEqual(verifiedNodeIDs, [first.id, second.id])
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(
            model.lastErrorMessage,
            "The item at \(second.url.path) changed since this scan. Rescan before moving it to Trash."
        )
    }

    @MainActor
    func testRequestMoveSelectedToTrashRejectsProtectedRoots() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let protectedRoot = makeTestDirectoryNode(
            id: "/Applications",
            name: "Applications",
            children: []
        )
        let store = FileTreeStore(root: protectedRoot)
        let snapshot = makeTestSnapshot(root: protectedRoot, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.select(nodeID: protectedRoot.id)

        model.requestMoveSelectedToTrash()

        XCTAssertNil(model.pendingTrashNode)
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testRequestMoveNodesToTrashKeepsOnlyTopLevelSelectedNodes() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let child = makeTestFileNode(id: "/selection/folder/child.txt", name: "child.txt")
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [child])
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [child]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.requestMoveNodesToTrash([folder, child])

        XCTAssertEqual(model.pendingTrashSelection?.nodes.map(\.id), [folder.id])
        XCTAssertEqual(model.pendingTrashNode?.id, folder.id)
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
        let loadedTarget = makeTestTarget("/async-loaded")
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
    func testMountedVolumeRefreshUpdatesTrashSafetyPolicy() async throws {
        let mountedVolumeURL = URL(filePath: "/Volumes/Injected", directoryHint: .isDirectory)
        let mountedVolumeNode = makeTestDirectoryNode(id: mountedVolumeURL.path, name: "Injected", children: [])
        let mountedVolumeEvents = PassthroughSubject<Void, Never>()
        var protectsMountedVolume = false
        var actions = AppSystemActions.inert
        actions.defaultTargets = { [] }
        actions.trashSafetyPolicy = {
            TrashSafetyPolicy(
                homeDirectory: URL(filePath: "/Users/example", directoryHint: .isDirectory),
                mountedVolumeURLs: protectsMountedVolume ? [mountedVolumeURL] : [],
                firmlinkEntries: []
            )
        }
        actions.mountedVolumeEvents = {
            mountedVolumeEvents.eraseToAnyPublisher()
        }

        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        XCTAssertTrue(mountedVolumeNode.supportsMoveToTrash(trashSafetyPolicy: model.scanState.trashSafetyPolicy))

        protectsMountedVolume = true
        mountedVolumeEvents.send(())

        try await waitForAppModelCondition("trash safety policy refresh") {
            !mountedVolumeNode.supportsMoveToTrash(trashSafetyPolicy: model.scanState.trashSafetyPolicy)
        }
    }

    @MainActor
    func testCleanupCancelsAsyncCapacityDescriptionRefresh() async throws {
        let probe = AsyncValueProbe<[String: String]>()
        let loadedTarget = makeTestTarget("/async-loaded")
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

    @MainActor
    func testImportScanSnapshotRestoresReadOnlyImportedSnapshot() async throws {
        let archiveURL = URL(filePath: "/tmp/imported.radixscan", directoryHint: .isDirectory)
        let file = makeTestFileNode(id: "/imported/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/imported", name: "imported", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let importedSnapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "imported", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .imported(ImportedSnapshotContext(
                sourceURL: archiveURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
        )
        let manifest = try ScanArchiveDocument(
            exportedAt: Date(timeIntervalSince1970: 3),
            appVersion: "Tests",
            snapshot: importedSnapshot,
            pathMode: .absolute,
            sections: ScanArchiveSections(
                nodes: "nodes.jsonl",
                topology: "topology.json",
                warnings: "warnings.json",
                stats: "stats.json"
            ),
            nodeChecksum: "checksum"
        )
        let archiveService = SpyScanArchiveService(
            previewResult: ScanArchivePreview(
                archiveURL: archiveURL,
                archiveSize: 1,
                manifest: manifest,
                stats: ScanArchiveStatsV1(store.aggregateStats)
            ),
            importResult: ScanArchiveImportResult(
                archiveURL: archiveURL,
                snapshot: importedSnapshot,
                manifest: manifest
            )
        )
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))

        model.importScanSnapshot()

        try await waitForAppModelCondition("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertEqual(previewedURLs, [archiveURL])
        let importedURLsBeforeConfirm = await archiveService.importedURLsSnapshot()
        XCTAssertTrue(importedURLsBeforeConfirm.isEmpty)
        XCTAssertNil(model.scanState.snapshot)

        model.confirmImportPreview()

        try await waitForAppModelCondition("imported snapshot restored") {
            model.scanState.snapshot?.id == importedSnapshot.id
        }

        let importedURLs = await archiveService.importedURLsSnapshot()
        XCTAssertEqual(importedURLs, [archiveURL])
        XCTAssertNil(model.pendingImportPreview)
        XCTAssertEqual(model.scanState.selectedTarget, importedSnapshot.target)
        XCTAssertNil(model.scanState.completedScanSnapshot)
        XCTAssertFalse(model.scanState.snapshotSource.allowsFileMutation)
        XCTAssertEqual(model.navigation.focusedNodeID, importedSnapshot.root.id)

        model.select(nodeID: file.id)
        model.requestMoveSelectedToTrash()
        XCTAssertNil(model.pendingTrashNode)
        XCTAssertEqual(model.lastErrorMessage, "Imported snapshots are read-only.")
    }

    @MainActor
    func testImportPreviewDisablesStartingAnotherImport() async throws {
        let archiveURL = URL(filePath: "/tmp/import-preview.radixscan", directoryHint: .isDirectory)
        let file = makeTestFileNode(id: "/import-preview/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/import-preview", name: "import-preview", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let importedSnapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "import-preview", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .imported(ImportedSnapshotContext(
                sourceURL: archiveURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
        )
        let manifest = try ScanArchiveDocument(
            exportedAt: Date(timeIntervalSince1970: 3),
            appVersion: "Tests",
            snapshot: importedSnapshot,
            pathMode: .absolute,
            sections: ScanArchiveSections(
                nodes: "nodes.jsonl",
                topology: "topology.json",
                warnings: "warnings.json",
                stats: "stats.json"
            ),
            nodeChecksum: "checksum"
        )
        let archiveService = SpyScanArchiveService(
            previewResult: ScanArchivePreview(
                archiveURL: archiveURL,
                archiveSize: 1,
                manifest: manifest,
                stats: ScanArchiveStatsV1(store.aggregateStats)
            )
        )
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))

        model.importScanSnapshot()
        try await waitForAppModelCondition("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        XCTAssertFalse(model.canImportScanSnapshot)

        model.cancelImportPreview()

        XCTAssertTrue(model.canImportScanSnapshot)
    }

    @MainActor
    func testImportScanSnapshotDefersWideRootTableMaterializationUntilAfterSnapshotPublish() async throws {
        let archiveURL = URL(filePath: "/tmp/wide-imported.radixscan", directoryHint: .isDirectory)
        let childCount = 20_000
        let children = (0..<childCount).map { index in
            makeTestFileNode(
                id: "/wide-imported/file-\(String(format: "%05d", index)).txt",
                name: "file-\(String(format: "%05d", index)).txt",
                size: Int64(childCount - index)
            )
        }
        let root = makeTestDirectoryNode(id: "/wide-imported", name: "wide-imported", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let importedSnapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "wide-imported", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .imported(ImportedSnapshotContext(
                sourceURL: archiveURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
        )
        let manifest = try ScanArchiveDocument(
            exportedAt: Date(timeIntervalSince1970: 3),
            appVersion: "Tests",
            snapshot: importedSnapshot,
            pathMode: .absolute,
            sections: ScanArchiveSections(
                nodes: "nodes.jsonl",
                topology: "topology.json",
                warnings: "warnings.json",
                stats: "stats.json"
            ),
            nodeChecksum: "checksum"
        )
        let archiveService = SpyScanArchiveService(
            previewResult: ScanArchivePreview(
                archiveURL: archiveURL,
                archiveSize: 1,
                manifest: manifest,
                stats: ScanArchiveStatsV1(store.aggregateStats)
            ),
            importResult: ScanArchiveImportResult(
                archiveURL: archiveURL,
                snapshot: importedSnapshot,
                manifest: manifest
            )
        )
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))
        var tableNodeCountAtSnapshotPublish: Int?
        let snapshotCancellable = model.scanState.$snapshot.sink { snapshot in
            guard snapshot?.id == importedSnapshot.id else { return }
            tableNodeCountAtSnapshotPublish = model.navigation.tableNodes.count
        }

        model.importScanSnapshot()
        try await waitForAppModelCondition("wide import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        model.confirmImportPreview()
        try await waitForAppModelCondition("wide imported snapshot restored") {
            model.scanState.snapshot?.id == importedSnapshot.id
        }

        XCTAssertEqual(tableNodeCountAtSnapshotPublish, 0)
        XCTAssertEqual(model.navigation.focusedNodeID, root.id)

        try await waitForAppModelCondition("wide imported table materialized") {
            model.navigation.tableNodes.count == childCount
        }

        withExtendedLifetime(snapshotCancellable) {}
    }

    @MainActor
    func testURLImportWhileScanningShowsError() async throws {
        let scanService = NeverFinishingScanService()
        let model = AppModel(dependencies: makeDependencies(scanService: scanService))
        let scanTarget = ScanTarget(
            id: "/active-scan",
            url: URL(filePath: "/active-scan", directoryHint: .isDirectory),
            displayName: "active-scan",
            kind: .folder
        )

        model.startScan(scanTarget)
        try await waitForAppModelCondition("scan started") {
            model.scanState.isScanning
        }

        model.importScanSnapshot(from: URL(filePath: "/tmp/opened.radixscan", directoryHint: .isDirectory))

        XCTAssertEqual(model.lastErrorMessage, "Stop the current scan before importing a snapshot.")
    }

    @MainActor
    func testExportCurrentScanUsesInjectedPanelAndArchiveService() async throws {
        let archiveURL = URL(filePath: "/tmp/export.radixscan", directoryHint: .isDirectory)
        let archiveService = SpyScanArchiveService()
        let recorder = AppModelActionRecorder()
        var requestedDefaultFileNames: [String] = []
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { defaultFileName in
            requestedDefaultFileNames.append(defaultFileName)
            return archiveURL
        }
        actions.reveal = { recorder.revealedURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))
        let file = makeTestFileNode(id: "/export/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/export", name: "Export", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "Export", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitForAsyncCondition("export requested") {
            await !archiveService.exportRequestsSnapshot().isEmpty
        }

        let exportRequests = await archiveService.exportRequestsSnapshot()
        XCTAssertEqual(exportRequests.map(\.snapshotID), [snapshot.id])
        XCTAssertEqual(exportRequests.map(\.destinationURL), [archiveURL])
        XCTAssertEqual(exportRequests.map(\.pathMode), [.absolute])
        XCTAssertEqual(requestedDefaultFileNames.count, 1)
        XCTAssertTrue(requestedDefaultFileNames[0].hasPrefix("Export "))
        XCTAssertFalse(requestedDefaultFileNames[0].hasSuffix(".radixscan"))
        XCTAssertNil(model.lastErrorMessage)
        try await waitForAppModelCondition("export confirmation presented") {
            model.exportConfirmation?.archiveURL == archiveURL
        }

        model.revealExportedSnapshotInFinder()

        XCTAssertEqual(recorder.revealedURLs, [archiveURL])
        XCTAssertNil(model.exportConfirmation)
    }

    @MainActor
    func testExportFailureUsesExportSpecificAlertTitle() async throws {
        let archiveURL = URL(filePath: "/tmp/export.invalid", directoryHint: .isDirectory)
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { _ in archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = makeTestFileNode(id: "/failed-export/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/failed-export", name: "Failed Export", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "Failed Export", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitForAppModelCondition("export failure presented") {
            model.lastErrorMessage != nil
        }

        XCTAssertEqual(model.errorAlertTitle, "Export Failed")
        XCTAssertNil(model.exportConfirmation)
    }

    @MainActor
    func testExportShowsCancellableArchiveOperationWithoutClearingSnapshot() async throws {
        let archiveURL = URL(filePath: "/tmp/export-blocked.radixscan", directoryHint: .isDirectory)
        let exportProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(exportWaitProbe: exportProbe)
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { _ in archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))
        let file = makeTestFileNode(id: "/export-blocked/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/export-blocked", name: "Export", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "Export", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitForAppModelCondition("export operation visible") {
            model.archiveOperation?.kind == .export
        }

        XCTAssertFalse(model.canExportCurrentScan)
        XCTAssertFalse(model.canImportScanSnapshot)
        XCTAssertEqual(model.scanState.snapshot?.id, snapshot.id)

        try await waitForAsyncCondition("export request waiting") {
            await exportProbe.isWaiting
        }
        await exportProbe.resume(returning: ())

        try await waitForAppModelCondition("export operation cleared") {
            model.archiveOperation == nil
        }
    }

    @MainActor
    func testCancelArchiveOperationCancelsExportWork() async throws {
        let archiveURL = URL(filePath: "/tmp/export-cancelled.radixscan", directoryHint: .isDirectory)
        let exportProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(exportWaitProbe: exportProbe)
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { _ in archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))
        let file = makeTestFileNode(id: "/export-cancelled/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/export-cancelled", name: "Export", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "Export", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()
        try await waitForAsyncCondition("export request waiting") {
            await exportProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await exportProbe.resume(returning: ())

        try await waitForAsyncCondition("export cancellation recorded") {
            await archiveService.exportCancellationStatesSnapshot().count == 1
        }
        let states = await archiveService.exportCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
    }

    @MainActor
    func testCancelArchiveOperationCancelsImportPreviewWork() async throws {
        let archiveURL = URL(filePath: "/tmp/preview-cancelled.radixscan", directoryHint: .isDirectory)
        let previewProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(previewWaitProbe: previewProbe)
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))

        model.importScanSnapshot()
        try await waitForAsyncCondition("preview request waiting") {
            await previewProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await previewProbe.resume(returning: ())

        try await waitForAsyncCondition("preview cancellation recorded") {
            await archiveService.previewCancellationStatesSnapshot().count == 1
        }
        let states = await archiveService.previewCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
        XCTAssertNil(model.pendingImportPreview)
    }

    @MainActor
    func testCancelArchiveOperationCancelsImportWork() async throws {
        let archiveURL = URL(filePath: "/tmp/import-cancelled.radixscan", directoryHint: .isDirectory)
        let file = makeTestFileNode(id: "/import-cancelled/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/import-cancelled", name: "import-cancelled", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let importedSnapshot = ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "import-cancelled", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .imported(ImportedSnapshotContext(
                sourceURL: archiveURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
        )
        let manifest = try ScanArchiveDocument(
            exportedAt: Date(timeIntervalSince1970: 3),
            appVersion: "Tests",
            snapshot: importedSnapshot,
            pathMode: .absolute,
            sections: ScanArchiveSections(
                nodes: "nodes.jsonl",
                topology: "topology.json",
                warnings: "warnings.json",
                stats: "stats.json"
            ),
            nodeChecksum: "checksum"
        )
        let importProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(
            previewResult: ScanArchivePreview(
                archiveURL: archiveURL,
                archiveSize: 1,
                manifest: manifest,
                stats: ScanArchiveStatsV1(store.aggregateStats)
            ),
            importResult: ScanArchiveImportResult(
                archiveURL: archiveURL,
                snapshot: importedSnapshot,
                manifest: manifest
            ),
            importWaitProbe: importProbe
        )
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions, scanArchiveService: archiveService))

        model.importScanSnapshot()
        try await waitForAppModelCondition("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        model.confirmImportPreview()
        try await waitForAsyncCondition("import request waiting") {
            await importProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await importProbe.resume(returning: ())

        try await waitForAsyncCondition("import cancellation recorded") {
            await archiveService.importCancellationStatesSnapshot().count == 1
        }
        let states = await archiveService.importCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
        XCTAssertNil(model.scanState.snapshot)
    }

    @MainActor
    func testStartingScanCancelsPendingImportBeforeItRestoresSnapshot() async throws {
        let archiveURL = URL(filePath: "/tmp/import-race.radixscan", directoryHint: .isDirectory)
        let importedFile = makeTestFileNode(id: "/import-race/file.txt", name: "file.txt")
        let importedRoot = makeTestDirectoryNode(id: "/import-race", name: "import-race", children: [importedFile])
        let importedStore = FileTreeStore(root: importedRoot, childrenByID: [importedRoot.id: [importedFile]])
        let importedSnapshot = ScanSnapshot(
            target: ScanTarget(id: importedRoot.id, url: importedRoot.url, displayName: "import-race", kind: .folder),
            treeStore: importedStore,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            aggregateStats: importedStore.aggregateStats,
            isComplete: true,
            source: .imported(ImportedSnapshotContext(
                sourceURL: archiveURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
        )
        let manifest = try ScanArchiveDocument(
            exportedAt: Date(timeIntervalSince1970: 3),
            appVersion: "Tests",
            snapshot: importedSnapshot,
            pathMode: .absolute,
            sections: ScanArchiveSections(
                nodes: "nodes.jsonl",
                topology: "topology.json",
                warnings: "warnings.json",
                stats: "stats.json"
            ),
            nodeChecksum: "checksum"
        )
        let importProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(
            previewResult: ScanArchivePreview(
                archiveURL: archiveURL,
                archiveSize: 1,
                manifest: manifest,
                stats: ScanArchiveStatsV1(importedStore.aggregateStats)
            ),
            importResult: ScanArchiveImportResult(
                archiveURL: archiveURL,
                snapshot: importedSnapshot,
                manifest: manifest
            ),
            importWaitProbe: importProbe
        )
        var actions = AppSystemActions.inert
        actions.presentImportScanPanel = { archiveURL }
        let scanService = NeverFinishingScanService()
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanService: scanService,
            scanArchiveService: archiveService
        ))

        model.importScanSnapshot()
        try await waitForAppModelCondition("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }
        model.confirmImportPreview()
        try await waitForAsyncCondition("import request waiting") {
            await importProbe.isWaiting
        }

        let liveTarget = ScanTarget(
            id: "/live-scan",
            url: URL(filePath: "/live-scan", directoryHint: .isDirectory),
            displayName: "live-scan",
            kind: .folder
        )
        model.startScan(liveTarget)
        try await waitForAppModelCondition("live scan started") {
            model.scanState.selectedTarget == liveTarget && model.scanState.isScanning
        }

        await importProbe.resume(returning: ())
        try await waitForAsyncCondition("import cancellation recorded") {
            await archiveService.importCancellationStatesSnapshot().count == 1
        }

        let states = await archiveService.importCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
        XCTAssertEqual(model.scanState.selectedTarget, liveTarget)
        XCTAssertNotEqual(model.scanState.snapshot?.id, importedSnapshot.id)
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

private final class NeverFinishingScanService: ScanEventStreaming, @unchecked Sendable {
    private var continuations: [AsyncThrowingStream<ScanProgressEvent, Error>.Continuation] = []

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            continuations.append(continuation)
        }
    }
}

private final class ControlledAppModelScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ScanTarget] = []

    var requests: [ScanTarget] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            storedRequests.append(target)
            lock.unlock()
        }
    }

    func yield(_ event: ScanProgressEvent, scanIndex: Int) {
        continuation(at: scanIndex)?.yield(event)
    }

    func finish(scanIndex: Int, throwing error: Error? = nil) {
        continuation(at: scanIndex)?.finish(throwing: error)
    }

    private func continuation(at index: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }
}

@MainActor
private func makeDependencies(
    preferences: SpyAppPreferencesStore = SpyAppPreferencesStore(preferences: .defaults),
    recentPersistence: SpyRecentTargetPersistence = SpyRecentTargetPersistence(),
    availableRecentIDs: Set<String> = [],
    systemActions: AppSystemActions = .inert,
    scanService: any ScanEventStreaming = ScanEngine(),
    scanArchiveService: any ScanArchiveServicing = ScanArchiveService(),
    usageStats: any AppUsageStatsPersisting = InMemoryAppUsageStatsStore()
) -> AppDependencies {
    AppDependencies(
        preferences: preferences,
        recentTargets: RecentTargetStore(
            persistence: recentPersistence,
            isAvailable: { availableRecentIDs.contains($0.id) }
        ),
        systemActions: systemActions,
        scanService: scanService,
        scanArchiveService: scanArchiveService,
        usageStats: usageStats
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

private func makeSpaceKeyEvent(windowNumber: Int = 0) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: windowNumber,
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
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("Timed out waiting for \(description).")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@discardableResult
private func installSelection(
    on model: AppModel,
    selectNode: Bool = true,
    file inputFile: FileNodeRecord? = nil
) -> FileNodeRecord {
    let file = inputFile ?? makeTestFileNode(id: "/selection/file.txt", name: "file.txt")
    let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [file])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    let snapshot = makeTestSnapshot(root: root, store: store)
    model.scanState.replaceCurrentSnapshot(snapshot)
    model.navigation.reconcileAfterSnapshotApplied(snapshot)
    model.navigation.setFocusedNodeID(root.id)

    if selectNode {
        model.select(nodeID: file.id)
    }

    return file
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

private final class SpyAppUsageStatsStore: AppUsageStatsPersisting {
    private var stats: AppUsageStats
    var savedStats: [AppUsageStats] = []
    var didClear = false

    init(stats: AppUsageStats = .empty) {
        self.stats = stats
    }

    func loadUsageStats() -> AppUsageStats {
        stats
    }

    func saveUsageStats(_ stats: AppUsageStats) {
        self.stats = stats
        savedStats.append(stats)
    }

    func clearUsageStats() {
        stats = .empty
        didClear = true
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
    var revealedManyURLs: [[URL]] = []
    var copiedPathURLs: [URL] = []
    var copiedPathManyURLs: [[URL]] = []
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

private actor AsyncTrashActionProbe {
    private enum ProbeError: Error {
        case timeout
    }

    private var movedURLValues: [URL] = []
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    func move(_ url: URL) async {
        movedURLValues.append(url)
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
        guard !isFinished else { return }

        await withCheckedContinuation { continuation in
            finishContinuations.append(continuation)
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(1)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.waitUntilStarted()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProbeError.timeout
            }

            try await group.next()
            group.cancelAll()
        }
    }

    func finish() {
        isFinished = true
        let continuations = finishContinuations
        finishContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func movedURLs() -> [URL] {
        movedURLValues
    }

    private func waitUntilStarted() async {
        guard movedURLValues.isEmpty else { return }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }
}

private actor SpyScanArchiveService: ScanArchiveServicing {
    struct ExportRequest: Sendable {
        let snapshotID: UUID
        let destinationURL: URL
        let pathMode: ScanArchivePathMode
    }

    private(set) var exportRequests: [ExportRequest] = []
    private(set) var previewedURLs: [URL] = []
    private(set) var importedURLs: [URL] = []
    private let previewResult: ScanArchivePreview?
    private let importResult: ScanArchiveImportResult?
    private let exportWaitProbe: AsyncValueProbe<Void>?
    private let previewWaitProbe: AsyncValueProbe<Void>?
    private let importWaitProbe: AsyncValueProbe<Void>?
    private(set) var exportCancellationStates: [Bool] = []
    private(set) var previewCancellationStates: [Bool] = []
    private(set) var importCancellationStates: [Bool] = []

    init(
        previewResult: ScanArchivePreview? = nil,
        importResult: ScanArchiveImportResult? = nil,
        exportWaitProbe: AsyncValueProbe<Void>? = nil,
        previewWaitProbe: AsyncValueProbe<Void>? = nil,
        importWaitProbe: AsyncValueProbe<Void>? = nil
    ) {
        self.previewResult = previewResult
        self.importResult = importResult
        self.exportWaitProbe = exportWaitProbe
        self.previewWaitProbe = previewWaitProbe
        self.importWaitProbe = importWaitProbe
    }

    func export(
        snapshot: ScanSnapshot,
        to destinationURL: URL,
        options: ScanArchiveExportOptions
    ) async throws -> ScanArchiveExportResult {
        exportRequests.append(ExportRequest(
            snapshotID: snapshot.id,
            destinationURL: destinationURL,
            pathMode: options.pathMode
        ))
        if let exportWaitProbe {
            await exportWaitProbe.wait()
        }
        exportCancellationStates.append(Task.isCancelled)
        return ScanArchiveExportResult(archiveURL: destinationURL, nodeChecksum: "checksum")
    }

    func previewSnapshot(from sourceURL: URL) async throws -> ScanArchivePreview {
        previewedURLs.append(sourceURL)
        if let previewWaitProbe {
            await previewWaitProbe.wait()
        }
        previewCancellationStates.append(Task.isCancelled)
        guard let previewResult else {
            throw ScanArchiveError.invalidArchivePackage("missing spy preview result")
        }
        return previewResult
    }

    func importSnapshot(
        from sourceURL: URL,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> ScanArchiveImportResult {
        importedURLs.append(sourceURL)
        if let importWaitProbe {
            await importWaitProbe.wait()
        }
        importCancellationStates.append(Task.isCancelled)
        guard let importResult else {
            throw ScanArchiveError.invalidArchivePackage("missing spy import result")
        }
        return importResult
    }

    func exportRequestsSnapshot() -> [ExportRequest] {
        exportRequests
    }

    func previewedURLsSnapshot() -> [URL] {
        previewedURLs
    }

    func importedURLsSnapshot() -> [URL] {
        importedURLs
    }

    func exportCancellationStatesSnapshot() -> [Bool] {
        exportCancellationStates
    }

    func previewCancellationStatesSnapshot() -> [Bool] {
        previewCancellationStates
    }

    func importCancellationStatesSnapshot() -> [Bool] {
        importCancellationStates
    }
}
