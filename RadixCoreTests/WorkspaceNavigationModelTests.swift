import Combine
import Foundation
import Testing

@testable import RadixCore

private actor NavigationTableLoadGate {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestCount = 0

    func load(store: FileTreeStore, id: String) async -> [FileNodeRecord] {
        let index = requestCount
        requestCount += 1
        await withCheckedContinuation { continuations[index] = $0 }
        return store.children(of: id)
    }

    func resume(at index: Int) { continuations.removeValue(forKey: index)?.resume() }
}

@MainActor
struct WorkspaceNavigationModelTests {
    @Test
    func testLargeDirectoryLoadsInBackgroundAndIgnoresSupersededResult() async throws {
        let files = (0..<600).map { makeTestFileNode(id: "/large/file-\($0)", name: "file-\($0)") }
        let root = makeTestDirectoryNode(id: "/large", name: "large", children: files)
        let snapshot = makeTestSnapshot(root: root, store: FileTreeStore(root: root, childrenByID: [root.id: files]))
        let gate = NavigationTableLoadGate()
        let model = WorkspaceNavigationModel(tableLoader: { store, id in
            await gate.load(store: store, id: id)
        })
        model.updateScanContext(snapshot: snapshot)
        #expect(model.isLoadingTableNodes)
        #expect(model.tableNodes.isEmpty)
        try await waitUntil { await gate.requestCount == 1 }
        // Selection and same-context refreshes must not restart pending work.
        model.select(nodeID: files[0].id)
        model.refreshTableNodesForCurrentContext()
        await Task.yield()
        let requests = await gate.requestCount
        #expect(requests == 1)

        model.reset()
        await gate.resume(at: 0)
        await Task.yield()
        #expect(!(model.isLoadingTableNodes))
        #expect(model.tableNodes.isEmpty)

        model.updateScanContext(snapshot: snapshot)
        try await waitUntil { await gate.requestCount == 2 }
        let revision = model.tableContentRevision
        await gate.resume(at: 1)
        try await waitUntil { !model.isLoadingTableNodes }
        #expect(model.tableNodes == files)
        #expect(model.tableContentRevision == revision + 1)
    }

    @Test
    func testExplicitlyDeferredLargeDirectoryWaitsForRefresh() async throws {
        let files = (0..<600).map { makeTestFileNode(id: "/large/file-\($0)", name: "file-\($0)") }
        let root = makeTestDirectoryNode(id: "/large", name: "large", children: files)
        let snapshot = makeTestSnapshot(root: root, store: FileTreeStore(root: root, childrenByID: [root.id: files]))
        let model = WorkspaceNavigationModel()
        model.updateScanContext(snapshot: snapshot, loadTableNodesImmediately: false)
        await Task.yield()
        #expect(!(model.isLoadingTableNodes))
        #expect(model.tableNodes.isEmpty)
        model.refreshTableNodesForCurrentContext()
        try await waitUntil { !model.isLoadingTableNodes }
        #expect(model.tableNodes == files)
    }

    @Test
    func testSelectingValidAndInvalidNodes() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        #expect(model.selectedNodes.isEmpty)

        model.select(nodeID: fixture.docFile.id)
        #expect(model.selectedNodeID == fixture.docFile.id)
        #expect(model.selectedNodeIDs == [fixture.docFile.id])
        #expect(model.selectedNode?.id == fixture.docFile.id)
        #expect(model.selectedNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.selectedAncestorIDs == Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        #expect(model.canClearSelection)

