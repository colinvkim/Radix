import Foundation
import Testing

@testable import RadixCore

struct DiskMapColorBranchContextTests {
    @Test
    func testCancellationDuringGlobalColorEnumeration() throws {
        let children = (0..<10).map { makeTestFileNode(id: "/root/\($0)", name: "\($0)") }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        var checks = 0
        #expect(throws: CancellationError.self) {
            try DiskMapColorBranchContext(
                in: store, layoutRootID: root.id, layoutRootChildren: children,
                visibleNodeIDs: [children[0].id],
                cancellationCheck: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }
            )
        }
        #expect(checks == 4)
    }

    @Test
    func testCancellationDuringFocusedBranchAncestryWalk() throws {
        let file = makeTestFileNode(id: "/root/a/b/file", name: "file")
        let b = makeTestDirectoryNode(id: "/root/a/b", name: "b", children: [file])
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [b])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a])
        let tree = ChartReadProbe(FileTreeStore(root: root, childrenByID: [root.id: [a], a.id: [b], b.id: [file]]))
        var checks = 0
        #expect(throws: CancellationError.self) {
            try DiskMapColorBranchContext(
                in: tree, layoutRootID: file.id, layoutRootChildren: [],
                visibleNodeIDs: [file.id],
                cancellationCheck: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        }
        #expect(checks == 3)
        #expect(tree.childReadCount(for: root.id) == 0)
    }
}
