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
