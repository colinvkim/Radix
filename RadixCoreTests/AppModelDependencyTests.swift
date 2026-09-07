import AppKit
import Combine
import XCTest
@testable import RadixCore

final class AppModelDependencyTests: XCTestCase {
    @MainActor
    func testOnboardingResumesAtAccessAndTourChoiceControlsTheWorkspaceHandoff() {
        let preferences = SpyAppPreferencesStore(
            preferences: AppPreferences(scan: .defaults, didCompleteOnboarding: false, onboardingPage: .access)
        )
        let model = AppModel(dependencies: makeDependencies(preferences: preferences))
        defer { model.cleanup() }
        XCTAssertTrue(model.showsOnboarding)
        XCTAssertEqual(model.onboardingPage, .access)

        model.onboardingPage = .tour
        XCTAssertEqual(preferences.preferences.onboardingPage, .tour)
        model.completeOnboarding(startsTour: false)
        XCTAssertTrue(preferences.preferences.didCompleteOnboarding)
        XCTAssertFalse(model.workspaceTour.isActive)

        model.presentOnboarding()
        XCTAssertEqual(model.onboardingPage, .welcome)
        model.completeOnboarding(startsTour: true)
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(model.workspaceTour.step, .scan)
        XCTAssertNil(model.scanState.snapshot)
        XCTAssertFalse(model.scanState.isScanning)
    }

    @MainActor
    func testTourObservesCommittedMarksAndPreservesPreexistingPileItems() async throws {
        let existing = makeTestFileNode(id: "/tour/existing.txt", name: "existing.txt", size: 20)
        let practice = makeTestFileNode(id: "/tour/practice.txt", name: "practice.txt", size: 10)
        let root = makeTestDirectoryNode(id: "/tour", name: "tour", children: [existing, practice])
        let snapshot = makeTestSnapshot(root: root, store: FileTreeStore(root: root, childrenByID: [root.id: [existing, practice]]))
        var trashCalls = 0
        var actions = AppSystemActions.inert
        actions.moveToTrash = { _ in
            trashCalls += 1
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        defer { model.cleanup() }
        model.dismissOnboarding()
        model.scanState.restoreCompletedSnapshot(snapshot)
        try await waitUntil("restored scan") { model.navigation.state.snapshotID == snapshot.id }
        XCTAssertTrue(model.addNodesToDiscardPile([existing]))

        model.workspaceTour.start(snapshotID: snapshot.id, isReady: true)
        for _ in 0..<6 { model.workspaceTour.advance() }
        XCTAssertEqual(model.workspaceTour.step, .markForReview)
        XCTAssertFalse(model.addNodeIDsToDiscardPile([practice.id], snapshotID: UUID()))
        XCTAssertEqual(model.workspaceTour.step, .markForReview)
        model.dismissErrorPresentation()
        XCTAssertTrue(model.addNodeIDsToDiscardPile([practice.id], snapshotID: snapshot.id))
        XCTAssertEqual(model.workspaceTour.step, .review)
        model.workspaceTour.reviewOpened()
        model.removeDiscardPileNodes(ids: [practice.id])

        XCTAssertEqual(Set(model.discardPile.nodeIDs), [existing.id])
        XCTAssertEqual(model.workspaceTour.step, .removeMark)
        XCTAssertNotNil(model.scanState.fileTreeStore?.node(id: practice.id))
        XCTAssertEqual(trashCalls, 0)
        model.workspaceTour.advance()
        XCTAssertEqual(model.workspaceTour.step, .finished)
        model.workspaceTour.stop()
        XCTAssertEqual(Set(model.discardPile.nodeIDs), [existing.id])
    }

    @MainActor
    func testProductionAndDefaultDependenciesUseIncrementalScanning() {
        let defaultDependencies = AppDependencies(
            preferences: SpyAppPreferencesStore(preferences: .defaults),
            recentTargets: RecentTargetStore(
                persistence: SpyRecentTargetPersistence(),
                isAvailable: { _ in true }
            ),
            systemActions: .inert
        )

        XCTAssertTrue(defaultDependencies.scanService is IncrementalScanService)
        XCTAssertTrue(AppDependencies.live.scanService is IncrementalScanService)
    }

    @MainActor
    func testInitializesFromInjectedPreferencesTargetsAndRecentStore() async throws {
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
                    showFreeSpaceInDiskMaps: true,
                    visualizationMode: .treemap,
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
        XCTAssertTrue(model.showFreeSpaceInDiskMaps)
        XCTAssertEqual(model.scanVisualizationMode, .treemap)
        XCTAssertTrue(model.useScanExclusions)
        XCTAssertEqual(model.exclusionPatterns, ["*.log"])
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertEqual(model.availableTargets, [defaultTarget])
        XCTAssertEqual(model.smartTargets, [defaultTarget])
        XCTAssertEqual(model.recentTargets, [availableRecent])
        try await waitUntil("full disk access becomes notGranted") {
            model.fullDiskAccessStatus == .notGranted
        }
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
            showFreeSpaceInDiskMaps: true,
            visualizationMode: .treemap,
            useScanExclusions: true,
            exclusionPatterns: ["node_modules"]
        )

        model.showHiddenFiles = false
        model.treatPackagesAsDirectories = true
        model.maxRenderedDepth = 10
        model.autoSummarizeDirectories = false
        model.showFreeSpaceInDiskMaps = true
        model.scanVisualizationMode = .treemap
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
    func testEmptyDiscardPileCanPresentReview() {
        let model = AppModel(dependencies: makeDependencies())
        model.dismissOnboarding()

        XCTAssertTrue(model.discardPile.isEmpty)

        model.presentDiscardPileReview()

        XCTAssertTrue(model.showsDiscardPileReview)
        XCTAssertEqual(model.presentationCoordinator.activeSheet, .discardPileReview)
    }

    @MainActor
    func testVisualizationModeUpdatePublishesAfterViewUpdate() async throws {
        let model = AppModel(dependencies: makeDependencies())
        var publicationCount = 0
        let cancellable = model.objectWillChange.sink {
            publicationCount += 1
        }

        model.setScanVisualizationModeAfterViewUpdate(.treemap)

        XCTAssertEqual(model.scanVisualizationMode, .sunburst)
        XCTAssertEqual(publicationCount, 0)

        try await waitUntil("deferred visualization mode") {
            model.scanVisualizationMode == .treemap
        }
        XCTAssertGreaterThanOrEqual(publicationCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testVisualizationModeUpdateCoalescesToLatestRequest() async throws {
        let model = AppModel(dependencies: makeDependencies())

        model.setScanVisualizationModeAfterViewUpdate(.treemap)
        model.setScanVisualizationModeAfterViewUpdate(.sunburst)

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.scanVisualizationMode, .sunburst)
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
            showFreeSpaceInDiskMaps: AppScanPreferences.defaults.showFreeSpaceInDiskMaps,
            visualizationMode: AppScanPreferences.defaults.visualizationMode,
            useScanExclusions: AppScanPreferences.defaults.useScanExclusions,
            exclusionPatterns: AppScanPreferences.defaults.exclusionPatterns
        )

        model.showHiddenFiles = false
        model.cleanup()

        XCTAssertEqual(preferences.savedScanPreferences, [expectedPreferences])
    }

    @MainActor
    func testCachedFreeSpaceCapacityRequiresEnabledActiveVolumeRootAndDoesNotRequery() async throws {
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

        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot))

