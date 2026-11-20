import Foundation
import Testing

@testable import RadixCore

struct DiscardPileVisualizationOverlayTests {
    @Test
    func testQueuedRootAndRenderedDescendantsRemainActionable() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.folder.id],
            treeStore: fixture.store
        )

        #expect(overlay.queuedNodeIDs == [fixture.folder.id, fixture.child.id])
        #expect(overlay.queuedRootNodeIDs == [fixture.folder.id])
        #expect(overlay.containingQueuedNodeIDs.isEmpty)
        #expect(overlay.role(for: fixture.folder.id) == .queuedRoot)
        #expect(overlay.role(for: fixture.child.id) == .queuedDescendant)
        #expect(overlay.role(for: fixture.sibling.id) == nil)
        #expect(overlay.allowsChartNodeAction(for: fixture.folder.id))
        #expect(overlay.allowsChartNodeAction(for: fixture.child.id))
        #expect(overlay.allowsChartNodeAction(for: fixture.sibling.id))
    }

    @Test
    func testUnrenderedQueuedItemMarksOnlyItsNearestRenderedAncestor() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.root.id, fixture.folder.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        #expect(overlay.queuedNodeIDs.isEmpty)
        #expect(overlay.containingQueuedNodeIDs == [fixture.folder.id])
        #expect(overlay.role(for: fixture.folder.id) == .containsQueuedItem)
        #expect(overlay.role(for: fixture.root.id) == nil)
    }

    @Test
    func testTopmostRenderedDescendantsBecomeVisualRootsWhenQueuedRootIsNotRendered() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.root.id],
            treeStore: fixture.store
        )

        #expect(overlay.queuedRootNodeIDs == [fixture.folder.id, fixture.sibling.id])
        #expect(overlay.role(for: fixture.folder.id) == .queuedRoot)
        #expect(overlay.role(for: fixture.child.id) == .queuedDescendant)
        #expect(overlay.role(for: fixture.sibling.id) == .queuedRoot)
    }

    @MainActor
    @Test
    func testRootLevelSunburstAggregateMarksQueuedGroupedItem() async throws {
        let fixture = makeAggregateFixture()
        let tree = DiskMapTreeStore(fixture.store)
        let model = SunburstChartModel()
        _ = await model.loadLayout(
            treeStore: tree,
            rootID: fixture.root.id,
            depthLimit: 1,
            layoutID: "layout"
        )
        let aggregate = try #require(model.renderedSegments.first(where: \.isAggregate))
        let overlay = model.discardPileOverlay(
            queuedRootNodeIDs: [fixture.tiny.id],
            movingToTrashRootNodeIDs: [],
            treeStore: tree
        )

        #expect(overlay.role(for: aggregate.nodeID, aggregateContainerNodeID: aggregate.containerNodeID)
            == .containsQueuedItem)
    }

    @MainActor
    @Test
    func testRootLevelTreemapAggregateMarksQueuedGroupedItem() async throws {
        let fixture = makeAggregateFixture()
        let tree = DiskMapTreeStore(fixture.store)
        let model = TreemapChartModel()
        _ = await model.loadLayout(
            treeStore: tree,
            rootID: fixture.root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300),
            layoutID: "layout"
        )
        let aggregate = try #require(model.renderedSegments.first(where: \.isAggregate))
        let overlay = model.discardPileOverlay(
            queuedRootNodeIDs: [fixture.tiny.id],
            movingToTrashRootNodeIDs: [],
            treeStore: tree
        )

        #expect(overlay.role(for: aggregate.nodeID, aggregateContainerNodeID: aggregate.containerNodeID)
            == .containsQueuedItem)
    }

    @Test
    func testQueuedItemsOutsideRenderedSubtreeProduceNoMarks() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.sibling.id],
            queuedRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        #expect(overlay == .empty)
    }

    @Test
    func testQueuedAncestorTakesPrecedenceOverContainedIndicator() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id],
            queuedRootNodeIDs: [fixture.folder.id, fixture.child.id],
            treeStore: fixture.store
        )

        #expect(overlay.role(for: fixture.folder.id) == .queuedRoot)
        #expect(overlay.containingQueuedNodeIDs.isEmpty)
    }

    @Test
    func testMovingToTrashStateRemainsDistinctFromDiscardPileState() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id, fixture.sibling.id],
            queuedRootNodeIDs: [fixture.sibling.id],
            movingToTrashRootNodeIDs: [fixture.folder.id],
            treeStore: fixture.store
        )

        #expect(overlay.role(for: fixture.folder.id) == .movingToTrashRoot)
        #expect(overlay.role(for: fixture.child.id) == .movingToTrashDescendant)
        #expect(overlay.role(for: fixture.sibling.id) == .queuedRoot)
        #expect(overlay.role(for: fixture.folder.id)?.statusText == "Moving to Trash")
        #expect(overlay.role(for: fixture.sibling.id)?.statusText == "In Discard Pile")
        #expect(overlay.isMovingToTrash(fixture.child.id))
        #expect(!(overlay.allowsChartNodeAction(for: fixture.child.id)))
    }

    @Test
    func testMixedMembershipsResolveAtDifferentAncestorDepths() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id],
            queuedRootNodeIDs: [fixture.child.id],
            movingToTrashRootNodeIDs: [fixture.folder.id],
            treeStore: fixture.store
        )

        #expect(overlay.queuedNodeIDs == [fixture.child.id])
        #expect(overlay.movingToTrashNodeIDs == [fixture.folder.id, fixture.child.id])
        #expect(overlay.role(for: fixture.child.id) == .movingToTrashDescendant)

        let reversedMemberships = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.folder.id, fixture.child.id],
            queuedRootNodeIDs: [fixture.folder.id],
            movingToTrashRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        #expect(reversedMemberships.queuedNodeIDs == [fixture.folder.id, fixture.child.id])
        #expect(reversedMemberships.movingToTrashNodeIDs == [fixture.child.id])
        #expect(reversedMemberships.role(for: fixture.child.id) == .movingToTrashRoot)
    }

    @Test
    func testUnrenderedMovingItemMarksNearestRenderedContainer() {
        let fixture = makeFixture()
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: [fixture.root.id, fixture.folder.id, fixture.sibling.id],
            movingToTrashRootNodeIDs: [fixture.child.id],
            treeStore: fixture.store
        )

        #expect(overlay.movingToTrashNodeIDs.isEmpty)
        #expect(overlay.containingMovingToTrashNodeIDs == [fixture.folder.id])
        #expect(overlay.role(for: fixture.folder.id) == .containsMovingToTrashItem)
    }

    @MainActor
    @Test
    func testMarksTrackQueueAndTrashChangesOnTheSameLayout() async {
        let fixture = makeFixture()
        let snapshot = makeTestSnapshot(root: fixture.root, store: fixture.store)
        func presentation(
            queued: Set<String> = [], moving: Set<String> = [], depth: Int = 2
        ) -> DiscardPileVisualizationPresentation {
            DiscardPileVisualizationPresentation(
                snapshot: snapshot, focusNode: fixture.root,
                showFreeSpace: false, availableCapacity: nil, maxRenderedDepth: depth,
                discardPileRootNodeIDs: queued, movingToTrashRootNodeIDs: moving
            )
        }

        let initial = presentation()
        let model = SunburstChartModel()
        _ = await model.loadLayout(
            treeStore: initial.visualizationInput.treeStore, rootID: initial.visualizationInput.rootNode.id,
            depthLimit: 2, layoutID: initial.layoutID
        )
        let cases: [(DiscardPileVisualizationPresentation, DiscardPileVisualizationOverlayRole?)] = [
            (presentation(queued: [fixture.folder.id]), .queuedDescendant),
            (presentation(), nil),
            (presentation(moving: [fixture.folder.id]), .movingToTrashDescendant),
        ]
        for (state, expectedRole) in cases {
            #expect(state.layoutID == initial.layoutID)
            let overlay = model.discardPileOverlay(
                queuedRootNodeIDs: state.discardPileRootNodeIDs,
                movingToTrashRootNodeIDs: state.movingToTrashRootNodeIDs,
                treeStore: state.visualizationInput.treeStore
            )
            #expect(overlay.role(for: fixture.child.id) == expectedRole)
        }
        #expect(presentation(depth: 3).layoutID != initial.layoutID)
    }

    private func makeFixture() -> (
        root: FileNodeRecord,
        folder: FileNodeRecord,
        child: FileNodeRecord,
        sibling: FileNodeRecord,
        store: FileTreeStore
    ) {
        let child = makeTestFileNode(
            id: "/root/folder/child.bin",
            name: "child.bin",
            size: 20
        )
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [child]
        )
        let sibling = makeTestFileNode(
            id: "/root/sibling.bin",
            name: "sibling.bin",
            size: 30
        )
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [folder, sibling]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [child],
            ]
        )
        return (root, folder, child, sibling, store)
    }

    private func makeAggregateFixture() -> (
        root: FileNodeRecord,
        tiny: FileNodeRecord,
        store: FileTreeStore
    ) {
        let large = makeTestFileNode(
            id: "/root/large.bin",
            name: "large.bin",
            size: 10_000
        )
        let tiny = makeTestFileNode(
            id: "/root/tiny-1.bin",
            name: "tiny-1.bin",
            size: 1
        )
        let otherTinyItems = (2...4).map { index in
            makeTestFileNode(
                id: "/root/tiny-\(index).bin",
                name: "tiny-\(index).bin",
                size: 1
            )
        }
        let children = [large, tiny] + otherTinyItems
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: children
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: children]
        )
        return (root, tiny, store)
    }
}