        model.select(nodeID: "/missing")
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedNodeIDs.isEmpty)
        #expect(model.selectedNodes.isEmpty)
        #expect(model.selectedAncestorIDs.isEmpty)
        #expect(!(model.canClearSelection))

        model.select(nodeID: fixture.cache.id)
        #expect(model.selectedNodeID == fixture.cache.id)
        #expect(model.selectedNodes.map(\.id) == [fixture.cache.id])
        #expect(model.selectedAncestorIDs == Set([fixture.root.id, fixture.cache.id]))

        model.select(nodeID: nil)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedNodes.isEmpty)
        #expect(model.selectedAncestorIDs.isEmpty)
    }

    @Test
    func testSelectingMultipleNodesKeepsPrimarySelection() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.select(
            nodeIDs: [fixture.cache.id, fixture.rootFile.id],
            primaryNodeID: fixture.rootFile.id
        )

        #expect(model.selectedNodeID == fixture.rootFile.id)
        #expect(model.selectedNodeIDs == [fixture.cache.id, fixture.rootFile.id])
        #expect(model.selectedNodes.map(\.id) == [fixture.cache.id, fixture.rootFile.id])
        #expect(model.selectedAncestorIDs == Set([fixture.root.id, fixture.rootFile.id]))
        #expect(model.canClearSelection)

        model.focus(nodeID: fixture.docs.id)

        #expect(model.selectedNodeID == nil)
        #expect(model.selectedNodeIDs.isEmpty)
        #expect(model.selectedAncestorIDs.isEmpty)
    }

    @Test
    func testFocusingNodesPreservesHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        #expect(model.focusedNodeID == fixture.root.id)
        #expect(model.currentFocusNode?.id == fixture.root.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        #expect(!(model.canNavigateBack))

        model.focus(nodeID: fixture.docs.id)

        #expect(model.focusedNodeID == fixture.docs.id)
        #expect(model.currentFocusNode?.id == fixture.docs.id)
        #expect(model.breadcrumbNodes.map(\.id) == [fixture.root.id, fixture.docs.id])
        #expect(model.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        #expect(model.canNavigateBack)
        #expect(!(model.canNavigateForward))

        model.focus(nodeID: "/missing")
        #expect(model.focusedNodeID == fixture.docs.id)
    }

    @Test
    func testBackAndForwardNavigation() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.focus(nodeID: fixture.cache.id)

        #expect(model.focusedNodeID == fixture.cache.id)
        #expect(model.canNavigateBack)
        #expect(!(model.canNavigateForward))

        model.navigateBack()
        #expect(model.focusedNodeID == fixture.docs.id)
        #expect(model.currentFocusNode?.id == fixture.docs.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        #expect(model.canNavigateBack)
        #expect(model.canNavigateForward)

        model.navigateBack()
        #expect(model.focusedNodeID == fixture.root.id)
        #expect(model.currentFocusNode?.id == fixture.root.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        #expect(!(model.canNavigateBack))
        #expect(model.canNavigateForward)

        model.navigateForward()
        #expect(model.focusedNodeID == fixture.docs.id)
        #expect(model.currentFocusNode?.id == fixture.docs.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        #expect(model.canNavigateBack)
        #expect(model.canNavigateForward)
    }

    @Test
    func testNavigateToParentRecordsHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        #expect(!(model.canNavigateToParent))
        #expect(model.currentFocusNodeParent == nil)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        #expect(model.canNavigateToParent)
        #expect(model.currentFocusNodeParent?.id == fixture.root.id)

        model.navigateToParent()

        #expect(model.focusedNodeID == fixture.root.id)
        #expect(model.currentFocusNode?.id == fixture.root.id)
        #expect(model.currentFocusNodeParent == nil)
        #expect(!(model.canNavigateToParent))
        #expect(model.selectedNodeID == fixture.docFile.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.canNavigateBack)
        #expect(!(model.canNavigateForward))

        model.navigateBack()
        #expect(model.focusedNodeID == fixture.docs.id)
    }

    @Test
    func testResetFocusToRootClearsSelectionAndRecordsHistory() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.resetFocusToRoot()

        #expect(model.focusedNodeID == fixture.root.id)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedAncestorIDs.isEmpty)
        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        #expect(model.isFocusedAtRoot)
        #expect(model.canNavigateBack)

        model.navigateBack()
        #expect(model.focusedNodeID == fixture.docs.id)
    }

    @Test
    func testFocusOutsideSelectedSubtreeClearsSelection() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)

        model.focus(nodeID: fixture.cache.id)

        #expect(model.focusedNodeID == fixture.cache.id)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedAncestorIDs.isEmpty)
        #expect(model.breadcrumbNodes.map(\.id) == [fixture.root.id, fixture.cache.id])
        #expect(model.tableNodes.map(\.id) == [fixture.cacheFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.cache.id)")
        #expect(!(model.canClearSelection))
    }

    @Test
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

        #expect(publishedStates.count == 1)
        let state = try #require(publishedStates.first)
        #expect(state.focusedNodeID == fixture.cache.id)
        #expect(state.selectedNodeID == nil)
        #expect(state.selectedAncestorIDs.isEmpty)
        #expect(state.tableNodes.map(\.id) == [fixture.cacheFile.id])
        #expect(state.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.cache.id)")
        #expect(state.focusBackStack == [fixture.root.id, fixture.docs.id])
        #expect(state.focusForwardStack.isEmpty)
    }

    @Test
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

        #expect(publishedStates.count == 1)
        let state = try #require(publishedStates.first)
        #expect(state.selectedNodeID == fixture.docs.id)
        #expect(state.focusedNodeID == fixture.docs.id)
        #expect(state.selectedAncestorIDs == Set([fixture.root.id, fixture.docs.id]))
        #expect(state.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(state.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.docs.id)")
        #expect(state.focusBackStack == [fixture.root.id])
        #expect(state.focusForwardStack.isEmpty)
    }

    @Test
    func testRevealFileFocusesContainingFolderAndSelectsNode() throws {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.reveal(nodeID: fixture.docFile.id)

        #expect(publishedStates.count == 1)
        let state = try #require(publishedStates.first)
        // Unlike selectAndFocus, reveal focuses the parent folder (docs) rather than the
        // file itself, so the file list shows the file among its siblings.
        #expect(state.focusedNodeID == fixture.docs.id)
        #expect(state.selectedNodeID == fixture.docFile.id)
        #expect(state.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(state.focusBackStack == [fixture.root.id])
    }

    @Test
    func testSelectionPublishesAncestorsWithoutReplacingTableState() throws {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        let initialTableContentID = model.tableContentID
        let initialTableNodeIDs = model.tableNodes.map(\.id)
        let initialTableStorageAddress = try #require(tableStorageAddress(of: model.state.tableNodes))
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.select(nodeID: fixture.docFile.id)

        #expect(publishedStates.count == 1)
        var state = try #require(publishedStates.first)
        #expect(state.selectedNodeID == fixture.docFile.id)
        #expect(state.selectedAncestorIDs == Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        #expect(state.tableContentID == initialTableContentID)
        #expect(state.tableNodes.map(\.id) == initialTableNodeIDs)
        #expect(tableStorageAddress(of: state.tableNodes) == initialTableStorageAddress)

        publishedStates.removeAll()
        model.clearSelection()

        #expect(publishedStates.count == 1)
        state = try #require(publishedStates.first)
        #expect(state.selectedNodeID == nil)
        #expect(state.selectedAncestorIDs.isEmpty)
        #expect(state.tableContentID == initialTableContentID)
        #expect(state.tableNodes.map(\.id) == initialTableNodeIDs)
        #expect(tableStorageAddress(of: state.tableNodes) == initialTableStorageAddress)
    }

    @Test
    func testTableStateTracksRootFallbackAndFocusedFiles() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.setFocusedNodeID(nil)

        #expect(model.focusedNodeID == nil)
        #expect(model.currentFocusNode?.id == fixture.root.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")

        let rootTableRevision = model.tableContentRevision
        model.setFocusedNodeID(fixture.rootFile.id)

        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentRevision == rootTableRevision)
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.rootFile.id)")

        model.setFocusedNodeID(fixture.docFile.id)

        #expect(model.focusedNodeID == fixture.docFile.id)
        #expect(model.currentFocusNode?.id == fixture.docFile.id)
        #expect(model.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.docFile.id)")
    }

    @Test
    func testDeferredTableMaterializationAdvancesContentRevision() {
        let fixture = makeNavigationFixture()
        let model = WorkspaceNavigationModel()

        model.updateScanContext(snapshot: fixture.snapshot, loadTableNodesImmediately: false)

        let deferredRevision = model.tableContentRevision
        #expect(model.tableNodes.isEmpty)
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")

        model.refreshTableNodesForCurrentContext()

        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentID == "\(fixture.snapshot.id.uuidString)|\(fixture.root.id)")
        #expect(model.tableContentRevision == deferredRevision + 1)

        model.refreshTableNodesForCurrentContext()

        #expect(model.tableContentRevision == deferredRevision + 1)

        model.updateScanContext(snapshot: fixture.snapshot, loadTableNodesImmediately: false)

        #expect(model.tableNodes.isEmpty)
        #expect(model.tableContentRevision == deferredRevision + 2)

        model.refreshTableNodesForCurrentContext()

        #expect(model.tableNodes.map(\.id) == [fixture.docs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableContentRevision == deferredRevision + 3)
    }

    @Test
    func testSameSnapshotIDNodeMetadataChangeAdvancesTableRevision() {
        let fixture = makeNavigationFixture()
        let model = makeConfiguredNavigationModel(fixture: fixture)
        let initialRevision = model.tableContentRevision
        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()

        let updatedDocFile = makeTestFileNode(
            id: fixture.docFile.id,
            name: fixture.docFile.name,
            size: 80
        )
        let updatedDocs = makeTestDirectoryNode(
            id: fixture.docs.id,
            name: fixture.docs.name,
            children: [updatedDocFile]
        )
        let updatedRoot = makeTestDirectoryNode(
            id: fixture.root.id,
            name: fixture.root.name,
            children: [updatedDocs, fixture.cache, fixture.rootFile]
        )
        let updatedStore = FileTreeStore(
            root: updatedRoot,
            childrenByID: [
                updatedRoot.id: [updatedDocs, fixture.cache, fixture.rootFile],
                updatedDocs.id: [updatedDocFile],
                fixture.cache.id: [fixture.cacheFile],
            ])
        let updatedSnapshot = ScanSnapshot(
            id: fixture.snapshot.id,
            target: fixture.snapshot.target,
            treeStore: updatedStore,
            startedAt: fixture.snapshot.startedAt,
            finishedAt: fixture.snapshot.finishedAt,
            scanWarnings: fixture.snapshot.scanWarnings,
            isComplete: fixture.snapshot.isComplete,
            scanOptions: fixture.snapshot.scanOptions,
            source: fixture.snapshot.source
        )

        model.$state
            .dropFirst()
            .sink { publishedStates.append($0) }
            .store(in: &cancellables)

        model.updateScanContext(snapshot: updatedSnapshot)

        #expect(publishedStates.count == 1)
        #expect(model.tableContentRevision == initialRevision + 1)
        #expect(model.tableNodes.map(\.id) == [updatedDocs.id, fixture.cache.id, fixture.rootFile.id])
        #expect(model.tableNodes.first?.allocatedSize == 80)
        #expect(model.currentFocusNode?.allocatedSize == updatedRoot.allocatedSize)
    }

    @Test
    func testReconcilingSnapshotReplacementClearsInvalidNavigationState() {
        let fixture = makeNavigationFixture()
        let replacement = makeNavigationFixture(rootID: "/replacement")
        let model = makeConfiguredNavigationModel(fixture: fixture)

        model.focus(nodeID: fixture.docs.id)
        model.select(nodeID: fixture.docFile.id)
        #expect(model.canNavigateBack)

        model.reconcileAfterSnapshotApplied(replacement.snapshot)

        #expect(model.focusedNodeID == replacement.root.id)
        #expect(model.currentFocusNode?.id == replacement.root.id)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedAncestorIDs.isEmpty)
        #expect(model.tableNodes.map(\.id) == [replacement.docs.id, replacement.cache.id, replacement.rootFile.id])
        #expect(model.tableContentID == "\(replacement.snapshot.id.uuidString)|\(replacement.root.id)")
        #expect(!(model.canNavigateBack))
        #expect(!(model.canNavigateForward))
        #expect(model.tableContentID.hasPrefix(replacement.snapshot.id.uuidString))
    }

    @Test
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

        #expect(publishedStates.count == 1)
        let state = try #require(publishedStates.first)
        #expect(state.snapshotID == replacement.snapshot.id)
        #expect(state.focusedNodeID == replacement.root.id)
        #expect(state.selectedNodeID == nil)
        #expect(state.selectedAncestorIDs.isEmpty)
        #expect(state.tableNodes.map(\.id) == [replacement.docs.id, replacement.cache.id, replacement.rootFile.id])
        #expect(state.tableContentID == "\(replacement.snapshot.id.uuidString)|\(replacement.root.id)")
        #expect(state.focusBackStack.isEmpty)
        #expect(state.focusForwardStack.isEmpty)
    }

    @Test
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
        model.refreshTableNodesForCurrentContext()

        #expect(publishedStates.isEmpty)
    }

    @Test
    func testAppModelRoutesNavigationActionsThroughNavigationState() {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)
        model.select(nodeID: fixture.docFile.id)
        model.focus(nodeID: fixture.docs.id)

        #expect(model.navigation.selectedNodeID == fixture.docFile.id)
        #expect(model.navigation.selectedNode?.id == fixture.docFile.id)
        #expect(model.navigation.selectedAncestorIDs == Set([fixture.root.id, fixture.docs.id, fixture.docFile.id]))
        #expect(model.navigation.selectedNodeParent?.id == fixture.docs.id)
        #expect(model.navigation.focusedNodeID == fixture.docs.id)
        #expect(model.navigation.currentFocusNode?.id == fixture.docs.id)
        #expect(model.navigation.breadcrumbNodes.map(\.id) == [fixture.root.id, fixture.docs.id])
        #expect(model.navigation.tableNodes.map(\.id) == [fixture.docFile.id])
        #expect(model.navigation.canClearSelection)
        #expect(model.navigation.canNavigateBack)
        #expect(model.navigation.tableContentID.hasPrefix(fixture.snapshot.id.uuidString))

        model.select(nodeID: "/missing")
        #expect(model.navigation.selectedNodeID == nil)

        model.select(nodeID: fixture.docFile.id)
        model.navigation.setFocusedNodeID(fixture.cache.id)
        #expect(model.navigation.focusedNodeID == fixture.cache.id)
        #expect(model.navigation.selectedNodeID == nil)

        model.navigation.setFocusedNodeID("/missing")
        #expect(model.navigation.focusedNodeID == fixture.cache.id)

        model.navigateBack()
        #expect(model.navigation.focusedNodeID == fixture.root.id)

        model.focus(nodeID: fixture.docs.id)
        model.navigateToParent()
        #expect(model.navigation.focusedNodeID == fixture.root.id)
    }

    @Test
    func testAppModelDeferredSelectionPublishesAfterViewUpdate() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docFile.id)

        #expect(model.navigation.selectedNodeID == nil)

        try await waitUntil("deferred selection") {
            model.navigation.selectedNodeID == fixture.docFile.id
        }
    }

    @Test
    func testAppModelDeferredSelectAndFocusKeepsZoomedSelection() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docs.id)
        model.selectAndFocusAfterViewUpdate(nodeID: fixture.docs.id)

        #expect(model.navigation.selectedNodeID == nil)
        #expect(model.navigation.focusedNodeID == fixture.root.id)

        try await waitUntil("deferred select and focus") {
            model.navigation.selectedNodeID == fixture.docs.id && model.navigation.focusedNodeID == fixture.docs.id
        }
    }

    @Test
    func testAppModelDirectNavigationCancelsDeferredSelection() async throws {
        let fixture = makeNavigationFixture()
        let model = AppModel(dependencies: makeNavigationAppDependencies())

        model.scanState.replaceCurrentSnapshot(fixture.snapshot)
        model.navigation.reconcileAfterSnapshotApplied(fixture.snapshot)

        model.selectAfterViewUpdate(nodeID: fixture.docFile.id)
        model.clearSelection()

        try await Task.sleep(for: .milliseconds(40))

        #expect(model.navigation.selectedNodeID == nil)
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
        preferences: TestAppPreferencesStore(),
        recentTargets: RecentTargetStore(
            persistence: TestRecentTargetPersistence(),
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
    let store = FileTreeStore(
        root: root,
        childrenByID: [
            root.id: [docs, cache, rootFile],
            docs.id: [docFile],
            cache.id: [cacheFile],
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
