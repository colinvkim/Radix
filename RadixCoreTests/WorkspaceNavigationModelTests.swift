import Combine
import XCTest
@testable import RadixCore

final class WorkspaceNavigationModelTests: XCTestCase {
    @MainActor
    func testSelectingValidAndInvalidNodes() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.select(nodeID: fixture.docFile.id)
        XCTAssertEqual(model.selectedNodeID, fixture.docFile.id)
        XCTAssertEqual(model.selectedNodeIDs, [fixture.docFile.id])
        XCTAssertEqual(model.selectedNode?.id, fixture.docFile.id)
        XCTAssertEqual(model.selectedAncestorIDs, Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        XCTAssertTrue(model.canClearSelection)

        model.select(nodeID: "/missing")
        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedNodeIDs.isEmpty)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
        XCTAssertFalse(model.canClearSelection)

        model.select(nodeID: fixture.cache.id)
        XCTAssertEqual(model.selectedNodeID, fixture.cache.id)
        XCTAssertEqual(model.selectedAncestorIDs, Set([fixture.root.id, fixture.cache.id]))

        model.select(nodeID: nil)
        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
    }

    @MainActor
    func testSelectingMultipleNodesKeepsPrimarySelection() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.select(
            nodeIDs: [fixture.cache.id, fixture.rootFile.id],
            primaryNodeID: fixture.rootFile.id
        )

        XCTAssertEqual(model.selectedNodeID, fixture.rootFile.id)
        XCTAssertEqual(model.selectedNodeIDs, [fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.selectedNodes.map(\.id), [fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.selectedAncestorIDs, Set([fixture.root.id, fixture.rootFile.id]))
        XCTAssertTrue(model.canClearSelection)

        model.focus(nodeID: fixture.docs.id)

        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedNodeIDs.isEmpty)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
    }

    @MainActor
    func testFocusingNodesPreservesHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        XCTAssertEqual(model.focusedNodeID, fixture.root.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.root.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        XCTAssertFalse(model.canNavigateBack)

        model.focus(nodeID: fixture.docs.id)

        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.docs.id)
        XCTAssertEqual(model.breadcrumbNodes.map(\.id), [fixture.root.id, fixture.docs.id])
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)

        model.focus(nodeID: "/missing")
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
    }

    @MainActor
    func testBackAndForwardNavigation() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.focus(nodeID: fixture.cache.id)

        XCTAssertEqual(model.focusedNodeID, fixture.cache.id)
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)

        model.navigateBack()
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.docs.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)

        model.navigateBack()
        XCTAssertEqual(model.focusedNodeID, fixture.root.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.root.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)

        model.navigateForward()
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.docs.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)
    }

    @MainActor
    func testNavigateToParentRecordsHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        XCTAssertFalse(model.canNavigateToParent)
        XCTAssertNil(model.currentFocusNodeParent)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        XCTAssertTrue(model.canNavigateToParent)
        XCTAssertEqual(model.currentFocusNodeParent?.id, fixture.root.id)

        model.navigateToParent()

        XCTAssertEqual(model.focusedNodeID, fixture.root.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.root.id)
        XCTAssertNil(model.currentFocusNodeParent)
        XCTAssertFalse(model.canNavigateToParent)
        XCTAssertEqual(model.selectedNodeID, fixture.docFile.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)

        model.navigateBack()
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
    }

    @MainActor
    func testResetFocusToRootClearsSelectionAndRecordsHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.resetFocusToRoot()

        XCTAssertEqual(model.focusedNodeID, fixture.root.id)
        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        XCTAssertTrue(model.isFocusedAtRoot)
        XCTAssertTrue(model.canNavigateBack)

        model.navigateBack()
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
    }

    @MainActor
    func testFocusOutsideSelectedSubtreeClearsSelection() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.focus(nodeID: fixture.cache.id)

        XCTAssertEqual(model.focusedNodeID, fixture.cache.id)
        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(model.breadcrumbNodes.map(\.id), [fixture.root.id, fixture.cache.id])
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.cacheFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.cache.id)")
        XCTAssertFalse(model.canClearSelection)
    }

    @MainActor
    func testFocusPublishesSingleCoherentState() throws {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.focus(nodeID: fixture.cache.id)

        XCTAssertEqual(publishedStates.count, 1)
        let state = try XCTUnwrap(publishedStates.first)
        XCTAssertEqual(state.focusedNodeID, fixture.cache.id)
        XCTAssertNil(state.selectedNodeID)
        XCTAssertTrue(state.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(state.tableNodes.map(\.id), [fixture.cacheFile.id])
        XCTAssertEqual(state.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.cache.id)")
        XCTAssertEqual(state.focusBackStack, [fixture.root.id, fixture.docs.id])
        XCTAssertTrue(state.focusForwardStack.isEmpty)
    }

    @MainActor
    func testSelectAndFocusPublishesSingleCoherentState() throws {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.selectAndFocus(nodeID: fixture.docs.id)

        XCTAssertEqual(publishedStates.count, 1)
        let state = try XCTUnwrap(publishedStates.first)
        XCTAssertEqual(state.selectedNodeID, fixture.docs.id)
        XCTAssertEqual(state.focusedNodeID, fixture.docs.id)
        XCTAssertEqual(state.selectedAncestorIDs, Set([fixture.root.id, fixture.docs.id]))
        XCTAssertEqual(state.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertEqual(state.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        XCTAssertEqual(state.focusBackStack, [fixture.root.id])
        XCTAssertTrue(state.focusForwardStack.isEmpty)
    }

    @MainActor
    func testSelectionPublishesAncestorsWithoutReplacingTableState() throws {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        let initialTableContentID = model.tableContentID
        let initialTableNodeIDs = model.tableNodes.map(\.id)
        let initialTableStorageAddress = try XCTUnwrap(tableStorageAddress(of: model.state.tableNodes))
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.select(nodeID: fixture.docFile.id)

        XCTAssertEqual(publishedStates.count, 1)
        var state = try XCTUnwrap(publishedStates.first)
        XCTAssertEqual(state.selectedNodeID, fixture.docFile.id)
        XCTAssertEqual(state.selectedAncestorIDs, Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        XCTAssertEqual(state.tableContentID, initialTableContentID)
        XCTAssertEqual(state.tableNodes.map(\.id), initialTableNodeIDs)
        XCTAssertEqual(tableStorageAddress(of: state.tableNodes), initialTableStorageAddress)

        publishedStates.removeAll()
        model.clearSelection()

        XCTAssertEqual(publishedStates.count, 1)
        state = try XCTUnwrap(publishedStates.first)
        XCTAssertNil(state.selectedNodeID)
        XCTAssertTrue(state.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(state.tableContentID, initialTableContentID)
        XCTAssertEqual(state.tableNodes.map(\.id), initialTableNodeIDs)
        XCTAssertEqual(tableStorageAddress(of: state.tableNodes), initialTableStorageAddress)
    }

    @MainActor
    func testTableStateTracksRootFallbackAndFocusedFiles() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.setFocusedNodeID(nil)

        XCTAssertNil(model.focusedNodeID)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.root.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")

        model.setFocusedNodeID(fixture.docFile.id)

        XCTAssertEqual(model.focusedNodeID, fixture.docFile.id)
        XCTAssertEqual(model.currentFocusNode?.id, fixture.docFile.id)
        XCTAssertEqual(model.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertEqual(model.tableContentID, "\(fixture.snapshot.id.uuidString)|\(fixture.docFile.id)")
    }

    @MainActor
    func testReconcilingSnapshotReplacementClearsInvalidNavigationState() {
        let fixture = makeNavigationFixture()
        let replacement = makeNavigationFixture(rootID: "/replacement")
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)
        XCTAssertTrue(model.canNavigateBack)

        model.reconcileAfterSnapshotApplied(replacement.snapshot)

        XCTAssertEqual(model.focusedNodeID, replacement.root.id)
        XCTAssertEqual(model.currentFocusNode?.id, replacement.root.id)
        XCTAssertNil(model.selectedNodeID)
        XCTAssertTrue(model.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(model.tableNodes.map(\.id), [replacement.docs.id, replacement.cache.id, replacement.rootFile.id])
        XCTAssertEqual(model.tableContentID, "\(replacement.snapshot.id.uuidString)|\(replacement.root.id)")
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)
        XCTAssertTrue(model.tableContentID.hasPrefix(replacement.snapshot.id.uuidString))
    }

    @MainActor
    func testSnapshotReconciliationPublishesSingleCoherentState() throws {
        let fixture = makeNavigationFixture()
        let replacement = makeNavigationFixture(rootID: "/replacement")
        let model = makeConfiguredNavigationModel(fixture: fixture)
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.reconcileAfterSnapshotApplied(replacement.snapshot)

        XCTAssertEqual(publishedStates.count, 1)
        let state = try XCTUnwrap(publishedStates.first)
        XCTAssertEqual(state.snapshotID, replacement.snapshot.id)
        XCTAssertEqual(state.focusedNodeID, replacement.root.id)
        XCTAssertNil(state.selectedNodeID)
        XCTAssertTrue(state.selectedAncestorIDs.isEmpty)
        XCTAssertEqual(state.tableNodes.map(\.id), [replacement.docs.id, replacement.cache.id, replacement.rootFile.id])
        XCTAssertEqual(state.tableContentID, "\(replacement.snapshot.id.uuidString)|\(replacement.root.id)")
        XCTAssertTrue(state.focusBackStack.isEmpty)
        XCTAssertTrue(state.focusForwardStack.isEmpty)
    }

    @MainActor
    func testUnchangedScanContextDoesNotRepublish() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.updateScanContext(snapshot: fixture.snapshot)
        model.reconcileAfterSnapshotApplied(fixture.snapshot)

        XCTAssertTrue(publishedStates.isEmpty)
    }

    @MainActor
    func testAppModelRoutesNavigationActionsThroughNavigationState() {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)
        model.select(nodeID: fixture.docFile.id)
        model.focus(nodeID: fixture.docs.id)

        XCTAssertEqual(model.navigation.selectedNodeID, fixture.docFile.id)
        XCTAssertEqual(model.navigation.selectedNode?.id, fixture.docFile.id)
        XCTAssertEqual(model.navigation.selectedAncestorIDs, Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        XCTAssertEqual(model.navigation.selectedNodeParent?.id, fixture.docs.id)
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.docs.id)
        XCTAssertEqual(model.navigation.currentFocusNode?.id, fixture.docs.id)
        XCTAssertEqual(model.navigation.breadcrumbNodes.map(\.id), [fixture.root.id, fixture.docs.id])
        XCTAssertEqual(model.navigation.tableNodes.map(\.id), [fixture.docFile.id])
        XCTAssertTrue(model.navigation.canClearSelection)
        XCTAssertTrue(model.navigation.canNavigateBack)
        XCTAssertTrue(model.navigation.tableContentID.hasPrefix(fixture.snapshot.id.uuidString))

        model.select(nodeID: "/missing")
        XCTAssertNil(model.navigation.selectedNodeID)

        model.select(nodeID: fixture.docFile.id)
        model.navigation.setFocusedNodeID(fixture.cache.id)
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.cache.id)
        XCTAssertNil(model.navigation.selectedNodeID)

        model.navigation.setFocusedNodeID("/missing")
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.cache.id)

        model.navigateBack()
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.root.id)

        model.focus(nodeID: fixture.docs.id)
        model.navigateToParent()
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.root.id)
    }

    @MainActor
    func testAppModelDeferredSelectionPublishesAfterViewUpdate() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docFile.id)

        XCTAssertNil(model.navigation.selectedNodeID)

        try await waitUntil("deferred selection") {
            model.navigation.selectedNodeID == fixture.docFile.id
        }
    }

    @MainActor
    func testAppModelDeferredSelectAndFocusKeepsZoomedSelection() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docs.id)
        model.selectAndFocusAfterViewUpdate(nodeID: fixture.docs.id)

        XCTAssertNil(model.navigation.selectedNodeID)
        XCTAssertEqual(model.navigation.focusedNodeID, fixture.root.id)

        try await waitUntil("deferred select and focus") {
            model.navigation.selectedNodeID == fixture.docs.id &&
                model.navigation.focusedNodeID == fixture.docs.id
        }
    }

    @MainActor
    func testAppModelDirectNavigationCancelsDeferredSelection() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docFile.id)
        model.clearSelection()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(model.navigation.selectedNodeID)
    }
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
private func makeConfiguredNavigationModel(fixture: NavigationFixture) -> WorkspaceNavigationModel {
    let model = WorkspaceNavigationModel()
    model.reconcileAfterSnapshotApplied(fixture.snapshot)
    return model
}

