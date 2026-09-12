import Foundation
import Testing

@testable import RadixCore

@MainActor
struct DiskMapFreeSpaceVisualizationTests {
    @Test
    func testVolumeRootAddsFreeSpaceUsingAvailableCapacityDenominator() throws {
        let used = makeTestFileNode(id: "/volume/used.bin", name: "used.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [used])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [used]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )

        let input = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )
        let largerFreeSpaceInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 80
        )
        let segments = SunburstLayout.segments(in: input.treeStore, rootID: input.rootNode.id, depthLimit: 1)
        let freeSegment = try #require(segments.first { DiskMapFreeSpaceVisualization.isFreeSpaceNodeID($0.nodeID) })
        let usedSegment = try #require(segments.first { $0.nodeID == root.id })
        let largerFreeSpaceUsedSegment = try #require(
            SunburstLayout.segments(
                in: largerFreeSpaceInput.treeStore,
                rootID: largerFreeSpaceInput.rootNode.id,
                depthLimit: 1
            )
            .first { $0.nodeID == root.id })

        #expect(input.rootNode.allocatedSize == 100)
        #expect(usedSegment.totalSize == 60)
        #expect(usedSegment.colorToken.role == .normal)
        #expect(usedSegment.colorToken.branchIndex == 0)
        #expect(usedSegment.colorToken.branchCount == 1)
        #expect(
            SunburstColorResolver.components(for: usedSegment.colorToken)
                == SunburstColorResolver.components(for: largerFreeSpaceUsedSegment.colorToken))
        #expect(freeSegment.label == "Free Space")
        #expect(freeSegment.totalSize == 40)
        #expect(freeSegment.colorToken.role == .freeSpace)
        #expect(abs((segmentFraction(freeSegment)) - (0.4)) <= 0.0001)
        #expect(snapshot.treeStore.node(id: freeSegment.nodeID) == nil)
    }

    @Test
    func testFreeSpaceOnlyAppliesToFocusedVolumeRoot() {
        let file = makeTestFileNode(id: "/folder/file.txt", name: "file.txt", size: 10)
        let folderRoot = makeTestDirectoryNode(id: "/folder", name: "folder", children: [file])
        let folderStore = FileTreeStore(root: folderRoot, childrenByID: [folderRoot.id: [file]])
        let folderSnapshot = makeTestSnapshot(root: folderRoot, store: folderStore)

        let folderInput = DiskMapFreeSpaceVisualization.input(
            snapshot: folderSnapshot,
            focusNode: folderRoot,
            showFreeSpace: true,
            availableCapacity: 90
        )

        #expect(folderInput.rootNode.id == folderRoot.id)
        #expect(folderInput.rootNode.allocatedSize == folderRoot.allocatedSize)

        let child = makeTestDirectoryNode(id: "/volume/child", name: "child", children: [file])
        let volumeRoot = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [child])
        let volumeStore = FileTreeStore(root: volumeRoot, childrenByID: [volumeRoot.id: [child]])
        let volumeSnapshot = makeTestSnapshot(
            target: ScanTarget(url: volumeRoot.url, kind: .volume),
            root: volumeRoot,
            store: volumeStore
        )

        let focusedChildInput = DiskMapFreeSpaceVisualization.input(
            snapshot: volumeSnapshot,
            focusNode: child,
            showFreeSpace: true,
            availableCapacity: 90
        )

        #expect(focusedChildInput.rootNode.id == child.id)
        #expect(
            !(focusedChildInput.treeStore.children(of: focusedChildInput.rootNode.id).contains {
                DiskMapFreeSpaceVisualization.isFreeSpaceNodeID($0.id)
            }))
        #expect(!(DiskMapFreeSpaceVisualization.isFreeSpaceNodeID("/tmp/file#radix-free-space")))
    }

    @Test
    func testVisualizationInputTracksBaseTreeContentID() {
        let used = makeTestFileNode(id: "/volume/used.bin", name: "used.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [used])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [used]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )

        let firstInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )
        let repeatedInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )

        #expect(firstInput.treeContentID == snapshot.treeStore.contentID)
        #expect(repeatedInput.treeContentID == firstInput.treeContentID)

        let resizedUsed = makeTestFileNode(id: used.id, name: used.name, size: 90)
        let updatedRoot = makeTestDirectoryNode(id: root.id, name: root.name, children: [resizedUsed])
        let updatedStore = FileTreeStore(root: updatedRoot, childrenByID: [updatedRoot.id: [resizedUsed]])
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
        let updatedInput = DiskMapFreeSpaceVisualization.input(
            snapshot: updatedSnapshot,
            focusNode: updatedRoot,
            showFreeSpace: true,
            availableCapacity: 40
        )

        #expect(updatedInput.treeContentID != firstInput.treeContentID)
        #expect(updatedInput.treeContentID == updatedSnapshot.treeStore.contentID)
    }

    @Test
    func testFreeSpaceNodeCannotBecomeSelectionOrFileActionTarget() throws {
        let used = makeTestFileNode(id: "/volume/used.bin", name: "used.bin", size: 60)
        let root = makeTestDirectoryNode(id: "/volume", name: "Volume", children: [used])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [used]])
        let snapshot = makeTestSnapshot(
            target: ScanTarget(url: root.url, kind: .volume),
            root: root,
            store: store
        )
        let input = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: true,
            availableCapacity: 40
        )
        let freeNode = try #require(
            input.treeStore.children(of: input.rootNode.id).first {
                DiskMapFreeSpaceVisualization.isFreeSpaceNodeID($0.id)
            })

        #expect(!(freeNode.supportsFileActions))
        #expect(
            freeNode.actionAvailability(activeTarget: snapshot.target)
                == FileNodeActionAvailability(
                    canOpen: false,
                    canPreviewWithQuickLook: false,
                    canRevealInFinder: false,
                    canCopyPath: false,
                    canMoveToTrash: false
                ))

        let navigation = WorkspaceNavigationModel()
        navigation.updateScanContext(snapshot: snapshot)
        navigation.select(nodeID: freeNode.id)

        #expect(navigation.selectedNodeID == nil)
        #expect(navigation.selectedNodeIDs.isEmpty)
    }

    private func segmentFraction(_ segment: SunburstSegment) -> Double {
        (segment.endAngle.radians - segment.startAngle.radians) / (.pi * 2)
    }
}
