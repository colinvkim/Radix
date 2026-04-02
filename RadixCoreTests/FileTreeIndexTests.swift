import XCTest
@testable import RadixCore

final class FileTreeIndexTests: XCTestCase {
    func testPathAndAncestorLookup() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])

        let index = FileTreeIndex(root: root)

        XCTAssertEqual(index.path(to: leaf.id).map(\.name), ["root", "folder", "file.txt"])
        XCTAssertTrue(index.isAncestor(root.id, of: leaf.id))
        XCTAssertTrue(index.isAncestor(folder.id, of: leaf.id))
        XCTAssertFalse(index.isAncestor(leaf.id, of: folder.id))
        XCTAssertEqual(index.parent(of: leaf.id)?.id, folder.id)
    }

    func testEmptyIndexFallsBackToRootPath() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let index = FileTreeIndex(root: root)

        XCTAssertEqual(index.path(to: nil).map(\.id), [root.id])
        XCTAssertEqual(index.children(of: nil).count, 0)
    }
}

private func makeFileNode(id: String, name: String, size: Int64) -> FileNode {
    FileNode(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        children: [],
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true
    )
}

private func makeDirectoryNode(id: String, name: String, children: [FileNode]) -> FileNode {
    FileNode(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        children: children,
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: false,
        isAccessible: true
    )
}
