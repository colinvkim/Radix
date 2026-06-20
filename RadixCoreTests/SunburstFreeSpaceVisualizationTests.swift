import XCTest
@testable import RadixCore

@MainActor
final class SunburstFreeSpaceVisualizationTests: XCTestCase {
    func testVolumeRootAddsFreeSpaceUsingAvailableCapacityDenominator() throws {
        let used = makeTestFileNode(id: "/volume/used.bin", name: "used.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [used])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [used]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )

        let input = SunburstFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )
        let segments = SunburstLayout.segments(in: input.treeStore, rootID: input.rootNode.id, depthLimit: 1)
        let freeSegment = try XCTUnwrap(segments.first { SunburstFreeSpaceVisualization.isFreeSpaceNodeID($0.nodeID) })
        let usedSegment = try XCTUnwrap(segments.first { $0.nodeID == root.id })

        XCTAssertEqual(input.rootNode.allocatedSize, 100)
        XCTAssertEqual(usedSegment.totalSize, 60)
        XCTAssertEqual(freeSegment.label, "Free Space")
        XCTAssertEqual(freeSegment.totalSize, 40)
        XCTAssertEqual(segmentFraction(freeSegment), 0.4, accuracy: 0.0001)
        XCTAssertNil(snapshot.treeStore.node(id: freeSegment.nodeID))
    }

    func testFreeSpaceOnlyAppliesToFocusedVolumeRoot() {
        let file = makeTestFileNode(id: "/folder/file.txt", name: "file.txt", size: 10)
        let folderRoot = makeTestDirectoryNode(id: "/folder", name: "folder", children: [file])
        let folderStore = FileTreeStore(root: folderRoot, childrenByID: [folderRoot.id: [file]])
        let folderSnapshot = makeTestSnapshot(root: folderRoot, store: folderStore)

        let folderInput = SunburstFreeSpaceVisualization.input(
            snapshot: folderSnapshot,
            focusNode: folderRoot,
            showFreeSpace: true,
            availableCapacity: 90
        )

        XCTAssertEqual(folderInput.rootNode.id, folderRoot.id)
        XCTAssertEqual(folderInput.rootNode.allocatedSize, folderRoot.allocatedSize)

        let child = makeTestDirectoryNode(id: "/volume/child", name: "child", children: [file])
        let volumeRoot = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [child])
        let volumeStore = FileTreeStore(root: volumeRoot, childrenByID: [volumeRoot.id: [child]])
        let volumeSnapshot = makeTestSnapshot(
            target: ScanTarget(url: volumeRoot.url, kind: .volume),
            root: volumeRoot,
            store: volumeStore
        )

        let focusedChildInput = SunburstFreeSpaceVisualization.input(
            snapshot: volumeSnapshot,
            focusNode: child,
            showFreeSpace: true,
            availableCapacity: 90
        )

        XCTAssertEqual(focusedChildInput.rootNode.id, child.id)
        XCTAssertNil(focusedChildInput.treeStore.nodesByID.keys.first {
            SunburstFreeSpaceVisualization.isFreeSpaceNodeID($0)
        })
        XCTAssertFalse(SunburstFreeSpaceVisualization.isFreeSpaceNodeID("/tmp/file#radix-free-space"))
    }

    func testFreeSpaceNodeCannotBecomeSelectionOrFileActionTarget() throws {
        let used = makeTestFileNode(id: "/volume/used.bin", name: "used.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [used])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [used]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )
        let input = SunburstFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )
        let freeNode = try XCTUnwrap(input.treeStore.nodesByID.values.first {
            SunburstFreeSpaceVisualization.isFreeSpaceNodeID($0.id)
        })

        XCTAssertFalse(freeNode.supportsFileActions)
        XCTAssertEqual(
            freeNode.actionAvailability(activeTarget: snapshot.target),
            FileNodeActionAvailability(
                canOpen: false,
                canPreviewWithQuickLook: false,
                canRevealInFinder: false,
                canCopyPath: false,
                canMoveToTrash: false
            )
        )

        let navigation = WorkspaceNavigationModel()
        navigation.updateScanContext(snapshot: snapshot)
        navigation.select(nodeID: freeNode.id)

        XCTAssertNil(navigation.selectedNodeID)
        XCTAssertTrue(navigation.selectedNodeIDs.isEmpty)
    }

    private func segmentFraction(_ segment: SunburstSegment) -> Double {
        (segment.endAngle.radians - segment.startAngle.radians) / (.pi * 2)
    }
}
