import Foundation
import Testing

@testable import RadixCore

struct InspectorSelectionSummaryTests {
    @Test
    func testSiblingSelectionsAreAggregated() {
        let first = makeTestFileNode(id: "/root/first.txt", name: "first.txt", size: 12)
        let second = makeTestFileNode(id: "/root/second.txt", name: "second.txt", size: 5)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])

        let summary = InspectorSelectionSummary(
            selectedNodes: [first, second],
            fileTreeStore: store
        )

        #expect(summary.selectedCount == 2)
        #expect(summary.topLevelSelectedNodes.map(\.id) == [first.id, second.id])
        #expect(summary.topLevelSelectedCount == 2)
        #expect(summary.allocatedSize == 17)
        #expect(!(summary.containsOverlappingSelections))
        #expect(summary.missingSelectedNodeCount == 0)
    }

    @Test
    func testNestedSelectionIsCountedOnce() {
        let nestedFile = makeTestFileNode(
            id: "/root/folder/nested.txt",
            name: "nested.txt",
            size: 20
        )
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [nestedFile]
        )
        let sibling = makeTestFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 5)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [nestedFile],
            ])

        let summary = InspectorSelectionSummary(
            selectedNodes: [nestedFile, folder, sibling],
            fileTreeStore: store
        )

        #expect(summary.selectedCount == 3)
        #expect(summary.topLevelSelectedNodes.map(\.id) == [folder.id, sibling.id])
        #expect(summary.topLevelSelectedCount == 2)
        #expect(summary.allocatedSize == 25)
        #expect(summary.containsOverlappingSelections)
        #expect(summary.missingSelectedNodeCount == 0)
    }

    @Test
    func testMissingSelectionIsNotReportedAsOverlap() {
        let present = makeTestFileNode(id: "/root/present.txt", name: "present.txt", size: 12)
        let stale = makeTestFileNode(id: "/root/stale.txt", name: "stale.txt", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [present])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [present]])

        let summary = InspectorSelectionSummary(
            selectedNodes: [present, stale],
            fileTreeStore: store
        )

        #expect(summary.selectedCount == 2)
        #expect(summary.topLevelSelectedNodes.map(\.id) == [present.id])
        #expect(summary.topLevelSelectedCount == 1)
        #expect(summary.allocatedSize == present.allocatedSize)
        #expect(!(summary.containsOverlappingSelections))
        #expect(summary.missingSelectedNodeCount == 1)
    }

    @Test
    func testSelectionPresentationCountsKindsAndOrdersLargestItemsFirst() {
        let file = makeTestFileNode(id: "/root/file.txt", name: "file.txt", size: 8)
        let folderChild = makeTestFileNode(id: "/root/folder/child.txt", name: "child.txt", size: 20)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [folderChild]
        )
        let packageChild = makeTestFileNode(id: "/root/App.app/item", name: "item", size: 12)
        let package = makeTestDirectoryNode(
            id: "/root/App.app",
            name: "App.app",
            children: [packageChild],
            isPackage: true
        )

        let summary = InspectorSelectionSummary(
            selectedNodes: [file, package, folder],
            fileTreeStore: nil
        )

        #expect(summary.selectedFolderCount == 1)
        #expect(summary.selectedFileCount == 1)
        #expect(summary.selectedPackageCount == 1)
        #expect(summary.selectedStorageCategoryCount == 0)
        #expect(summary.selectedNodesByAllocatedSize.map(\.id) == [folder.id, package.id, file.id])
        #expect(summary.largestSelectedNodes(limit: 2).map(\.id) == [folder.id, package.id])
    }

    @Test
    func testSyntheticStorageAndSharedFilesHaveDistinctPresentationState() {
        let synthetic = makeTestFileNode(
            id: "/root/unattributed",
            name: "Unattributed",
            size: 30,
            isSynthetic: true
        )
        let clone = makeTestFileNode(
            id: "/root/clone.dat",
            name: "clone.dat",
            size: 12,
            cloneIdentity: CloneIdentity(device: 1, cloneID: 7)
        )

        let summary = InspectorSelectionSummary(
            selectedNodes: [synthetic, clone],
            fileTreeStore: nil
        )

        #expect(summary.selectedFileCount == 1)
        #expect(summary.selectedStorageCategoryCount == 1)
        #expect(summary.containsSharedStorageItems)
        #expect(summary.containsKnownClones)
    }
}
