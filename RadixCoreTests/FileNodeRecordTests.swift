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
            #expect(!root.isAutoSummarized)
        }
    }

    @Test
    func testDirectoryClampsSignedSizesAndNonnegativeFileCount() {
        let positiveOverflow = makeTestDirectoryNode(
            id: "/positive",
            name: "positive",
            children: [
                makeTestFileNode(id: "/positive/a", name: "a", size: .max),
                makeTestFileNode(id: "/positive/b", name: "b", size: 1),
            ]
        )
        let negativeOverflow = makeTestDirectoryNode(
            id: "/negative",
            name: "negative",
            children: [
                makeTestFileNode(id: "/negative/a", name: "a", size: .min),
                makeTestFileNode(id: "/negative/b", name: "b", size: -1),
            ]
        )
        let countOverflow = makeTestDirectoryNode(
            id: "/count",
            name: "count",
            children: [
                makeTestSummarizedDirectoryNode(
                    id: "/count/summary", name: "summary", size: 0, descendantFileCount: .max
                ),
                makeTestFileNode(id: "/count/file", name: "file"),
            ]
        )

        #expect(positiveOverflow.allocatedSize == Int64.max)
        #expect(positiveOverflow.logicalSize == Int64.max)
        #expect(negativeOverflow.allocatedSize == Int64.min)
        #expect(negativeOverflow.logicalSize == Int64.min)
        #expect(countOverflow.descendantFileCount == Int.max)
    }

    @Test
    func testVolumeRootUsesVolumeKindWhileOrdinaryDirectoriesRemainFolders() {
        let volumeRoot = makeTestDirectoryNode(id: "/", name: "Macintosh HD", children: [])
        let volumeTarget = ScanTarget(url: volumeRoot.url, kind: .volume)
        let ordinaryFolder = makeTestDirectoryNode(id: "/Users", name: "Users", children: [])

        #expect(volumeRoot.itemKind(activeTarget: volumeTarget) == String(localized: "Volume"))
        #expect(ordinaryFolder.itemKind(activeTarget: volumeTarget) == String(localized: "Folder"))
        #expect(volumeRoot.itemKind(activeTarget: ScanTarget(url: volumeRoot.url, kind: .folder)) == String(localized: "Folder"))
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

        #expect(visualizationRoot.itemKind(activeTarget: target) == String(localized: "Volume"))
    }

    @Test(arguments: ["Excluded & Unattributed", "System & Unattributed", "Unrecognized synthetic name"])
    func testSyntheticDisplayNamesKeepStableStoredNames(name: String) {
        let synthetic = makeTestFileNode(id: "/synthetic", name: name, isSynthetic: true)
        let regular = makeTestFileNode(id: "/regular", name: name)
        let expected: String
        switch name {
        case "Excluded & Unattributed": expected = String(localized: "Excluded & Unattributed")
        case "System & Unattributed": expected = String(localized: "System & Unattributed")
        default: expected = name
        }

        #expect(synthetic.name == name)
        #expect(synthetic.displayName == expected)
        #expect(regular.displayName == name)
    }

    @Test(arguments: [
        IconCase(synthetic: true, symbolicLink: true, package: true, directory: true, expected: "internaldrive.fill"),
        IconCase(synthetic: false, symbolicLink: true, package: true, directory: true, expected: "arrowshape.turn.up.right.circle.fill"),
        IconCase(synthetic: false, symbolicLink: false, package: true, directory: true, expected: "shippingbox.fill"),
        IconCase(synthetic: false, symbolicLink: false, package: false, directory: true, expected: "folder.fill"),
        IconCase(synthetic: false, symbolicLink: false, package: false, directory: false, expected: "doc.fill"),
    ])
    func testSystemImagesRespectSyntheticLinkPackageAndDirectoryPrecedence(icon: IconCase) {
        let node = FileNodeRecord(
            id: "/node", url: URL(filePath: "/node"), name: "node",
            isDirectory: icon.directory, isSymbolicLink: icon.symbolicLink,
            allocatedSize: 0, logicalSize: 0, descendantFileCount: 0, lastModified: nil,
            isPackage: icon.package, isAccessible: true, isSelfAccessible: true,
            isSynthetic: icon.synthetic, isAutoSummarized: false
        )

        #expect(node.systemImageName == icon.expected)
    }

    struct IconCase: Sendable {
        let synthetic: Bool
        let symbolicLink: Bool
        let package: Bool
        let directory: Bool
        let expected: String
    }

    @Test
    func testSharedAPFSStorageStatusDistinguishesFullAndPartialClones() throws {
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

        let fullStatus = try #require(fullClone.sharedStorageStatusText)
        let partialStatus = try #require(partialClone.sharedStorageStatusText)
        let fullDescription = try #require(fullClone.sharedStorageDescription)
        let partialDescription = try #require(partialClone.sharedStorageDescription)
        #expect(!fullStatus.isEmpty && !partialStatus.isEmpty)
        #expect(fullStatus != partialStatus)
        #expect(fullClone.secondaryStatusText == fullStatus)
        #expect(partialClone.secondaryStatusText == partialStatus)
        #expect(!fullDescription.isEmpty && !partialDescription.isEmpty)
        #expect(fullDescription != partialDescription)
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

        #expect(inaccessibleClone.secondaryStatusText != nil)
        #expect(inaccessibleClone.sharedStorageStatusText != nil)
        #expect(inaccessibleClone.secondaryStatusText != inaccessibleClone.sharedStorageStatusText)
        #expect(inaccessibleClone.sharedStorageDescription != nil)
    }
}