        model.scanState.replaceCurrentSnapshot(volumeSnapshot)
        model.showFreeSpaceInDiskMaps = true
        try await waitUntil("free-space capacity fallback applies") {
            model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot) == 123
        }

        XCTAssertEqual(model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot), 123)
        XCTAssertEqual(model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot), 123)
        XCTAssertEqual(model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: volumeRoot), 123)
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: volumeSnapshot, focusNode: child))

        let folderSnapshot = makeTestSnapshot(root: volumeRoot, store: store)
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: folderSnapshot, focusNode: volumeRoot))
        XCTAssertEqual(requestedURLs, [volumeRoot.url])
    }

    @MainActor
    func testCapturedFreeSpaceCapacityAvoidsLiveRequery() async throws {
        var requestedURLs: [URL] = []
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            requestedURLs.append(url)
            return 999
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [])
        let store = FileTreeStore(root: root)
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            isComplete: true,
            volumeCapacity: VolumeCapacitySnapshot(totalCapacity: 1_000, availableCapacity: 321)
        )

        model.scanState.replaceCurrentSnapshot(snapshot)
        model.showFreeSpaceInDiskMaps = true

        XCTAssertEqual(model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root), 321)
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    @MainActor
    func testOverlappingVolumeAllocationsSuppressFreeSpaceComposition() {
        var requestedURLs: [URL] = []
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            requestedURLs.append(url)
            return 1
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = makeTestFileNode(
            id: "/volume/clone.bin",
            name: "clone.bin",
            size: 200 * 1_024 * 1_024
        )
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            isComplete: true,
            volumeCapacity: VolumeCapacitySnapshot(
                totalCapacity: 500 * 1_024 * 1_024,
                availableCapacity: 400 * 1_024 * 1_024
            )
        )

        model.scanState.replaceCurrentSnapshot(snapshot)
        model.showFreeSpaceInDiskMaps = true

        XCTAssertEqual(snapshot.overlappingAllocatedBytes, 100 * 1_024 * 1_024)
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root))
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    @MainActor
    func testAsyncFreeSpaceCapacityLoadDoesNotBlockMainActor() async throws {
        let probe = ControlledCapacityLoader()
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            await probe.load(url)
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: FileTreeStore(root: root)
        )

        model.scanState.replaceCurrentSnapshot(snapshot)
        model.showFreeSpaceInDiskMaps = true
        try await probe.waitForIssuedRequestCount(1)

        model.showHiddenFiles = false
        XCTAssertFalse(model.showHiddenFiles)
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root))

        let didCompleteRequest = await probe.completeRequest(id: 0, with: 456)
        XCTAssertTrue(didCompleteRequest)
        try await waitUntil("async free-space capacity applies") {
            model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root) == 456
        }
    }

    @MainActor
    func testStaleFreeSpaceCapacityResultCannotOverwriteNewSnapshot() async throws {
        let probe = ControlledCapacityLoader()
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            await probe.load(url)
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let firstRoot = makeTestDirectoryNode(id: "/first", name: "First", children: [])
        let firstSnapshot = makeTestSnapshot(
            target: ScanTarget(url: firstRoot.url, kind: .volume),
            root: firstRoot,
            store: FileTreeStore(root: firstRoot)
        )
        let secondRoot = makeTestDirectoryNode(id: "/second", name: "Second", children: [])
        let secondSnapshot = makeTestSnapshot(
            target: ScanTarget(url: secondRoot.url, kind: .volume),
            root: secondRoot,
            store: FileTreeStore(root: secondRoot)
        )

        model.showFreeSpaceInDiskMaps = true
        model.scanState.replaceCurrentSnapshot(firstSnapshot)
        try await probe.waitForIssuedRequestCount(1)
        model.scanState.replaceCurrentSnapshot(secondSnapshot)
        try await probe.waitForIssuedRequestCount(2)

        let didCompleteCurrentRequest = await probe.completeRequest(id: 1, with: 222)
        XCTAssertTrue(didCompleteCurrentRequest)
        try await waitUntil("current free-space capacity applies") {
            model.cachedFreeSpaceAvailableCapacity(for: secondSnapshot, focusNode: secondRoot) == 222
        }
        let didCompleteStaleRequest = await probe.completeRequest(id: 0, with: 111)
        XCTAssertTrue(didCompleteStaleRequest)
        await Task.yield()

        XCTAssertEqual(model.cachedFreeSpaceAvailableCapacity(for: secondSnapshot, focusNode: secondRoot), 222)
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: firstSnapshot, focusNode: firstRoot))
    }

    @MainActor
    func testCleanupCancelsFreeSpaceCapacityLoadAndClearsCache() async throws {
        let probe = ControlledCapacityLoader()
        var actions = AppSystemActions.inert
        actions.volumeAvailableCapacityForImportantUsage = { url in
            await probe.load(url)
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: FileTreeStore(root: root)
        )

        model.showFreeSpaceInDiskMaps = true
        model.scanState.replaceCurrentSnapshot(snapshot)
        try await probe.waitForIssuedRequestCount(1)
        model.cleanup()
        try await probe.waitForCancelledRequest(id: 0)

        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root))
        let didCompleteCancelledRequest = await probe.completeRequest(id: 0, with: 999)
        XCTAssertTrue(didCompleteCancelledRequest)
        await Task.yield()
        XCTAssertNil(model.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: root))
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
    func testSelectedFileActionsUseInjectedSystemActions() async {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.open = { recorder.openedURLs.append($0) }
        actions.openInTerminal = { recorder.terminalDirectoryURLs.append($0) }
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
        await model.openSelectedInTerminal()
        model.copySelectedPath()
        model.previewSelectedWithQuickLook()
        model.toggleQuickLookForSelected()

        XCTAssertEqual(recorder.revealedURLs, [file.url])
        XCTAssertEqual(recorder.openedURLs, [file.url])
        XCTAssertEqual(recorder.terminalDirectoryURLs, [file.url.deletingLastPathComponent()])
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
    func testConfirmPendingTrashUsesInjectedFileActionsAndRefreshesTargets() async throws {
        let recorder = AppModelActionRecorder()
        let refreshedTarget = makeTestTarget("/refreshed")
        recorder.defaultTargets = [refreshedTarget]
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        actions.defaultTargets = {
            recorder.defaultTargetsCallCount += 1
            return recorder.defaultTargets
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [file.url])
        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertEqual(model.availableTargets, [refreshedTarget])
        XCTAssertEqual(recorder.defaultTargetsCallCount, 2)
    }

    @MainActor
    func testConfirmPendingTrashUsesAsyncTrashActionWithoutBlockingDismissal() async throws {
        let probe = AsyncTrashActionProbe()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { node in
            await probe.move(node.url)
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        model.scanState.selectedTarget = ScanTarget(url: URL(filePath: "/selection", directoryHint: .isDirectory))

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()

        XCTAssertNil(model.pendingTrashSelection)

        try await probe.waitUntilStarted()
        let movedURLs = await probe.movedURLs()
        XCTAssertEqual(movedURLs, [file.url])
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: file.id))
        XCTAssertEqual(model.movingToTrashRootNodeIDs, [file.id])
        XCTAssertTrue(model.discardPileRootNodeIDs.isEmpty)
        XCTAssertTrue(model.workspaceHiddenNodeIDs.contains(file.id))

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
    func testAsyncTrashFailureRestoresOptimisticallyHiddenNode() async throws {
        let probe = AsyncTrashActionProbe()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { node in
            await probe.move(node.url)
            throw NSError(domain: "RadixTrashTest", code: 1)
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        model.scanState.selectedTarget = ScanTarget(url: URL(filePath: "/selection", directoryHint: .isDirectory))

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()

        try await probe.waitUntilStarted()
        XCTAssertEqual(model.movingToTrashRootNodeIDs, [file.id])
        XCTAssertTrue(model.workspaceHiddenNodeIDs.contains(file.id))

        await probe.finish()

        try await waitUntil("async trash failure reported", timeout: 2) {
            model.lastErrorMessage != nil
        }
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: file.id))
        XCTAssertFalse(model.workspaceHiddenNodeIDs.contains(file.id))
        XCTAssertTrue(model.movingToTrashRootNodeIDs.isEmpty)
    }

    @MainActor
    func testOptimisticTrashVisibilityMutationsPublishThroughAppModel() {
        let model = AppModel(dependencies: makeDependencies())
        let snapshotID = UUID()
        var publicationCount = 0
        let cancellable = model.objectWillChange.sink {
            publicationCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertTrue(model.trashFlow.replaceOptimisticTrashVisibility(
            nodeIDs: ["/selection/file.txt"],
            snapshotID: snapshotID
        ))
        XCTAssertEqual(publicationCount, 1)

        XCTAssertFalse(model.trashFlow.replaceOptimisticTrashVisibility(
            nodeIDs: ["/selection/file.txt"],
            snapshotID: snapshotID
        ))
        XCTAssertEqual(publicationCount, 1)

        XCTAssertTrue(model.trashFlow.clearOptimisticTrashVisibility())
        XCTAssertEqual(publicationCount, 2)
    }

    @MainActor
    func testCancellationStopsTrashBatchAfterUninterruptibleMove() async throws {
        let probe = AsyncTrashActionProbe()
        var movedIDs: [String] = []
        var actions = AppSystemActions.inert
        actions.moveToTrash = { node in
            movedIDs.append(node.id)
            await probe.move(node.url)
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.bin", name: "first.bin", size: 40)
        let second = makeTestFileNode(id: "/selection/second.bin", name: "second.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [first, second])

        model.confirmMovePendingSelectionToTrash()
        try await probe.waitUntilStarted()
        model.suspendMainWindowActivity()
        await probe.finish()

        try await waitUntil("completed move reconciled after cancellation") {
            model.scanState.snapshot?.treeStore.node(id: first.id) == nil
        }
        XCTAssertEqual(movedIDs, [first.id])
        XCTAssertEqual(model.usageStats.bytesMovedToTrash, first.allocatedSize)
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: second.id))
        XCTAssertFalse(model.workspaceHiddenNodeIDs.contains(second.id))
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testAsyncDiscardPileTrashDoesNotRemoveNewSnapshotListEntry() async throws {
        let probe = AsyncTrashActionProbe()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { node in
            await probe.move(node.url)
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        let oldFile = makeTestFileNode(id: "/selection/file.txt", name: "file.txt", size: 40)
        let oldRoot = makeTestDirectoryNode(id: "/selection", name: "selection", children: [oldFile])
        let oldStore = FileTreeStore(root: oldRoot, childrenByID: [oldRoot.id: [oldFile]])
        let oldSnapshot = makeTestSnapshot(root: oldRoot, store: oldStore)
        model.scanState.replaceCurrentSnapshot(oldSnapshot)
        model.navigation.reconcileAfterSnapshotApplied(oldSnapshot)
        model.addNodesToDiscardPile([oldFile])
        XCTAssertTrue(model.requestMoveDiscardPileToTrash())
        model.confirmMovePendingSelectionToTrash()
        try await probe.waitUntilStarted()

        let newFile = makeTestFileNode(id: oldFile.id, name: oldFile.name, size: 80)
        let newRoot = makeTestDirectoryNode(id: "/selection", name: "selection", children: [newFile])
        let newStore = FileTreeStore(root: newRoot, childrenByID: [newRoot.id: [newFile]])
        let newSnapshot = makeTestSnapshot(root: newRoot, store: newStore)
        model.scanState.replaceCurrentSnapshot(newSnapshot)
        model.navigation.reconcileAfterSnapshotApplied(newSnapshot)
        model.addNodesToDiscardPile([newFile])

        await probe.finish()

        try await waitUntil("old async trash completion recorded", timeout: 2) {
            model.usageStats.bytesMovedToTrash == oldFile.allocatedSize
        }
        XCTAssertEqual(model.discardPile.snapshotID, newSnapshot.id)
        XCTAssertEqual(model.discardPile.nodeIDs, [newFile.id])
        XCTAssertEqual(model.discardPileSnapshot.summary.totalAllocatedSize, newFile.allocatedSize)
    }

    @MainActor
    func testSuspendingMainWindowCancelsInFlightAsyncDiscardPileTrashMove() async throws {
        let probe = AsyncTrashActionProbe()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { node in
            if node.name == "second.bin" {
                await probe.move(node.url)
                try Task.checkCancellation()
            }
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        let first = makeTestFileNode(id: "/selection/first.bin", name: "first.bin", size: 40)
        let second = makeTestFileNode(id: "/selection/second.bin", name: "second.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.addNodesToDiscardPile([first, second])
        XCTAssertTrue(model.requestMoveDiscardPileToTrash())
        model.confirmMovePendingSelectionToTrash()

        try await probe.waitUntilStarted()
        let startedURLs = await probe.movedURLs()
        XCTAssertEqual(startedURLs, [second.url])
        XCTAssertTrue(model.workspaceHiddenNodeIDs.contains(first.id))
        XCTAssertTrue(model.workspaceHiddenNodeIDs.contains(second.id))
        XCTAssertEqual(model.movingToTrashRootNodeIDs, [first.id, second.id])
        XCTAssertEqual(model.discardPileRootNodeIDs, [first.id, second.id])

        model.suspendMainWindowActivity()
        await probe.finish()

        try await waitUntil("cancelled trash move reconciled", timeout: 2) {
            model.usageStats.bytesMovedToTrash == first.allocatedSize
        }
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertEqual(model.discardPile.nodeIDs, [second.id])
    }

    @MainActor
    func testConfirmPendingTrashRecordsTrashUsageStats() async throws {
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
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            usageStats: usageStats
        ))
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [folder])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [folder.url])
        XCTAssertEqual(model.usageStats.filesDeleted, 2)
        XCTAssertEqual(model.usageStats.foldersDeleted, 1)
        XCTAssertEqual(model.usageStats.bytesMovedToTrash, 100)
        XCTAssertEqual(model.usageStats.largestTrashMoveBytes, 100)
        XCTAssertEqual(usageStats.savedStats.last?.filesDeleted, 2)
        XCTAssertEqual(usageStats.savedStats.last?.foldersDeleted, 1)
    }

    @MainActor
    func testConfirmPendingTrashAllowsMatchingIdentity() async throws {
        let recorder = AppModelActionRecorder()
        let identity = FileIdentity(device: 12, inode: 34)
        let file = makeTestFileNode(
            id: "/selection/file.txt",
            name: "file.txt",
            fileIdentity: identity
        )
        var verifiedNodeIDs: [String] = []
        var actions = AppSystemActions.inert
        actions.moveToTrash = { node in
            verifiedNodeIDs.append(node.id)
            recorder.movedToTrashURLs.append(node.url)
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(verifiedNodeIDs, [file.id])
        XCTAssertEqual(recorder.movedToTrashURLs, [file.url])
        XCTAssertNil(model.lastErrorMessage)
    }

    @MainActor
    func testConfirmPendingTrashBlocksMismatchedIdentity() async throws {
        let recorder = AppModelActionRecorder()
        let file = makeTestFileNode(
            id: "/selection/replaced.txt",
            name: "replaced.txt",
            fileIdentity: FileIdentity(device: 1, inode: 2)
        )
        var actions = AppSystemActions.inert
        actions.moveToTrash = { _ in .mismatch }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(
            model.lastErrorMessage,
            "The item at \(file.url.path) changed since this scan. Rescan before moving it to Trash."
        )
    }

    @MainActor
    func testConfirmPendingTrashBlocksMissingScannedIdentity() async throws {
        let recorder = AppModelActionRecorder()
        let file = makeTestFileNode(id: "/selection/unverified.txt", name: "unverified.txt")
        var actions = AppSystemActions.inert
        actions.moveToTrash = { _ in .missingScannedIdentity }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        installSelection(on: model, file: file)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [file])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(
            model.lastErrorMessage,
            "Radix could not verify the scanned identity for \(file.url.path). Rescan before moving it to Trash."
        )
    }

    @MainActor
    func testConfirmPendingTrashBatchReconcilesMovedPrefixAfterLaterFailure() async throws {
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
        actions.moveToTrash = { node in
            verifiedNodeIDs.append(node.id)
            guard node.id != second.id else { return .mismatch }
            recorder.movedToTrashURLs.append(node.url)
            return .matches
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [first, second])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(verifiedNodeIDs, [first.id, second.id])
        XCTAssertEqual(recorder.movedToTrashURLs, [first.url])
        XCTAssertEqual(
            model.lastErrorMessage,
            "The item at \(second.url.path) changed since this scan. Rescan before moving it to Trash."
        )
        try await waitUntil("partially successful trash batch reconciled", timeout: 2) {
            model.scanState.snapshot?.treeStore.node(id: first.id) == nil
        }
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: second.id))
        XCTAssertFalse(model.workspaceHiddenNodeIDs.contains(second.id))
    }

    @MainActor
    func testRequestMoveSelectedToTrashRejectsProtectedRoots() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
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

        XCTAssertNil(model.pendingTrashSelection)
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
    }

    @MainActor
    func testAddingResidentCloudFileToDiscardPileRequiresConfirmation() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let cloudFile = makeTestFileNode(
            id: "/Users/alex/Library/CloudStorage/Dropbox/file.bin",
            name: "file.bin"
        )
        let root = makeTestDirectoryNode(
            id: "/Users/alex/Library/CloudStorage/Dropbox",
            name: "Dropbox",
            children: [cloudFile]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [cloudFile]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.addNodesToDiscardPile([cloudFile]))

        XCTAssertTrue(model.discardPile.isEmpty)
        XCTAssertEqual(model.pendingCloudFileAction?.kind, .addToDiscardPile)
        XCTAssertEqual(model.pendingCloudFileAction?.nodes.map(\.id), [cloudFile.id])
        XCTAssertEqual(model.pendingCloudFileAction?.cloudImpact, .storedInCloud)

        model.confirmPendingCloudFileAction()

        XCTAssertEqual(model.discardPile.nodeIDs, [cloudFile.id])
        XCTAssertNil(model.pendingCloudFileAction)
    }

    @MainActor
    func testMovingResidentCloudFileToTrashRequiresSecondConfirmation() async throws {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let cloudFile = makeTestFileNode(
            id: "/Users/alex/Library/CloudStorage/Dropbox/file.bin",
            name: "file.bin"
        )
        let root = makeTestDirectoryNode(
            id: "/Users/alex/Library/CloudStorage/Dropbox",
            name: "Dropbox",
            children: [cloudFile]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [cloudFile]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.requestMoveNodesToTrash([cloudFile]))

        model.confirmMovePendingSelectionToTrash()

        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertEqual(
            model.pendingCloudFileAction?.kind,
            .moveToTrash(allowsHiddenNodes: false)
        )
        XCTAssertEqual(model.pendingCloudFileAction?.cloudImpact, .storedInCloud)

        model.confirmPendingCloudFileAction()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [cloudFile.url])
        XCTAssertNil(model.pendingCloudFileAction)
    }

    @MainActor
    func testMovingVisibleNodeToTrashDoesNotMoveDiscardPileNodes() async throws {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/queued.txt", name: "queued.txt", size: 40)
        let visible = makeTestFileNode(id: "/selection/visible.txt", name: "visible.txt", size: 80)
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [queued, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [queued, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.addNodesToDiscardPile([queued]))
        XCTAssertTrue(model.requestMoveNodesToTrash([visible]))
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [visible.url])
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
        try await waitUntil("visible node removed from snapshot", timeout: 2) {
            model.scanState.snapshot?.treeStore.node(id: visible.id) == nil
        }
        XCTAssertNotNil(model.scanState.snapshot?.treeStore.node(id: queued.id))
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
        XCTAssertEqual(model.discardPile.snapshotID, snapshot.id)
    }

    @MainActor
    func testPrimaryTrashDoesNotClearUnrelatedDiscardPileNodes() async throws {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let firstQueued = makeTestFileNode(id: "/selection/firstQueued.txt", name: "firstQueued.txt", size: 40)
        let secondQueued = makeTestFileNode(id: "/selection/secondQueued.txt", name: "secondQueued.txt", size: 60)
        let visible = makeTestFileNode(id: "/selection/visible.txt", name: "visible.txt", size: 80)
        let root = makeTestDirectoryNode(
            id: "/selection",
            name: "selection",
            children: [firstQueued, secondQueued, visible]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [firstQueued, secondQueued, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.addNodesToDiscardPile([firstQueued, secondQueued]))
        model.select(nodeID: visible.id)
        model.requestMovePrimarySelectionToTrash()
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [visible.url])

        try await waitUntil("visible node removed from snapshot", timeout: 2) {
            model.scanState.snapshot?.treeStore.node(id: visible.id) == nil
        }
        XCTAssertEqual(model.discardPile.nodeIDs, [firstQueued.id, secondQueued.id])
        XCTAssertEqual(model.discardPile.snapshotID, snapshot.id)
    }

    @MainActor
    func testContextTrashRejectsAncestorOfDiscardPileNode() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/folder/queued.txt", name: "queued.txt", size: 40)
        let sibling = makeTestFileNode(id: "/selection/folder/sibling.txt", name: "sibling.txt", size: 80)
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [queued, sibling])
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [queued, sibling]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.addNodesToDiscardPile([queued]))
        XCTAssertFalse(model.requestMoveNodesToTrash([folder]))

        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testPrimaryTrashRejectsAncestorOfDiscardPileNode() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/folder/queued.txt", name: "queued.txt", size: 40)
        let sibling = makeTestFileNode(id: "/selection/folder/sibling.txt", name: "sibling.txt", size: 80)
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [queued, sibling])
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [queued, sibling]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.addNodesToDiscardPile([queued]))
        model.select(nodeID: folder.id)
        model.requestMovePrimarySelectionToTrash()

        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testPendingTrashRejectsNewDiscardPileDescendantBeforeConfirm() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/folder/queued.txt", name: "queued.txt", size: 40)
        let sibling = makeTestFileNode(id: "/selection/folder/sibling.txt", name: "sibling.txt", size: 80)
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [queued, sibling])
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [queued, sibling]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        XCTAssertTrue(model.requestMoveNodesToTrash([folder]))
        XCTAssertTrue(model.addNodesToDiscardPile([queued]))
        model.confirmMovePendingSelectionToTrash()

        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testPrimaryTrashRejectsStaleDiscardPileSelection() {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/queued.txt", name: "queued.txt", size: 40)
        let visible = makeTestFileNode(id: "/selection/visible.txt", name: "visible.txt", size: 80)
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [queued, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [queued, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        XCTAssertTrue(model.addNodesToDiscardPile([queued]))

        model.navigation.select(nodeID: queued.id)
        model.requestMovePrimarySelectionToTrash()

        XCTAssertNil(model.pendingTrashSelection)
        XCTAssertEqual(model.navigation.selectedNodeIDs, [queued.id])
        XCTAssertTrue(recorder.movedToTrashURLs.isEmpty)
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
    }

    @MainActor
    func testSelectedTrashFiltersStaleDiscardPileSelection() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestFileNode(id: "/selection/queued.txt", name: "queued.txt", size: 40)
        let visible = makeTestFileNode(id: "/selection/visible.txt", name: "visible.txt", size: 80)
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [queued, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [queued, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.scanState.selectedTarget = snapshot.target
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        XCTAssertTrue(model.addNodesToDiscardPile([queued]))

        model.navigation.select(nodeIDs: [queued.id, visible.id], primaryNodeID: visible.id)
        model.requestMoveSelectedToTrash()

        XCTAssertEqual(model.pendingTrashSelection?.nodes.map(\.id), [visible.id])
        XCTAssertEqual(model.discardPile.nodeIDs, [queued.id])
    }

    @MainActor
    func testDiscardPileAddsValidNode() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        let didAdd = model.addNodesToDiscardPile([file])

        XCTAssertTrue(didAdd)
        XCTAssertEqual(model.discardPile.nodeIDs, [file.id])
        XCTAssertEqual(model.discardPileSnapshot.nodes.map(\.id), [file.id])
        XCTAssertEqual(model.discardPileSnapshot.summary.itemCount, 1)
        XCTAssertEqual(model.discardPileSnapshot.summary.totalAllocatedSize, file.allocatedSize)
    }

    @MainActor
    func testDiscardPileBulkRemovalPublishesOnceAndPreservesRemainingOrder() {
        let model = AppModel(dependencies: makeDependencies())
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let third = makeTestFileNode(id: "/selection/third.txt", name: "third.txt")
        let root = makeTestDirectoryNode(
            id: "/selection",
            name: "selection",
            children: [first, second, third]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second, third]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        XCTAssertTrue(model.addNodesToDiscardPile([first, second, third]))

        var publicationCount = 0
        let cancellable = model.trashFlow.$discardPile.dropFirst().sink { _ in
            publicationCount += 1
        }
        defer { cancellable.cancel() }

        model.removeDiscardPileNodes(ids: [first.id, third.id])

        XCTAssertEqual(model.discardPile.nodeIDs, [second.id])
        XCTAssertEqual(model.discardPile.snapshotID, snapshot.id)
        XCTAssertEqual(publicationCount, 1)
    }

    @MainActor
    func testPrimaryDiscardPileAddAfterViewUpdateDefersMutation() async throws {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.addPrimarySelectionToDiscardPileAfterViewUpdate()

        XCTAssertTrue(model.discardPile.isEmpty)
        XCTAssertEqual(model.navigation.selectedNodeID, file.id)

        try await waitUntil("deferred discard pile add") {
            model.discardPile.nodeIDs == [file.id] &&
                model.navigation.selectedNodeID == file.id
        }
    }

    @MainActor
    func testDiscardPileAddDefersLivePathValidationUntilTrashRequest() {
        var fileExistsCallCount = 0
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in
            fileExistsCallCount += 1
            return false
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        let didAdd = model.addNodesToDiscardPile([file])

        XCTAssertTrue(didAdd)
        XCTAssertEqual(model.discardPile.nodeIDs, [file.id])
        XCTAssertEqual(fileExistsCallCount, 0)

        let didRequestTrash = model.requestMoveDiscardPileToTrash()

        XCTAssertFalse(didRequestTrash)
        XCTAssertEqual(fileExistsCallCount, 1)
        XCTAssertEqual(model.discardPile.nodeIDs, [file.id])
    }

    @MainActor
    func testDiscardPileAddsResolvedNodeIDs() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        let didAdd = model.addNodeIDsToDiscardPile([first.id, second.id], snapshotID: snapshot.id)

        XCTAssertTrue(didAdd)
        XCTAssertEqual(model.discardPile.nodeIDs, [first.id, second.id])
    }

    @MainActor
    func testDiscardPileAddsLargeSiblingBatch() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let files = (0..<1_000).map { index in
            makeTestFileNode(
                id: "/selection/file-\(index).bin",
                name: "file-\(index).bin",
                size: Int64(index + 1)
            )
        }
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: files)
        let store = FileTreeStore(root: root, childrenByID: [root.id: files])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        let didAdd = model.addNodeIDsToDiscardPile(files.map(\.id), snapshotID: snapshot.id)

        XCTAssertTrue(didAdd)
        XCTAssertEqual(model.discardPile.nodeIDs.count, files.count)
        XCTAssertEqual(Set(model.discardPile.nodeIDs), Set(files.map(\.id)))
    }

    @MainActor
    func testDiscardPileRejectsUnresolvedDroppedNodeIDBatch() throws {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        let snapshotID = model.scanState.snapshot?.id

        let didAdd = model.addNodeIDsToDiscardPile(
            [file.id, "/selection/missing.txt"],
            snapshotID: try XCTUnwrap(snapshotID)
        )

        XCTAssertFalse(didAdd)
        XCTAssertTrue(model.discardPile.isEmpty)
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testDiscardPileRejectsNodeIDsFromDifferentSnapshot() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        let didAdd = model.addNodeIDsToDiscardPile([file.id], snapshotID: UUID())

        XCTAssertFalse(didAdd)
        XCTAssertTrue(model.discardPile.isEmpty)
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testDiscardPileRejectsUnsupportedNode() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let syntheticNode = FileNodeRecord(
            id: "/selection/system-data",
            url: URL(filePath: "/selection/system-data"),
            name: "System Data",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 10,
            logicalSize: 10,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [syntheticNode])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [syntheticNode]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        let didAdd = model.addNodesToDiscardPile([syntheticNode])

        XCTAssertFalse(didAdd)
        XCTAssertTrue(model.discardPile.isEmpty)
        XCTAssertEqual(model.lastErrorMessage, "This item does not support that action.")
    }

    @MainActor
    func testDiscardPileParentDedupRemovesQueuedChildren() {
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

        model.addNodesToDiscardPile([child])
        model.addNodesToDiscardPile([folder])

        XCTAssertEqual(model.discardPile.nodeIDs, [folder.id])
    }

    @MainActor
    func testDiscardPileChildAddNoOpsWhenAncestorQueued() {
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

        model.addNodesToDiscardPile([folder])
        model.addNodesToDiscardPile([child])

        XCTAssertEqual(model.discardPile.nodeIDs, [folder.id])
    }

    @MainActor
    func testWorkspaceHiddenNodeIDsTrackCurrentSnapshot() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)

        model.addNodesToDiscardPile([file])

        XCTAssertEqual(model.workspaceHiddenNodeIDs, [file.id])

        let nextFile = makeTestFileNode(id: "/next/file.txt", name: "file.txt")
        let nextRoot = makeTestDirectoryNode(id: "/next", name: "next", children: [nextFile])
        let nextStore = FileTreeStore(root: nextRoot, childrenByID: [nextRoot.id: [nextFile]])
        model.scanState.replaceCurrentSnapshot(makeTestSnapshot(root: nextRoot, store: nextStore))

        XCTAssertTrue(model.workspaceHiddenNodeIDs.isEmpty)
    }

    @MainActor
    func testDiscardPileAddPreservesSelectionForInspection() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        XCTAssertEqual(model.navigation.selectedNodeID, file.id)

        model.addNodesToDiscardPile([file])

        XCTAssertEqual(model.navigation.selectedNodeID, file.id)
        XCTAssertEqual(model.navigation.selectedNodeIDs, [file.id])
    }

    @MainActor
    func testDiscardPileAddClearsQueuedMultiSelection() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let root = makeTestDirectoryNode(
            id: "/selection",
            name: "selection",
            children: [first, second]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.select(nodeIDs: [first.id, second.id], primaryNodeID: first.id)

        model.addSelectedNodesToDiscardPile()

        XCTAssertTrue(model.navigation.selectedNodeIDs.isEmpty)
        XCTAssertNil(model.navigation.selectedNodeID)
    }

    @MainActor
    func testDiscardPileNodeCanBeSelectedButNotFocused() throws {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.reveal = { recorder.revealedURLs.append($0) }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let file = installSelection(on: model)
        let rootID = try XCTUnwrap(model.scanState.snapshot?.root.id)

        model.addNodesToDiscardPile([file])
        model.clearSelection()
        model.select(nodeID: file.id)
        model.focus(nodeID: file.id)
        model.revealPrimarySelectionInFinder()

        XCTAssertEqual(model.navigation.selectedNodeID, file.id)
        XCTAssertEqual(model.navigation.focusedNodeID, rootID)
        XCTAssertFalse(model.canZoomIntoSelection)
        XCTAssertTrue(model.selectionIncludesHiddenNodes)
        XCTAssertEqual(recorder.revealedURLs, [file.url])
    }

    @MainActor
    func testDiscardPileAddMovesHiddenFocusToVisibleAncestor() {
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
        model.focus(nodeID: folder.id)
        model.select(nodeID: child.id)

        model.addNodesToDiscardPile([folder])

        XCTAssertEqual(model.navigation.focusedNodeID, root.id)
        XCTAssertEqual(model.navigation.selectedNodeID, child.id)
        XCTAssertEqual(model.navigation.selectedNodeIDs, [child.id])
        XCTAssertFalse(model.navigation.canNavigateBack)
    }

    @MainActor
    func testDiscardPileAddPrunesQueuedFolderFromBackHistory() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let queued = makeTestDirectoryNode(
            id: "/selection/queued",
            name: "queued",
            children: []
        )
        let visible = makeTestDirectoryNode(
            id: "/selection/visible",
            name: "visible",
            children: []
        )
        let root = makeTestDirectoryNode(
            id: "/selection",
            name: "selection",
            children: [queued, visible]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [queued, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.focus(nodeID: queued.id)
        model.focus(nodeID: visible.id)

        model.addNodesToDiscardPile([queued])
        model.navigateBack()

        XCTAssertEqual(model.navigation.focusedNodeID, root.id)
        XCTAssertFalse(model.navigation.canNavigateBack)
        XCTAssertTrue(model.navigation.canNavigateForward)
    }

    @MainActor
    func testDiscardPileAddPrunesQueuedDescendantFromForwardHistory() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let descendant = makeTestDirectoryNode(
            id: "/selection/queued/descendant",
            name: "descendant",
            children: []
        )
        let queued = makeTestDirectoryNode(
            id: "/selection/queued",
            name: "queued",
            children: [descendant]
        )
        let root = makeTestDirectoryNode(
            id: "/selection",
            name: "selection",
            children: [queued]
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [queued],
            queued.id: [descendant],
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.focus(nodeID: descendant.id)
        model.navigateBack()

        model.addNodesToDiscardPile([queued])

        XCTAssertEqual(model.navigation.focusedNodeID, root.id)
        XCTAssertFalse(model.navigation.canNavigateForward)
        model.navigateForward()
        XCTAssertEqual(model.navigation.focusedNodeID, root.id)
    }

    @MainActor
    func testDiscardPilePublishesAfterHiddenFocusReconciles() {
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
        model.navigation.setFocusedNodeID(folder.id)
        model.select(nodeID: folder.id)

        var observedFocusID: FileNodeRecord.ID?
        let cancellable = model.trashFlow.$discardPile.dropFirst().sink { _ in
            observedFocusID = model.navigation.focusedNodeID
        }
        defer { cancellable.cancel() }

        model.addNodesToDiscardPile([folder])

        XCTAssertEqual(observedFocusID, root.id)
    }

    @MainActor
    func testDeferredDiscardPileAddMovesFocusedSelectionToVisibleAncestor() async throws {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let child = makeTestFileNode(id: "/selection/folder/child.txt", name: "child.txt")
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [child])
        let sibling = makeTestFileNode(id: "/selection/sibling.txt", name: "sibling.txt")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [child]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.navigation.setFocusedNodeID(folder.id)
        model.select(nodeID: folder.id)

        model.addPrimarySelectionToDiscardPileAfterViewUpdate()

        try await waitUntil("deferred focused discard pile add") {
            model.discardPile.nodeIDs == [folder.id] &&
                model.navigation.focusedNodeID == root.id &&
                model.navigation.selectedNodeID == folder.id
        }
    }

    @MainActor
    func testDiscardPileClearsWhenActiveSnapshotIsReplaced() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let firstFile = makeTestFileNode(id: "/first/file.txt", name: "file.txt")
        let firstRoot = makeTestDirectoryNode(id: "/first", name: "first", children: [firstFile])
        let firstStore = FileTreeStore(root: firstRoot, childrenByID: [firstRoot.id: [firstFile]])
        let firstSnapshot = makeTestSnapshot(root: firstRoot, store: firstStore)
        model.scanState.replaceCurrentSnapshot(firstSnapshot)
        model.navigation.reconcileAfterSnapshotApplied(firstSnapshot)
        model.addNodesToDiscardPile([firstFile])

        let secondFile = makeTestFileNode(id: "/second/file.txt", name: "file.txt")
        let secondRoot = makeTestDirectoryNode(id: "/second", name: "second", children: [secondFile])
        let secondStore = FileTreeStore(root: secondRoot, childrenByID: [secondRoot.id: [secondFile]])
        let secondSnapshot = makeTestSnapshot(root: secondRoot, store: secondStore)
        model.scanState.replaceCurrentSnapshot(secondSnapshot)

        XCTAssertTrue(model.discardPile.isEmpty)
    }

    @MainActor
    func testDiscardPileReviewMoveRequestsResolvedTopLevelNodesAndClearsAfterMove() async throws {
        let recorder = AppModelActionRecorder()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { recorder.movedToTrashURLs.append($0.url); return .matches }
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
        model.addNodesToDiscardPile([child])
        model.addNodesToDiscardPile([folder])

        let didRequestTrash = model.requestMoveDiscardPileToTrash()

        XCTAssertTrue(didRequestTrash)
        XCTAssertEqual(model.pendingTrashSelection?.nodes.map(\.id), [folder.id])
        XCTAssertEqual(model.discardPile.nodeIDs, [folder.id])

        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("confirmed trash action completed") {
            model.usageStats.bytesMovedToTrash > 0 || model.lastErrorMessage != nil
        }

        XCTAssertEqual(recorder.movedToTrashURLs, [folder.url])
        XCTAssertTrue(model.discardPile.isEmpty)
    }

    @MainActor
    func testDiscardPileReconcilesUnavailableQueuedIDsOut() {
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        let first = makeTestFileNode(id: "/selection/first.txt", name: "first.txt")
        let second = makeTestFileNode(id: "/selection/second.txt", name: "second.txt")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        model.scanState.replaceCurrentSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.addNodesToDiscardPile([first, second])
        XCTAssertEqual(model.discardPile.nodeIDs, [first.id, second.id])

        let updatedRoot = makeTestDirectoryNode(id: "/selection", name: "selection", children: [first])
        let updatedStore = FileTreeStore(root: updatedRoot, childrenByID: [updatedRoot.id: [first]])
        let updatedSnapshot = ScanSnapshot(
            id: snapshot.id,
            target: snapshot.target,
            treeStore: updatedStore,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            scanWarnings: snapshot.scanWarnings,
            isComplete: snapshot.isComplete,
            scanOptions: snapshot.scanOptions,
            source: snapshot.source
        )
        model.scanState.replaceCurrentSnapshot(updatedSnapshot)

        XCTAssertEqual(model.discardPile.nodeIDs, [first.id])
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
    func testFullDiskAccessStatusCanRefreshThroughInjectedProbe() async throws {
        var statuses: [FullDiskAccessStatus] = [.notGranted, .granted]
        var actions = AppSystemActions.inert
        actions.fullDiskAccessStatus = {
            statuses.removeFirst()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        try await waitUntil("full disk access becomes notGranted") {
            model.fullDiskAccessStatus == .notGranted
        }
        XCTAssertEqual(model.fullDiskAccessStatus, .notGranted)

        model.refreshFullDiskAccessStatus()

        try await waitUntil("full disk access becomes granted") {
            model.fullDiskAccessStatus == .granted
        }
        XCTAssertEqual(model.fullDiskAccessStatus, .granted)
    }

    @MainActor
    func testFullDiskAccessRefreshIgnoresSupersededProbe() async throws {
        let oldProbe = AsyncValueProbe<FullDiskAccessStatus>()
        var callCount = 0
        var oldProbeReturned = false
        var actions = AppSystemActions.inert
        actions.fullDiskAccessStatus = {
            callCount += 1
            if callCount == 1 {
                let status = await oldProbe.wait()
                oldProbeReturned = true
                return status
            }
            return .granted
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))
        try await waitUntil("initial permission probe starts") { await oldProbe.isWaiting }

        model.refreshFullDiskAccessStatus()
        try await waitUntil("latest permission probe applies") { model.fullDiskAccessStatus == .granted }
        await oldProbe.resume(returning: .notGranted)
        try await waitUntil("superseded permission probe returns") { oldProbeReturned }

        XCTAssertEqual(model.fullDiskAccessStatus, .granted)
    }

    @MainActor
    func testAsyncFullDiskAccessRefreshAppliesLatestProbe() async throws {
        var actions = AppSystemActions.inert
        actions.fullDiskAccessStatus = {
            .granted
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.fullDiskAccessStatus, .unknown)

        try await waitUntil("async full disk access refresh applies") {
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
        actions.targetCapacityDescriptions = {
            await probe.wait()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        XCTAssertEqual(model.availableTargets, [loadedTarget])
        XCTAssertTrue(model.targetCapacityDescriptions.isEmpty)

        try await waitUntil("async capacity description refresh starts") {
            await probe.isWaiting
        }

        await probe.resume(returning: [loadedTarget.id: "1 GB free of 2 GB"])

        try await waitUntil("async capacity descriptions apply") {
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

        try await waitUntil("trash safety policy refresh") {
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
        actions.targetCapacityDescriptions = {
            await probe.wait()
        }
        let model = AppModel(dependencies: makeDependencies(systemActions: actions))

        try await waitUntil("async capacity description refresh starts") {
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
            nodeChecksum: "checksum",
            formatVersion: 4
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

        try await waitUntil("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertEqual(previewedURLs, [archiveURL])
        let importedURLsBeforeConfirm = await archiveService.importedURLsSnapshot()
        XCTAssertTrue(importedURLsBeforeConfirm.isEmpty)
        XCTAssertNil(model.scanState.snapshot)

        model.confirmImportPreview()

        try await waitUntil("imported snapshot restored") {
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
        XCTAssertNil(model.pendingTrashSelection)
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
            nodeChecksum: "checksum",
            formatVersion: 4
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
        try await waitUntil("import preview presented") {
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
            nodeChecksum: "checksum",
            formatVersion: 4
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
        try await waitUntil("wide import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        model.confirmImportPreview()
        try await waitUntil("wide imported snapshot restored") {
            model.scanState.snapshot?.id == importedSnapshot.id
        }

        XCTAssertEqual(tableNodeCountAtSnapshotPublish, 0)
        XCTAssertEqual(model.navigation.focusedNodeID, root.id)

        try await waitUntil("wide imported table materialized") {
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
        try await waitUntil("scan started") {
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
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitUntil("export requested") {
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
        try await waitUntil("export confirmation presented") {
            model.exportConfirmation?.archiveURL == archiveURL
        }

        model.revealExportedSnapshotInFinder()

        XCTAssertEqual(recorder.revealedURLs, [archiveURL])
        XCTAssertNil(model.exportConfirmation)
    }

    @MainActor
    func testSupersededExportPanelCannotClearOrOutliveRestartedRequest() async throws {
        let staleURL = URL(filePath: "/tmp/stale-export.radixscan", directoryHint: .isDirectory)
        let currentURL = URL(filePath: "/tmp/current-export.radixscan", directoryHint: .isDirectory)
        let firstPanel = AsyncValueProbe<URL?>()
        let secondPanel = AsyncValueProbe<URL?>()
        let archiveService = SpyScanArchiveService()
        var panelRequestCount = 0
        var actions = AppSystemActions.inert
        actions.presentExportScanPanel = { _ in
            panelRequestCount += 1
            return await (panelRequestCount == 1 ? firstPanel : secondPanel).wait()
        }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanArchiveService: archiveService
        ))
        let file = makeTestFileNode(id: "/export-race/file.txt", name: "file.txt")
        let root = makeTestDirectoryNode(id: "/export-race", name: "Export Race", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        model.scanState.restoreCompletedSnapshot(ScanSnapshot(
            target: ScanTarget(id: root.id, url: root.url, displayName: "Export Race", kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            scanWarnings: [],
            isComplete: true
        ))

        model.exportCurrentScan()
        try await waitUntil("first export panel") {
            await firstPanel.isWaiting
        }
        model.cleanup()
        model.exportCurrentScan()
        try await waitUntil("second export panel") {
            await secondPanel.isWaiting
        }

        await firstPanel.resume(returning: staleURL)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.isExportPanelPresented)

        model.cleanup()
        await secondPanel.resume(returning: currentURL)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(model.isExportPanelPresented)
        let exportRequests = await archiveService.exportRequestsSnapshot()
        XCTAssertTrue(exportRequests.isEmpty)
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
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitUntil("export failure presented") {
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
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()

        try await waitUntil("export operation visible") {
            model.archiveOperation?.kind == .export
        }

        XCTAssertFalse(model.canExportCurrentScan)
        XCTAssertFalse(model.canImportScanSnapshot)
        XCTAssertEqual(model.scanState.snapshot?.id, snapshot.id)

        try await waitUntil("export request waiting") {
            await exportProbe.isWaiting
        }
        await exportProbe.resume(returning: ())

        try await waitUntil("export operation cleared") {
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
            isComplete: true
        )
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.exportCurrentScan()
        try await waitUntil("export request waiting") {
            await exportProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await exportProbe.resume(returning: ())

        try await waitUntil("export cancellation recorded") {
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
        try await waitUntil("preview request waiting") {
            await previewProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await previewProbe.resume(returning: ())

        try await waitUntil("preview cancellation recorded") {
            await archiveService.previewCancellationStatesSnapshot().count == 1
        }
        let states = await archiveService.previewCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
        XCTAssertNil(model.pendingImportPreview)
    }

    @MainActor
    func testDocumentOpenWaitsUntilOnboardingDismissesBeforeReadingArchive() async throws {
        let archiveURL = URL(filePath: "/tmp/onboarding-open.radixscan", directoryHint: .isDirectory)
        let previewProbe = AsyncValueProbe<Void>()
        let archiveService = SpyScanArchiveService(previewWaitProbe: previewProbe)
        let model = AppModel(dependencies: makeDependencies(scanArchiveService: archiveService))

        XCTAssertTrue(model.showsOnboarding)
        XCTAssertEqual(model.presentationCoordinator.activeSheet, .onboarding)

        model.openScanSnapshotArchive(archiveURL)

        let previewStartedDuringOnboarding = await previewProbe.isWaiting
        XCTAssertFalse(previewStartedDuringOnboarding)
        XCTAssertEqual(model.presentationCoordinator.activeSheet, .onboarding)

        model.dismissOnboarding()
        try await waitUntil("queued document open starts after onboarding") {
            await previewProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await previewProbe.resume(returning: ())
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
            nodeChecksum: "checksum",
            formatVersion: 4
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
        try await waitUntil("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }

        model.confirmImportPreview()
        try await waitUntil("import request waiting") {
            await importProbe.isWaiting
        }

        model.cancelArchiveOperation()
        await importProbe.resume(returning: ())

        try await waitUntil("import cancellation recorded") {
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
            nodeChecksum: "checksum",
            formatVersion: 4
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
        try await waitUntil("import preview presented") {
            model.pendingImportPreview?.archiveURL == archiveURL
        }
        model.confirmImportPreview()
        try await waitUntil("import request waiting") {
            await importProbe.isWaiting
        }

        let liveTarget = ScanTarget(
            id: "/live-scan",
            url: URL(filePath: "/live-scan", directoryHint: .isDirectory),
            displayName: "live-scan",
            kind: .folder
        )
        model.startScan(liveTarget)
        try await waitUntil("live scan started") {
            model.scanState.selectedTarget == liveTarget && model.scanState.isScanning
        }

        await importProbe.resume(returning: ())
        try await waitUntil("import cancellation recorded") {
            await archiveService.importCancellationStatesSnapshot().count == 1
        }

        let states = await archiveService.importCancellationStatesSnapshot()
        XCTAssertEqual(states, [true])
        XCTAssertEqual(model.scanState.selectedTarget, liveTarget)
        XCTAssertNotEqual(model.scanState.snapshot?.id, importedSnapshot.id)
    }

    @MainActor
    func testCompareScanSnapshotsOpensSetupBeforeFileSelection() async throws {
        let oldURL = URL(filePath: "/tmp/old.radixscan", directoryHint: .isDirectory)
        let newURL = URL(filePath: "/tmp/new.radixscan", directoryHint: .isDirectory)
        let oldSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-root",
            fileSize: 10,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20),
            sourceURL: oldURL
        )
        let newSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-root",
            fileSize: 35,
            startedAt: Date(timeIntervalSince1970: 30),
            finishedAt: Date(timeIntervalSince1970: 40),
            sourceURL: newURL
        )
        let archiveService = try SpyScanArchiveService(
            previewResultsByURL: [
                oldURL: makeArchivePreview(archiveURL: oldURL, snapshot: oldSnapshot),
                newURL: makeArchivePreview(archiveURL: newURL, snapshot: newSnapshot),
            ],
            importResultsByURL: [
                oldURL: makeArchiveImportResult(archiveURL: oldURL, snapshot: oldSnapshot),
                newURL: makeArchiveImportResult(archiveURL: newURL, snapshot: newSnapshot),
            ],
            importDelay: .milliseconds(25)
        )
        var selectedSnapshotURLs = [oldURL, newURL]
        var actions = AppSystemActions.inert
        actions.presentComparisonSnapshotPanel = {
            selectedSnapshotURLs.removeFirst()
        }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanArchiveService: archiveService
        ))

        model.compareScanSnapshots()
        XCTAssertNotNil(model.pendingComparisonSetup)
        XCTAssertNil(model.pendingComparisonSetup?.before)
        XCTAssertNil(model.pendingComparisonSetup?.after)

        model.chooseComparisonSnapshot(for: .before)

        try await waitUntil("comparison setup built") {
            model.pendingComparisonSetup?.before?.displayName == oldSnapshot.target.displayName
        }

        model.chooseComparisonSnapshot(for: .after)

        try await waitUntil("comparison setup completed") {
            model.pendingComparisonSetup?.after?.displayName == newSnapshot.target.displayName
        }

        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertEqual(previewedURLs, [oldURL, newURL])
        let importedURLsBeforeConfirm = await archiveService.importedURLsSnapshot()
        XCTAssertTrue(importedURLsBeforeConfirm.isEmpty)

        model.confirmComparisonSetup()

        try await waitUntil("comparison built") {
            model.scanComparison?.summary.changedCount == 1
        }

        let importedURLs = await archiveService.importedURLsSnapshot()
        let maximumConcurrentImports = await archiveService.maximumConcurrentImportsSnapshot()
        XCTAssertEqual(Set(importedURLs), Set([oldURL, newURL]))
        XCTAssertEqual(maximumConcurrentImports, 2)
        XCTAssertEqual(model.scanComparison?.before.id, oldSnapshot.id)
        XCTAssertEqual(model.scanComparison?.after.id, newSnapshot.id)
        XCTAssertEqual(model.scanComparison?.rows.first?.kind, .grew)
        XCTAssertEqual(model.scanComparison?.rows.first?.allocatedDelta, 25)
        XCTAssertNil(model.scanState.snapshot)

        let activeComparisonID = try XCTUnwrap(model.scanComparison?.id)

        model.compareScanSnapshots()

        XCTAssertEqual(model.scanComparison?.id, activeComparisonID)
        XCTAssertNotNil(model.pendingComparisonSetup)

        model.cancelComparisonSetup()

        XCTAssertEqual(model.scanComparison?.id, activeComparisonID)
        XCTAssertNil(model.pendingComparisonSetup)
    }

    func testComparisonImportConcurrencyRequiresArchivePairWithinMemoryBudget() throws {
        let oldURL = URL(filePath: "/tmp/old-budget.radixscan", directoryHint: .isDirectory)
        let newURL = URL(filePath: "/tmp/new-budget.radixscan", directoryHint: .isDirectory)
        let oldSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-budget",
            fileSize: 10,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20),
            sourceURL: oldURL
        )
        let newSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-budget",
            fileSize: 20,
            startedAt: Date(timeIntervalSince1970: 30),
            finishedAt: Date(timeIntervalSince1970: 40),
            sourceURL: newURL
        )
        let oldCandidate = ScanComparisonCandidate(
            preview: try makeArchivePreview(archiveURL: oldURL, snapshot: oldSnapshot)
        )
        let newCandidate = ScanComparisonCandidate(
            preview: try makeArchivePreview(archiveURL: newURL, snapshot: newSnapshot)
        )

        XCTAssertTrue(AppModel.shouldLoadComparisonSnapshotsConcurrently(
            before: oldCandidate,
            after: newCandidate,
            physicalMemory: .max
        ))
        XCTAssertFalse(AppModel.shouldLoadComparisonSnapshotsConcurrently(
            before: oldCandidate,
            after: newCandidate,
            physicalMemory: 0
        ))
        XCTAssertFalse(AppModel.shouldLoadComparisonSnapshotsConcurrently(
            before: ScanComparisonCandidate(snapshot: oldSnapshot),
            after: newCandidate,
            physicalMemory: .max
        ))
    }

    @MainActor
    func testSupersededComparisonPanelCannotApplyLateSelection() async throws {
        let oldURL = URL(filePath: "/tmp/superseded.radixscan", directoryHint: .isDirectory)
        let newURL = URL(filePath: "/tmp/current.radixscan", directoryHint: .isDirectory)
        let oldSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-root",
            fileSize: 10,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20),
            sourceURL: oldURL
        )
        let newSnapshot = makeComparisonSnapshot(
            rootPath: "/comparison-root",
            fileSize: 20,
            startedAt: Date(timeIntervalSince1970: 30),
            finishedAt: Date(timeIntervalSince1970: 40),
            sourceURL: newURL
        )
        let archiveService = SpyScanArchiveService(previewResultsByURL: [
            oldURL: try makeArchivePreview(archiveURL: oldURL, snapshot: oldSnapshot),
            newURL: try makeArchivePreview(archiveURL: newURL, snapshot: newSnapshot),
        ])
        let firstPanel = AsyncValueProbe<URL?>()
        let secondPanel = AsyncValueProbe<URL?>()
        var panelRequestCount = 0
        var actions = AppSystemActions.inert
        actions.presentComparisonSnapshotPanel = {
            panelRequestCount += 1
            return await (panelRequestCount == 1 ? firstPanel : secondPanel).wait()
        }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanArchiveService: archiveService
        ))

        model.compareScanSnapshots()
        model.chooseComparisonSnapshot(for: .before)
        try await waitUntil("first comparison panel") {
            await firstPanel.isWaiting
        }
        model.chooseComparisonSnapshot(for: .before)
        try await waitUntil("second comparison panel") {
            await secondPanel.isWaiting
        }

        await secondPanel.resume(returning: newURL)
        try await waitUntil("current comparison selection") {
            model.pendingComparisonSetup?.before?.displayName == newSnapshot.target.displayName
        }
        await firstPanel.resume(returning: oldURL)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.pendingComparisonSetup?.before?.displayName, newSnapshot.target.displayName)
        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertEqual(previewedURLs, [newURL])
    }

    @MainActor
    func testCompareCurrentScanWithSnapshotUsesCurrentScanAsAfter() async throws {
        let archiveURL = URL(filePath: "/tmp/current-compare.radixscan", directoryHint: .isDirectory)
        let archivedSnapshot = makeComparisonSnapshot(
            rootPath: "/current-root",
            fileSize: 10,
            sourceURL: archiveURL
        )
        let currentSnapshot = makeComparisonSnapshot(
            rootPath: "/current-root",
            fileSize: 30
        )
        let archiveService = try SpyScanArchiveService(
            previewResultsByURL: [
                archiveURL: makeArchivePreview(archiveURL: archiveURL, snapshot: archivedSnapshot),
            ],
            importResultsByURL: [
                archiveURL: makeArchiveImportResult(archiveURL: archiveURL, snapshot: archivedSnapshot),
            ]
        )
        var actions = AppSystemActions.inert
        actions.presentComparisonSnapshotPanel = { archiveURL }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanArchiveService: archiveService
        ))
        model.dismissOnboarding()
        model.scanState.restoreCompletedSnapshot(currentSnapshot)

        XCTAssertTrue(model.canCompareCurrentScanWithSnapshot)

        model.compareCurrentScanWithSnapshot()

        XCTAssertNil(model.pendingComparisonSetup?.before)
        XCTAssertEqual(model.pendingComparisonSetup?.after?.id, currentSnapshot.id)

        model.chooseComparisonSnapshot(for: .before)

        try await waitUntil("current comparison setup built") {
            model.pendingComparisonSetup?.before?.displayName == archivedSnapshot.target.displayName
        }

        model.confirmComparisonSetup()

        try await waitUntil("current comparison built") {
            model.scanComparison?.summary.changedCount == 1
        }

        XCTAssertEqual(model.scanComparison?.before.id, archivedSnapshot.id)
        XCTAssertEqual(model.scanComparison?.after.id, currentSnapshot.id)
        XCTAssertEqual(model.scanComparison?.rows.first?.kind, .grew)
        XCTAssertEqual(model.scanComparison?.rows.first?.allocatedDelta, 20)
        XCTAssertEqual(model.scanState.snapshot?.id, currentSnapshot.id)
        XCTAssertFalse(model.canUseWorkspaceCommands)
        XCTAssertTrue(model.isQuickLookKeyboardShortcutBlocked)

        model.closeScanComparison()

        XCTAssertTrue(model.canUseWorkspaceCommands)
        XCTAssertFalse(model.isQuickLookKeyboardShortcutBlocked)
    }

    @MainActor
    func testDroppedComparisonSnapshotLoadsIntoRequestedSlot() async throws {
        let archiveURL = URL(filePath: "/tmp/dropped.radixscan", directoryHint: .isDirectory)
        let snapshot = makeComparisonSnapshot(
            rootPath: "/dropped-root",
            fileSize: 10,
            sourceURL: archiveURL
        )
        let archiveService = try SpyScanArchiveService(
            previewResultsByURL: [
                archiveURL: makeArchivePreview(archiveURL: archiveURL, snapshot: snapshot),
            ]
        )
        let model = AppModel(dependencies: makeDependencies(scanArchiveService: archiveService))

        model.compareScanSnapshots()
        model.dropComparisonSnapshot(archiveURL, for: .after)

        try await waitUntil("dropped comparison snapshot loaded") {
            model.pendingComparisonSetup?.after?.displayName == snapshot.target.displayName
        }

        XCTAssertNil(model.pendingComparisonSetup?.before)
        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertEqual(previewedURLs, [archiveURL])
    }

    @MainActor
    func testSwapDuringComparisonPreviewLoadLandsResultInSwappedSlot() async throws {
        let archiveURL = URL(filePath: "/tmp/swap-loading.radixscan", directoryHint: .isDirectory)
        let snapshot = makeComparisonSnapshot(
            rootPath: "/swap-root",
            fileSize: 10,
            sourceURL: archiveURL
        )
        let previewProbe = AsyncValueProbe<Void>()
        let archiveService = try SpyScanArchiveService(
            previewResultsByURL: [
                archiveURL: makeArchivePreview(archiveURL: archiveURL, snapshot: snapshot),
            ],
            previewWaitProbe: previewProbe
        )
        let model = AppModel(dependencies: makeDependencies(scanArchiveService: archiveService))
        model.scanState.restoreCompletedSnapshot(snapshot)

        model.compareScanSnapshots()
        XCTAssertTrue(model.canExportCurrentScan)
        model.dropComparisonSnapshot(archiveURL, for: .before)

        try await waitUntil("comparison preview load started") {
            await previewProbe.isWaiting
        }
        XCTAssertEqual(model.pendingComparisonSetup?.loadingSlot, .before)
        XCTAssertTrue(model.isArchiveOperationInProgress)
        XCTAssertFalse(model.canExportCurrentScan)

        model.swapPendingComparisonSetup()
        XCTAssertEqual(model.pendingComparisonSetup?.loadingSlot, .after)
        XCTAssertNil(model.pendingComparisonSetup?.before)
        XCTAssertNil(model.pendingComparisonSetup?.after)

        await previewProbe.resume(returning: ())

        try await waitUntil("swapped comparison preview loaded") {
            model.pendingComparisonSetup?.loadingSlot == nil
        }
        XCTAssertNil(model.pendingComparisonSetup?.before)
        XCTAssertEqual(
            model.pendingComparisonSetup?.after?.displayName,
            snapshot.target.displayName
        )
    }

    @MainActor
    func testDroppedComparisonSnapshotRejectsOtherFileTypes() async throws {
        let archiveService = SpyScanArchiveService()
        let model = AppModel(dependencies: makeDependencies(scanArchiveService: archiveService))

        model.compareScanSnapshots()
        model.dropComparisonSnapshot(URL(filePath: "/tmp/not-a-scan.zip"), for: .before)

        XCTAssertEqual(
            model.pendingComparisonSetup?.errorMessage,
            "Drop a .radixscan saved scan."
        )
        let previewedURLs = await archiveService.previewedURLsSnapshot()
        XCTAssertTrue(previewedURLs.isEmpty)
    }

    @MainActor
    func testComparisonSetupRejectsReverseChronologicalOrder() async throws {
        let oldURL = URL(filePath: "/tmp/swap-old.radixscan", directoryHint: .isDirectory)
        let newURL = URL(filePath: "/tmp/swap-new.radixscan", directoryHint: .isDirectory)
        let oldSnapshot = makeComparisonSnapshot(
            rootPath: "/swap-root",
            fileSize: 10,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20),
            sourceURL: oldURL
        )
        let newSnapshot = makeComparisonSnapshot(
            rootPath: "/swap-root",
            fileSize: 35,
            startedAt: Date(timeIntervalSince1970: 30),
            finishedAt: Date(timeIntervalSince1970: 40),
            sourceURL: newURL
        )
        let archiveService = try SpyScanArchiveService(
            previewResultsByURL: [
                oldURL: makeArchivePreview(archiveURL: oldURL, snapshot: oldSnapshot),
                newURL: makeArchivePreview(archiveURL: newURL, snapshot: newSnapshot),
            ],
            importResultsByURL: [
                oldURL: makeArchiveImportResult(archiveURL: oldURL, snapshot: oldSnapshot),
                newURL: makeArchiveImportResult(archiveURL: newURL, snapshot: newSnapshot),
            ]
        )
        var selectedSnapshotURLs = [oldURL, newURL]
        var actions = AppSystemActions.inert
        actions.presentComparisonSnapshotPanel = {
            selectedSnapshotURLs.removeFirst()
        }
        let model = AppModel(dependencies: makeDependencies(
            systemActions: actions,
            scanArchiveService: archiveService
        ))

        model.compareScanSnapshots()
        model.chooseComparisonSnapshot(for: .before)
        try await waitUntil("comparison setup built") {
            model.pendingComparisonSetup?.before?.displayName == oldSnapshot.target.displayName
        }
        model.chooseComparisonSnapshot(for: .after)
        try await waitUntil("comparison setup completed") {
            model.pendingComparisonSetup?.after?.displayName == newSnapshot.target.displayName
        }

        model.swapPendingComparisonSetup()
        XCTAssertEqual(model.pendingComparisonSetup?.before?.displayName, newSnapshot.target.displayName)
        XCTAssertFalse(model.pendingComparisonSetup?.canCompare ?? true)
        XCTAssertEqual(
            model.pendingComparisonSetup?.validationMessage,
            "The earlier scan must precede the later scan."
        )

        model.swapPendingComparisonSetup()
        XCTAssertEqual(model.pendingComparisonSetup?.before?.displayName, oldSnapshot.target.displayName)
        XCTAssertTrue(model.pendingComparisonSetup?.canCompare ?? false)
        XCTAssertNil(model.pendingComparisonSetup?.validationMessage)
        XCTAssertNil(model.pendingComparisonSetup?.errorMessage)
    }

    @MainActor
    func testImportedSnapshotCannotBeComparedAsCurrentScan() {
        let archiveURL = URL(filePath: "/tmp/imported-current.radixscan", directoryHint: .isDirectory)
        let importedSnapshot = makeComparisonSnapshot(
            rootPath: "/imported-current",
            fileSize: 10,
            sourceURL: archiveURL
        )
        let model = AppModel(dependencies: makeDependencies())

        model.scanState.restoreCompletedSnapshot(importedSnapshot)

        XCTAssertFalse(model.canCompareCurrentScanWithSnapshot)
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

private actor ControlledCapacityLoader {
    private struct RequestCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let requestID: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var issuedURLs: [URL] = []
    private var continuations: [Int: CheckedContinuation<Int64?, Never>] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var requestCountWaiters: [RequestCountWaiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    func load(_ url: URL) async -> Int64? {
        let requestID = issuedURLs.count
        issuedURLs.append(url)
        resumeRequestCountWaiters()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task {
                await self.recordCancellation(id: requestID)
            }
        }
    }

    func waitForIssuedRequestCount(_ count: Int) async throws {
        if issuedURLs.count >= count { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append(RequestCountWaiter(count: count, continuation: continuation))
        }
    }

    func waitForCancelledRequest(id requestID: Int) async throws {
        if cancelledRequestIDs.contains(requestID) { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CancellationWaiter(requestID: requestID, continuation: continuation))
        }
    }

    func completeRequest(id requestID: Int, with value: Int64?) -> Bool {
        guard let continuation = continuations.removeValue(forKey: requestID) else { return false }
        continuation.resume(returning: value)
        return true
    }

    private func recordCancellation(id requestID: Int) {
        cancelledRequestIDs.insert(requestID)
        var pending: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if waiter.requestID == requestID {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        cancellationWaiters = pending
    }

    private func resumeRequestCountWaiters() {
        var pending: [RequestCountWaiter] = []
        for waiter in requestCountWaiters {
            if issuedURLs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
    }
}

private final class NeverFinishingScanService: ScanEventStreaming, @unchecked Sendable {
    private var continuations: [AsyncThrowingStream<ScanProgressEvent, Error>.Continuation] = []

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            continuations.append(continuation)
        }
    }

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
    }
}

private final class ControlledAppModelScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ScanTarget] = []
    private var storedOptions: [ScanOptions] = []

    var requests: [ScanTarget] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var options: [ScanOptions] {
        lock.lock()
        defer { lock.unlock() }
        return storedOptions
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            storedRequests.append(target)
            storedOptions.append(options)
            lock.unlock()
        }
    }

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
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
    scanService: any ScanEventStreaming = IncrementalScanService(),
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

