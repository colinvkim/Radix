import XCTest
@testable import RadixCore

final class WorkspaceNavigationModelTests: XCTestCase {
    @MainActor
    func testSelectingValidAndInvalidNodes() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.select(nodeID: fixture.docFile.id)
        XCTAssertEqual(model.selectedNodeID, fixture.docFile.id)
        XCTAssertEqual(model.selectedNode?.id, fixture.docFile.id)
        XCTAssertEqual(model.selectedAncestorIDs, Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        XCTAssertTrue(model.canClearSelection)

        model.select(nodeID: "/missing")
        XCTAssertNil(model.selectedNodeID)
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
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)

        model.navigateBack()
        XCTAssertEqual(model.focusedNodeID, fixture.root.id)
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)

        model.navigateForward()
        XCTAssertEqual(model.focusedNodeID, fixture.docs.id)
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)
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
        XCTAssertFalse(model.canClearSelection)
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
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)
        XCTAssertTrue(model.tableContentID.hasPrefix(replacement.snapshot.id.uuidString))
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
    let docFile = makeNavigationFileNode(id: rootID + "/docs/report.txt", name: "report.txt", size: 20)
    let cacheFile = makeNavigationFileNode(id: rootID + "/cache/item.db", name: "item.db", size: 12)
    let rootFile = makeNavigationFileNode(id: rootID + "/readme.txt", name: "readme.txt", size: 5)
    let docs = makeNavigationDirectoryNode(id: rootID + "/docs", name: "docs", children: [docFile])
    let cache = makeNavigationDirectoryNode(id: rootID + "/cache", name: "cache", children: [cacheFile])
    let root = makeNavigationDirectoryNode(id: rootID, name: "root", children: [docs, cache, rootFile])
    let store = FileTreeStore(root: root, childrenByID: [
        root.id: [docs, cache, rootFile],
        docs.id: [docFile],
        cache.id: [cacheFile]
    ])
    let snapshot = ScanSnapshot(
        target: ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: [],
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
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

private func makeNavigationFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
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

private func makeNavigationDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord]
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        isPackage: false,
        isAccessible: true
    )
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
