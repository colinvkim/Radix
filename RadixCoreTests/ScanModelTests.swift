import XCTest
@testable import RadixCore

final class ScanModelTests: XCTestCase {
    func testSupportsMoveToTrashRejectsSyntheticNodesAndRootPath() {
        let rootNode = makeNode(id: "/", isDirectory: true, isSynthetic: false, isAccessible: true)
        let syntheticNode = makeNode(id: "/System & Unattributed", isDirectory: true, isSynthetic: true, isAccessible: true)
        let folderNode = makeNode(id: "/Users/example/Documents", isDirectory: true, isSynthetic: false, isAccessible: true)

        XCTAssertFalse(rootNode.supportsMoveToTrash)
        XCTAssertFalse(syntheticNode.supportsMoveToTrash)
        XCTAssertTrue(folderNode.supportsMoveToTrash)
    }

    func testAccessPresentationReflectsAccessibilityAndSyntheticState() {
        let readableNode = makeNode(id: "/Users/example/file.txt", isDirectory: false, isSynthetic: false, isAccessible: true)
        let limitedNode = makeNode(id: "/Users/example/private", isDirectory: true, isSynthetic: false, isAccessible: false)
        let syntheticNode = makeNode(id: "/System & Unattributed", isDirectory: true, isSynthetic: true, isAccessible: true)

        XCTAssertEqual(readableNode.accessDescription, "Readable")
        XCTAssertNil(readableNode.secondaryStatusText)

        XCTAssertEqual(limitedNode.accessDescription, "Limited")
        XCTAssertEqual(limitedNode.secondaryStatusText, "Limited access")

        XCTAssertEqual(syntheticNode.accessDescription, "Estimated")
        XCTAssertEqual(syntheticNode.secondaryStatusText, "Estimated from volume usage")
    }

    func testDirectoryBuilderAppliesCoreTreeInvariants() {
        let small = makeNode(id: "/root/a.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 10)
        let largeInaccessible = makeNode(id: "/root/z.txt", isDirectory: false, isSynthetic: false, isAccessible: false, allocatedSize: 20)
        let symlink = FileNode(
            id: "/root/link",
            url: URL(filePath: "/root/link"),
            name: "link",
            isDirectory: false,
            isSymbolicLink: true,
            allocatedSize: 5,
            logicalSize: 5,
            children: [],
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )

        let directory = FileNode.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [small, largeInaccessible, symlink],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(directory.children.map(\.name), ["z.txt", "a.txt", "link"])
        XCTAssertEqual(directory.allocatedSize, 35)
        XCTAssertEqual(directory.logicalSize, 35)
        XCTAssertEqual(directory.descendantFileCount, 2)
        XCTAssertFalse(directory.isAccessible)
        XCTAssertFalse(directory.isAutoSummarized)
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        isSynthetic: Bool,
        isAccessible: Bool,
        allocatedSize: Int64 = 64
    ) -> FileNode {
        FileNode(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent.isEmpty ? id : URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            children: [],
            descendantFileCount: isDirectory ? 0 : 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: isAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: false
        )
    }
}
