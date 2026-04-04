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

    private func makeNode(
        id: String,
        isDirectory: Bool,
        isSynthetic: Bool,
        isAccessible: Bool
    ) -> FileNode {
        FileNode(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent.isEmpty ? id : URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: 64,
            logicalSize: 64,
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
