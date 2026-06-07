import XCTest
@testable import RadixCore

final class FileTreeStoreTests: XCTestCase {
    func testPathAndAncestorLookup() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [leaf],
        ])

        XCTAssertEqual(store.path(to: leaf.id).map(\.name), ["root", "folder", "file.txt"])
        XCTAssertTrue(store.isAncestor(root.id, of: leaf.id))
        XCTAssertTrue(store.isAncestor(folder.id, of: leaf.id))
        XCTAssertFalse(store.isAncestor(leaf.id, of: folder.id))
        XCTAssertEqual(store.parent(of: leaf.id)?.id, folder.id)
    }

    func testIndexedNodeIDsPreserveTraversalOrderAndCanExcludeRoot() {
        let first = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 12)
        let nested = makeFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [first, folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [first, folder],
            folder.id: [nested],
        ])

        XCTAssertEqual(store.indexedNodeIDs(), ["/root", "/root/a.txt", "/root/folder", "/root/folder/b.txt"])
        XCTAssertEqual(store.indexedNodeIDs(excludingRoot: true), ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])
    }

    func testEmptyStoreFallsBackToRootPath() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root)

        XCTAssertEqual(store.path(to: nil).map(\.id), [root.id])
        XCTAssertEqual(store.children(of: nil).count, 0)
    }

    func testUnknownNodeFallsBackToRootPath() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        XCTAssertEqual(store.path(to: "/root/missing").map(\.id), [root.id])
        XCTAssertNil(store.node(id: "/root/missing"))
        XCTAssertNil(store.parent(of: "/root/missing"))
    }

    func testChildrenPrefixPreservesOrderAndLimit() {
        let children = (0..<6).map { index in
            makeFileNode(id: "/root/item-\(index).txt", name: "item-\(index).txt", size: Int64(10 - index))
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        XCTAssertEqual(
            store.childrenPrefix(of: root.id, maxCount: 3).map(\.id),
            children.prefix(3).map(\.id)
        )
        XCTAssertEqual(store.childrenPrefix(of: root.id, maxCount: 99).count, children.count)
        XCTAssertTrue(store.childrenPrefix(of: root.id, maxCount: 0).isEmpty)
    }

    func testDeepTreeIndexingAndAggregateStatsAvoidRecursiveTraversal() {
        let depth = 5_000
        let leafID = "/root/file.txt"
        let leaf = makeFileNode(id: leafID, name: "file.txt", size: 12)
        var nodesByID = [leaf.id: leaf]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var childID = leaf.id

        for level in stride(from: depth, through: 1, by: -1) {
            let nodeID = "/root/level-\(level)"
            let directory = makeDirectoryNode(
                id: nodeID,
                name: "level-\(level)",
                children: [nodesByID[childID]!]
            )
            nodesByID[nodeID] = directory
            childIDsByID[nodeID] = [childID]
            parentIDByID[childID] = nodeID
            childID = nodeID
        }

        let root = makeDirectoryNode(id: "/root", name: "root", children: [nodesByID[childID]!])
        nodesByID[root.id] = root
        childIDsByID[root.id] = [childID]
        parentIDByID[childID] = root.id

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )

        XCTAssertEqual(store.path(to: leafID).count, depth + 2)
        XCTAssertEqual(store.aggregateStats.directoryCount, depth + 1)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }
}

private func makeFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeDirectoryNode(id: String, name: String, children: [FileNodeRecord]) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