private func makeArchiveImportResult(
    archiveURL: URL,
    snapshot: ScanSnapshot
) throws -> ScanArchiveImportResult {
    let manifest = try ScanArchiveDocument(
        exportedAt: Date(timeIntervalSince1970: 3),
        appVersion: "Tests",
        snapshot: snapshot,
        pathMode: .absolute,
        sections: ScanArchiveSections(
            nodes: "nodes.jsonl",
            topology: "topology.json",
            warnings: "warnings.json",
            stats: "stats.json"
        ),
        nodeChecksum: "checksum",
        formatVersion: 4
    )
    return ScanArchiveImportResult(
        archiveURL: archiveURL,
        snapshot: snapshot,
        manifest: manifest
    )
}

private func makeArchivePreview(
    archiveURL: URL,
    snapshot: ScanSnapshot
) throws -> ScanArchivePreview {
    let manifest = try ScanArchiveDocument(
        exportedAt: Date(timeIntervalSince1970: 3),
        appVersion: "Tests",
        snapshot: snapshot,
        pathMode: .absolute,
        sections: ScanArchiveSections(
            nodes: "nodes.jsonl",
            topology: "topology.json",
            warnings: "warnings.json",
            stats: "stats.json"
        ),
        nodeChecksum: "checksum",
        formatVersion: 4
    )
    return ScanArchivePreview(
        archiveURL: archiveURL,
        archiveSize: 1,
        manifest: manifest,
        stats: ScanArchiveStatsV1(snapshot.aggregateStats)
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

    func saveOnboardingPage(_ page: OnboardingPage) {
        preferences.onboardingPage = page
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
    var terminalDirectoryURLs: [URL] = []
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
    private let previewResultsByURL: [URL: ScanArchivePreview]
    private let importResult: ScanArchiveImportResult?
    private let importResultsByURL: [URL: ScanArchiveImportResult]
    private let exportWaitProbe: AsyncValueProbe<Void>?
    private let previewWaitProbe: AsyncValueProbe<Void>?
    private let importWaitProbe: AsyncValueProbe<Void>?
    private let importDelay: Duration?
    private var activeImportCount = 0
    private var maximumConcurrentImportCount = 0
    private(set) var exportCancellationStates: [Bool] = []
    private(set) var previewCancellationStates: [Bool] = []
    private(set) var importCancellationStates: [Bool] = []

    init(
        previewResult: ScanArchivePreview? = nil,
        previewResultsByURL: [URL: ScanArchivePreview] = [:],
        importResult: ScanArchiveImportResult? = nil,
        importResultsByURL: [URL: ScanArchiveImportResult] = [:],
        exportWaitProbe: AsyncValueProbe<Void>? = nil,
        previewWaitProbe: AsyncValueProbe<Void>? = nil,
        importWaitProbe: AsyncValueProbe<Void>? = nil,
        importDelay: Duration? = nil
    ) {
        self.previewResult = previewResult
        self.previewResultsByURL = previewResultsByURL
        self.importResult = importResult
        self.importResultsByURL = importResultsByURL
        self.exportWaitProbe = exportWaitProbe
        self.previewWaitProbe = previewWaitProbe
        self.importWaitProbe = importWaitProbe
        self.importDelay = importDelay
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
        if let result = previewResultsByURL[sourceURL] {
            return result
        }
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
        activeImportCount += 1
        maximumConcurrentImportCount = max(maximumConcurrentImportCount, activeImportCount)
        defer { activeImportCount -= 1 }
        if let importDelay {
            try await Task.sleep(for: importDelay)
        }
        if let importWaitProbe {
            await importWaitProbe.wait()
        }
        importCancellationStates.append(Task.isCancelled)
        if let result = importResultsByURL[sourceURL] {
            return result
        }
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

    func maximumConcurrentImportsSnapshot() -> Int {
        maximumConcurrentImportCount
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
