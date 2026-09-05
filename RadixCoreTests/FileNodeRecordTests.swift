import XCTest
@testable import RadixCore

final class FileNodeRecordTests: XCTestCase {
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

            XCTAssertEqual(root.allocatedSize, 33)
            XCTAssertEqual(root.logicalSize, 34)
            XCTAssertEqual(root.descendantFileCount, 6)
            XCTAssertFalse(root.isAccessible)
            XCTAssertTrue(root.isSelfAccessible)
        }
    }

    func testVolumeRootUsesVolumeKindWhileOrdinaryDirectoriesRemainFolders() {
        let volumeRoot = makeTestDirectoryNode(id: "/", name: "Macintosh HD", children: [])
        let volumeTarget = ScanTarget(url: volumeRoot.url, kind: .volume)
        let ordinaryFolder = makeTestDirectoryNode(id: "/Users", name: "Users", children: [])

        XCTAssertEqual(volumeRoot.itemKind(activeTarget: volumeTarget), "Volume")
        XCTAssertEqual(ordinaryFolder.itemKind(activeTarget: volumeTarget), "Folder")
        XCTAssertEqual(volumeRoot.itemKind(activeTarget: ScanTarget(url: volumeRoot.url, kind: .folder)), "Folder")
    }

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

        XCTAssertEqual(visualizationRoot.itemKind(activeTarget: target), "Volume")
    }

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

        XCTAssertEqual(fullClone.secondaryStatusText, "APFS clone · shared storage")
        XCTAssertEqual(partialClone.secondaryStatusText, "May share APFS storage")
        XCTAssertEqual(fullClone.sharedStorageStatusText, "APFS clone · shared storage")
        XCTAssertEqual(partialClone.sharedStorageStatusText, "May share APFS storage")
        XCTAssertEqual(
            fullClone.sharedStorageDescription,
            "APFS lets files share storage, but Finder may show the full file size for every clone. Radix counts shared bytes once, so one file carries the allocated size and the others may show zero. That file is only an accounting representative, not an original. Deleting one clone may not free the displayed amount."
        )
        XCTAssertEqual(
            partialClone.sharedStorageDescription,
            "Parts of this file may share APFS storage. macOS does not expose enough information for Radix to calculate exact shared or reclaimable bytes."
        )
        XCTAssertNil(regularFile.sharedStorageStatusText)
        XCTAssertNil(regularFile.sharedStorageDescription)
    }

    func testSharedStorageStatusRemainsAvailableWhenAccessStatusTakesPrecedence() {
        let inaccessibleClone = makeTestFileNode(
            id: "/inaccessible-clone.bin",
            name: "inaccessible-clone.bin",
            cloneIdentity: CloneIdentity(device: 1, cloneID: 2),
            mayShareDataBlocks: true,
            isAccessible: false
        )

        XCTAssertEqual(inaccessibleClone.secondaryStatusText, "Limited access")
        XCTAssertEqual(inaccessibleClone.sharedStorageStatusText, "APFS clone · shared storage")
        XCTAssertNotNil(inaccessibleClone.sharedStorageDescription)
    }
}