@MainActor
private func makeNavigationAppDependencies() -> AppDependencies {
    AppDependencies(
        preferences: NavigationAppPreferencesStore(),
        recentTargets: RecentTargetStore(
            persistence: NavigationRecentTargetPersistence(),
            isAvailable: { _ in true }
        ),
        systemActions: .inert
    )
}

private struct NavigationFixture {
    let root: FileNodeRecord
    let docs: FileNodeRecord
    let cache: FileNodeRecord
    let docFile: FileNodeRecord
    let cacheFile: FileNodeRecord
    let rootFile: FileNodeRecord
    let store: FileTreeStore
    let snapshot: ScanSnapshot
}

private func makeNavigationFixture(rootID: String = "/root") -> NavigationFixture {
    let docFile = makeTestFileNode(id: rootID + "/docs/report.txt", name: "report.txt", size: 20)
    let cacheFile = makeTestFileNode(id: rootID + "/cache/item.db", name: "item.db", size: 12)
    let rootFile = makeTestFileNode(id: rootID + "/readme.txt", name: "readme.txt", size: 5)
    let docs = makeTestDirectoryNode(id: rootID + "/docs", name: "docs", children: [docFile])
    let cache = makeTestDirectoryNode(id: rootID + "/cache", name: "cache", children: [cacheFile])
    let root = makeTestDirectoryNode(id: rootID, name: "root", children: [docs, cache, rootFile])
    let store = FileTreeStore(root: root, childrenByID: [
        root.id: [docs, cache, rootFile],
        docs.id: [docFile],
        cache.id: [cacheFile]
    ])
    let snapshot = makeTestSnapshot(root: root, store: store)
    return NavigationFixture(
        root: root,
        docs: docs,
        cache: cache,
        docFile: docFile,
        cacheFile: cacheFile,
        rootFile: rootFile,
        store: store,
        snapshot: snapshot
    )
}

private func tableStorageAddress(of nodes: [FileNodeRecord]) -> UnsafeRawPointer? {
    nodes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return nil }
        return UnsafeRawPointer(baseAddress)
    }
}

private final class NavigationAppPreferencesStore: AppPreferencesPersisting {
    var preferences = AppPreferences.defaults

    func loadPreferences() -> AppPreferences {
        preferences
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        self.preferences.scan = preferences
    }

    func markOnboardingComplete() {
        preferences.didCompleteOnboarding = true
    }

    func markOnboardingIncomplete() {
        preferences.didCompleteOnboarding = false
    }
}

private final class NavigationRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget] = []

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
    }

    func clearRecentTargets() {
        targets = []
    }
}
