import Foundation
import Testing

@testable import RadixCore

struct FileNodeRecordTests {
    @Test
    func testDirectoryAggregatesMixedChildrenRegardlessOfOrder() {
        let file = makeTestFileNode(id: "/root/file", name: "file", size: 3)
            .replacingAllocatedSize(2)
        let directory = makeTestSummarizedDirectoryNode(
            id: "/root/directory", name: "directory", size: 7, descendantFileCount: 5
        )
        let symbolicLink = makeTestFileNode(
            id: "/root/link", name: "link", size: 11,
            isSymbolicLink: true, isAccessible: false
        )
        let synthetic = makeTestFileNode(
            id: "/root/synthetic", name: "synthetic", size: 13, isSynthetic: true
        )
        let children = [file, symbolicLink, directory, synthetic]

        for orderedChildren in [children, Array(children.reversed())] {
            let root = makeTestDirectoryNode(id: "/root", name: "root", children: orderedChildren)

            #expect(root.allocatedSize == 33)
            #expect(root.logicalSize == 34)
            #expect(root.descendantFileCount == 6)
            #expect(!(root.isAccessible))
            #expect(root.isSelfAccessible)
        }
    }

    @Test
    func testVolumeRootUsesVolumeKindWhileOrdinaryDirectoriesRemainFolders() {
        let volumeRoot = makeTestDirectoryNode(id: "/", name: "Macintosh HD", children: [])
        let volumeTarget = ScanTarget(url: volumeRoot.url, kind: .volume)
        let ordinaryFolder = makeTestDirectoryNode(id: "/Users", name: "Users", children: [])

        #expect(volumeRoot.itemKind(activeTarget: volumeTarget) == "Volume")
        #expect(ordinaryFolder.itemKind(activeTarget: volumeTarget) == "Folder")
        #expect(volumeRoot.itemKind(activeTarget: ScanTarget(url: volumeRoot.url, kind: .folder)) == "Folder")
    }

    @Test
    func testSyntheticVolumeVisualizationRootUsesVolumeKind() {
        let target = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .volume)
        let visualizationRoot = FileNodeRecord.directory(
            id: "/\u{0}radix-volume-capacity",
            url: target.url,
            name: "Macintosh HD",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        #expect(visualizationRoot.itemKind(activeTarget: target) == "Volume")
    }

    @Test
    func testSharedAPFSStorageStatusDistinguishesFullAndPartialClones() {
        let fullClone = makeTestFileNode(
            id: "/full.bin",
            name: "full.bin",
            cloneIdentity: CloneIdentity(device: 1, cloneID: 2),
            mayShareDataBlocks: true
        )
        let partialClone = makeTestFileNode(
            id: "/partial.bin",
            name: "partial.bin",
            mayShareDataBlocks: true
        )
        let regularFile = makeTestFileNode(id: "/regular.bin", name: "regular.bin")

        #expect(fullClone.secondaryStatusText == "APFS clone · shared storage")
        #expect(partialClone.secondaryStatusText == "May share APFS storage")
        #expect(fullClone.sharedStorageStatusText == "APFS clone · shared storage")
        #expect(partialClone.sharedStorageStatusText == "May share APFS storage")
        #expect(
            fullClone.sharedStorageDescription
                == "APFS lets files share storage, but Finder may show the full file size for every clone. Radix counts shared bytes once, so one file carries the allocated size and the others may show zero. That file is only an accounting representative, not an original. Deleting one clone may not free the displayed amount."
        )
        #expect(
            partialClone.sharedStorageDescription
                == "Parts of this file may share APFS storage. macOS does not expose enough information for Radix to calculate exact shared or reclaimable bytes."
        )
        #expect(regularFile.sharedStorageStatusText == nil)
        #expect(regularFile.sharedStorageDescription == nil)
    }

    @Test
    func testSharedStorageStatusRemainsAvailableWhenAccessStatusTakesPrecedence() {
        let inaccessibleClone = makeTestFileNode(
            id: "/inaccessible-clone.bin",
            name: "inaccessible-clone.bin",
            cloneIdentity: CloneIdentity(device: 1, cloneID: 2),
            mayShareDataBlocks: true,
            isAccessible: false
        )

        #expect(inaccessibleClone.secondaryStatusText == "Limited access")
        #expect(inaccessibleClone.sharedStorageStatusText == "APFS clone · shared storage")
        #expect(inaccessibleClone.sharedStorageDescription != nil)
    }
}
