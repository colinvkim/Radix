import Foundation
import Testing

@testable import RadixCore

struct DiscardPileVisualizationOverlayTests {
    @Test
    func testQueuedRootAndRenderedDescendantsAreMarkedWithoutChangingTree() {
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
        #expect(!(overlay.allowsChartNodeAction(for: fixture.folder.id)))
        #expect(!(overlay.allowsChartNodeAction(for: fixture.child.id)))
        #expect(overlay.allowsChartNodeAction(for: fixture.sibling.id))
        #expect(fixture.store.node(id: fixture.folder.id) != nil)
        #expect(fixture.store.node(id: fixture.child.id) != nil)
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

    @Test
    func testRootLevelSunburstAggregateMarksQueuedGroupedItem() throws {
        let fixture = makeAggregateFixture()
        let segments = SunburstLayout.segments(
            in: fixture.store,
            rootID: fixture.root.id,
            depthLimit: 1
        )
        let aggregateValue = (segments.first(where: \.isAggregate))
        let aggregate = try #require(aggregateValue)
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: Set(segments.compactMap(\.nodeID)),
            renderedAggregateContainerNodeIDs: Set(
                segments.lazy.filter(\.isAggregate).map(\.containerNodeID)
            ),
            queuedRootNodeIDs: [fixture.tiny.id],
            treeStore: fixture.store
        )

        #expect(aggregate.nodeID == nil)
        #expect(aggregate.containerNodeID == fixture.root.id)
        #expect(
            overlay.role(
                for: aggregate.nodeID,
                aggregateContainerNodeID: aggregate.containerNodeID
            ) == .containsQueuedItem)
    }

    @Test
    func testRootLevelTreemapAggregateMarksQueuedGroupedItem() throws {
        let fixture = makeAggregateFixture()
        let segments = TreemapLayout.segments(
            in: fixture.store,
            rootID: fixture.root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )
        let aggregateValue = (segments.first(where: \.isAggregate))
        let aggregate = try #require(aggregateValue)
        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: Set(segments.compactMap(\.nodeID)),
            renderedAggregateContainerNodeIDs: Set(
                segments.lazy.filter(\.isAggregate).map(\.containerNodeID)
            ),
            queuedRootNodeIDs: [fixture.tiny.id],
            treeStore: fixture.store
        )

        #expect(aggregate.nodeID == nil)
        #expect(aggregate.containerNodeID == fixture.root.id)
        #expect(
            overlay.role(
                for: aggregate.nodeID,
                aggregateContainerNodeID: aggregate.containerNodeID
            ) == .containsQueuedItem)
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
        #expect(!(overlay.isQueued(fixture.child.id)))
        #expect(!(overlay.allowsChartNodeAction(for: fixture.child.id)))
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

    @Test
    func testCacheAvoidsRebuildingOverlayUntilLayoutOrQueueChanges() {
        let fixture = makeFixture()
        let treeStore = DiskMapTreeStore(fixture.store)
        var cache = DiscardPileVisualizationOverlayCache()
        var renderedNodeIDBuildCount = 0
        let renderedNodeIDs = {
            renderedNodeIDBuildCount += 1
            return Set([fixture.folder.id, fixture.child.id, fixture.sibling.id])
        }

        let first = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.folder.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        let cached = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.folder.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        let updated = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [fixture.child.id],
            movingToTrashRootNodeIDs: [],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )

        #expect(first == cached)
        #expect(updated != first)
        #expect(renderedNodeIDBuildCount == 2)
    }

    @Test
    func testCacheRebuildsWhenMovingToTrashRootsChange() {
        let fixture = makeFixture()
        let treeStore = DiskMapTreeStore(fixture.store)
        var cache = DiscardPileVisualizationOverlayCache()
        var renderedNodeIDBuildCount = 0
        let renderedNodeIDs = {
            renderedNodeIDBuildCount += 1
            return Set([fixture.folder.id, fixture.child.id, fixture.sibling.id])
        }

        _ = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [],
            movingToTrashRootNodeIDs: [fixture.folder.id],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )
        _ = cache.overlay(
            renderedLayoutVersion: 1,
            queuedRootNodeIDs: [],
            movingToTrashRootNodeIDs: [fixture.sibling.id],
            treeStore: treeStore,
            renderedNodeIDs: renderedNodeIDs
        )

        #expect(renderedNodeIDBuildCount == 2)
    }

    @MainActor
    @Test
    func testConsecutiveQueueChangesPreserveLayoutIdentity() {
        let fixture = makeFixture()
        let snapshot = makeTestSnapshot(
            root: fixture.root,
            store: fixture.store
        )
        let queuedNodeIDSets: [Set<FileNodeRecord.ID>] = [
            [],
            [fixture.folder.id],
            [fixture.folder.id, fixture.sibling.id],
            [fixture.child.id, fixture.sibling.id],
        ]
        let presentations = queuedNodeIDSets.map { queuedNodeIDs in
            DiscardPileVisualizationPresentation(
                snapshot: snapshot,
                focusNode: fixture.root,
                showFreeSpace: false,
                availableCapacity: nil,
                maxRenderedDepth: 6,
                discardPileRootNodeIDs: queuedNodeIDs
            )
        }
        let changedDepthPresentation = DiscardPileVisualizationPresentation(
            snapshot: snapshot,
            focusNode: fixture.root,
            showFreeSpace: false,
            availableCapacity: nil,
            maxRenderedDepth: 7,
            discardPileRootNodeIDs: queuedNodeIDSets.last ?? []
        )
        let movingPresentation = DiscardPileVisualizationPresentation(
            snapshot: snapshot,
            focusNode: fixture.root,
            showFreeSpace: false,
            availableCapacity: nil,
            maxRenderedDepth: 6,
            discardPileRootNodeIDs: queuedNodeIDSets.last ?? [],
            movingToTrashRootNodeIDs: [fixture.folder.id]
        )

        var lastRequestedLayoutID: String?
        var layoutRequestCount = 0
        for presentation in presentations {
            if presentation.layoutID != lastRequestedLayoutID {
                lastRequestedLayoutID = presentation.layoutID
                layoutRequestCount += 1
            }
        }

        #expect(layoutRequestCount == 1)
        #expect(presentations.map(\.discardPileRootNodeIDs) == queuedNodeIDSets)
        #expect(
            presentations.allSatisfy {
                $0.visualizationInput.treeContentID == fixture.store.contentID
            })
        #expect(changedDepthPresentation.layoutID != presentations.last?.layoutID)
        #expect(movingPresentation.layoutID == presentations.last?.layoutID)
        #expect(movingPresentation.movingToTrashRootNodeIDs == [fixture.folder.id])
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
