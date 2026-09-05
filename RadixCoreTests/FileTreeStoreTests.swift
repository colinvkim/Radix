import XCTest
@testable import RadixCore

final class FileTreeStoreTests: XCTestCase {
    func testRepairingMaterializedDirectoryTotalsSaturatesOverflow() {
        let first = makeFileNode(id: "/root/first.bin", name: "first.bin", size: .max)
        let second = makeFileNode(id: "/root/second.bin", name: "second.bin", size: 1)
        let staleRoot = makeDirectoryNode(id: "/root", name: "root", children: [])

        let store = FileTreeStore(
            rootID: staleRoot.id,
            nodesByID: [
                staleRoot.id: staleRoot,
                first.id: first,
                second.id: second,
            ],
            childIDsByID: [staleRoot.id: [first.id, second.id]]
        )

        XCTAssertEqual(store.root.allocatedSize, Int64.max)
        XCTAssertEqual(store.root.logicalSize, Int64.max)
        XCTAssertEqual(store.root.descendantFileCount, 2)
    }

    func testComputedAggregateFileCountSaturatesOverflow() {
        let summarized = FileNodeRecord(
            id: "/root/summarized",
            url: URL(filePath: "/root/summarized", directoryHint: .isDirectory),
            name: "summarized",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: .max,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let file = makeFileNode(id: "/root/file.bin", name: "file.bin", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarized, file]])

        XCTAssertEqual(store.aggregateStats.fileCount, Int.max)
    }

    func testComputedAggregateCountsHybridPackageSummaryOnce() {
        let summarizedPackage = FileNodeRecord(
            id: "/root/Hybrid.pkg",
            url: URL(filePath: "/root/Hybrid.pkg", directoryHint: .isDirectory),
            name: "Hybrid.pkg",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 7,
            lastModified: nil,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )

        let store = FileTreeStore(root: summarizedPackage)

        XCTAssertEqual(store.aggregateStats.fileCount, 7)
        XCTAssertEqual(store.aggregateStats.directoryCount, 1)
    }

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

    func testTopLevelNodeIDsDropsDescendantsOfQueuedParents() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        XCTAssertEqual(
            store.topLevelNodeIDs(from: [leaf.id, folder.id, sibling.id, folder.id]),
            [folder.id, sibling.id]
        )
        XCTAssertTrue(store.isNodeOrDescendant(leaf.id, of: [folder.id]))
        XCTAssertFalse(store.isNodeOrDescendant(sibling.id, of: [folder.id]))
    }

    func testPreparedNodeSetPreservesMissingSiblingAndNestedSemantics() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        let prepared = store.preparedNodeSet(for: [folder.id, "/missing"])

        XCTAssertTrue(store.isNodeOrDescendant(folder.id, of: prepared))
        XCTAssertTrue(store.isNodeOrDescendant(leaf.id, of: prepared))
        XCTAssertFalse(store.isNodeOrDescendant(root.id, of: prepared))
        XCTAssertFalse(store.isNodeOrDescendant(sibling.id, of: prepared))
        XCTAssertFalse(store.isNodeOrDescendant("/missing", of: prepared))
    }

    func testTopLevelNodeIDsHandlesLargeSiblingBatchWithoutDroppingNodes() {
        let siblings = (0..<10_000).map { index in
            makeFileNode(
                id: "/root/file-\(index).txt",
                name: "file-\(index).txt",
                size: Int64(index)
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: siblings)
        let store = FileTreeStore(root: root, childrenByID: [root.id: siblings])

        let result = store.topLevelNodeIDs(from: siblings.map(\.id))

        XCTAssertEqual(result, siblings.map(\.id))
    }

    func testRemovingSubtreesRemovesQueuedParentsAndRepairsTotals() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [leaf],
        ])

        let updatedStore = store.removingSubtrees(rootedAt: [leaf.id, folder.id])

        XCTAssertNil(updatedStore.node(id: folder.id))
        XCTAssertNil(updatedStore.node(id: leaf.id))
        XCTAssertEqual(updatedStore.children(of: root.id).map(\.id), [sibling.id])
        XCTAssertEqual(updatedStore.root.allocatedSize, sibling.allocatedSize)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 1)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 1)
        XCTAssertEqual(updatedStore.aggregateStats.directoryCount, 1)
    }

    func testRemovingSubtreesRootReturnsEmptyRootStore() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        let updatedStore = store.removingSubtrees(rootedAt: [root.id])

        XCTAssertEqual(updatedStore.root.id, root.id)
        XCTAssertEqual(updatedStore.root.allocatedSize, 0)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 0)
        XCTAssertTrue(updatedStore.children(of: root.id).isEmpty)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 0)
    }

    func testRemovingSubtreesRepairsAndResortsSharedAncestors() {
        let retained = makeFileNode(id: "/root/folder/retained.bin", name: "retained.bin", size: 1)
        let removed = makeFileNode(id: "/root/folder/removed.bin", name: "removed.bin", size: 99)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [removed, retained])
        let sibling = makeFileNode(id: "/root/sibling.bin", name: "sibling.bin", size: 50)
        let unrelated = makeFileNode(id: "/root/unrelated.bin", name: "unrelated.bin", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling, unrelated])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling, unrelated],
            folder.id: [removed, retained],
        ])

        let updatedStore = store.removingSubtrees(rootedAt: [removed.id, unrelated.id])

        XCTAssertEqual(updatedStore.children(of: folder.id).map(\.id), [retained.id])
        XCTAssertEqual(updatedStore.children(of: root.id).map(\.id), [sibling.id, folder.id])
        XCTAssertEqual(
            updatedStore.indexedNodeIDs(),
            [root.id, sibling.id, folder.id, retained.id]
        )
        XCTAssertEqual(updatedStore.node(id: folder.id)?.allocatedSize, 1)
        XCTAssertEqual(updatedStore.root.allocatedSize, 51)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 51)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 2)
    }

    func testLogicalScopeRemovalRepairsOrderAndTraversal() throws {
        let retained = makeFileNode(id: "/root/folder/retained.bin", name: "retained.bin", size: 1)
        let removed = makeFileNode(id: "/root/folder/removed.bin", name: "removed.bin", size: 99)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [removed, retained])
        let sibling = makeFileNode(id: "/root/sibling.bin", name: "sibling.bin", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [removed, retained],
        ])
        let scope = try XCTUnwrap(store.logicalScope(rootedAt: root.id))
        let materializedScope = try scope.materialized(cancellationCheck: {})

        let expected = try XCTUnwrap(materializedScope.removingSubtree(id: removed.id))
        let updatedStore = try XCTUnwrap(scope.removingSubtree(id: removed.id))

        assertEquivalent(updatedStore, expected)
        XCTAssertEqual(updatedStore.childIDs(of: root.id), [sibling.id, folder.id])
        XCTAssertEqual(
            updatedStore.indexedNodeIDs(),
            [root.id, sibling.id, folder.id, retained.id]
        )
    }

    func testRemovingSubtreesResortsMultipleChangedBranches() {
        let firstRetained = makeFileNode(
            id: "/root/first/retained.bin",
            name: "retained.bin",
            size: 10
        )
        let firstRemoved = makeFileNode(
            id: "/root/first/removed.bin",
            name: "removed.bin",
            size: 90
        )
        let secondRetained = makeFileNode(
            id: "/root/second/retained.bin",
            name: "retained.bin",
            size: 80
        )
        let secondRemoved = makeFileNode(
            id: "/root/second/removed.bin",
            name: "removed.bin",
            size: 10
        )
        let first = makeDirectoryNode(
            id: "/root/first",
            name: "first",
            children: [firstRemoved, firstRetained]
        )
        let second = makeDirectoryNode(
            id: "/root/second",
            name: "second",
            children: [secondRetained, secondRemoved]
        )
        let sibling = makeFileNode(id: "/root/sibling.bin", name: "sibling.bin", size: 50)
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [first, second, sibling]
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [first, second, sibling],
            first.id: [firstRemoved, firstRetained],
            second.id: [secondRetained, secondRemoved],
        ])

        let updatedStore = store.removingSubtrees(
            rootedAt: [firstRemoved.id, secondRemoved.id]
        )

        XCTAssertEqual(updatedStore.childIDs(of: root.id), [second.id, sibling.id, first.id])
        XCTAssertEqual(updatedStore.root.allocatedSize, 140)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 3)
    }

    func testReplacingAllocatedSizesResortsManyChangedChildren() throws {
        let children = (0..<16).map { index in
            makeFileNode(
                id: "/root/item-\(index).bin",
                name: "item-\(index).bin",
                size: Int64(16 - index)
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let replacements = try children.enumerated().map { index, child in
            let nodeIndex = try XCTUnwrap(store.nodeIndex(id: child.id))
            return (nodeIndex: nodeIndex, allocatedSize: Int64(index + 1))
        }

        let updatedStore = try store.replacingAllocatedSizes(
            replacements,
            cancellationCheck: {}
        )

        XCTAssertEqual(updatedStore.childIDs(of: root.id), children.reversed().map(\.id))
        XCTAssertEqual(updatedStore.root.allocatedSize, store.root.allocatedSize)
    }

    func testReplacingOneAllocatedSizeReinsertsChangedChild() throws {
        let first = makeFileNode(id: "/root/first.bin", name: "first.bin", size: 40)
        let second = makeFileNode(id: "/root/second.bin", name: "second.bin", size: 30)
        let third = makeFileNode(id: "/root/third.bin", name: "third.bin", size: 20)
        let fourth = makeFileNode(id: "/root/fourth.bin", name: "fourth.bin", size: 10)
        let children = [first, second, third, fourth]
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let secondIndex = try XCTUnwrap(store.nodeIndex(id: second.id))
        let thirdIndex = try XCTUnwrap(store.nodeIndex(id: third.id))

        let movedLater = try store.replacingAllocatedSizes(
            [(nodeIndex: secondIndex, allocatedSize: 5)],
            cancellationCheck: {}
        )
        let movedEarlier = try store.replacingAllocatedSizes(
            [(nodeIndex: thirdIndex, allocatedSize: 50)],
            cancellationCheck: {}
        )

        XCTAssertEqual(movedLater.childIDs(of: root.id), [first.id, third.id, fourth.id, second.id])
        XCTAssertEqual(movedEarlier.childIDs(of: root.id), [third.id, first.id, second.id, fourth.id])
    }

    func testReplacingAllocatedSizesHonorsCancellationDuringDisplayOrdering() throws {
        let children = (0..<1_024).map { index in
            makeFileNode(
                id: "/root/item-\(index).bin",
                name: "item-\(index).bin",
                size: Int64(1_024 - index)
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let replacements = try children.enumerated().map { index, child in
            let nodeIndex = try XCTUnwrap(store.nodeIndex(id: child.id))
            return (nodeIndex: nodeIndex, allocatedSize: Int64(index + 1))
        }
        // The replacement, ancestor, traversal, and repair passes account for
        // four checks per child; this margin reaches the ordering merge.
        let cancellationCheckLimit = children.count * 4 + 12
        var cancellationCheckCount = 0

        XCTAssertThrowsError(try store.replacingAllocatedSizes(
            replacements,
            cancellationCheck: {
                cancellationCheckCount += 1
                if cancellationCheckCount == cancellationCheckLimit {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationCheckCount, cancellationCheckLimit)
        XCTAssertEqual(store.childIDs(of: root.id), children.map(\.id))
    }

    func testReplacingAllocatedSizesRepairsNestedAncestorRollups() throws {
        let a1 = makeFileNode(id: "/root/a/a1.bin", name: "a1.bin", size: 40)
        let a2 = makeFileNode(id: "/root/a/a2.bin", name: "a2.bin", size: 30)
        let dirA = makeDirectoryNode(id: "/root/a", name: "a", children: [a1, a2])
        let b1 = makeFileNode(id: "/root/b/b1.bin", name: "b1.bin", size: 10)
        let dirB = makeDirectoryNode(id: "/root/b", name: "b", children: [b1])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [dirA, dirB])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [dirA, dirB],
            dirA.id: [a1, a2],
            dirB.id: [b1]
        ])
        let a1Index = try XCTUnwrap(store.nodeIndex(id: a1.id))
        let b1Index = try XCTUnwrap(store.nodeIndex(id: b1.id))

        let updatedStore = try store.replacingAllocatedSizes(
            [
                (nodeIndex: a1Index, allocatedSize: 5),
                (nodeIndex: b1Index, allocatedSize: 100)
            ],
            cancellationCheck: {}
        )

        XCTAssertEqual(updatedStore.node(id: dirA.id)?.allocatedSize, 35)
        XCTAssertEqual(updatedStore.node(id: dirA.id)?.descendantFileCount, 2)
        XCTAssertEqual(updatedStore.node(id: dirB.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.root.allocatedSize, 135)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 3)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 3)
        XCTAssertEqual(updatedStore.aggregateStats.accessibleItemCount, 6)
        XCTAssertEqual(updatedStore.childIDs(of: dirA.id), [a2.id, a1.id])
        XCTAssertEqual(updatedStore.childIDs(of: root.id), [dirB.id, dirA.id])
    }

    func testReplacingAllocatedSizesLeavesUnaffectedBranchesUntouched() throws {
        let a1 = makeFileNode(id: "/root/a/a1.bin", name: "a1.bin", size: 20)
        let dirA = makeDirectoryNode(id: "/root/a", name: "a", children: [a1])
        let c1 = makeFileNode(id: "/root/c/c1.bin", name: "c1.bin", size: 9)
        let c2 = makeFileNode(id: "/root/c/c2.bin", name: "c2.bin", size: 4)
        let dirC = makeDirectoryNode(id: "/root/c", name: "c", children: [c1, c2])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [dirA, dirC])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [dirA, dirC],
            dirA.id: [a1],
            dirC.id: [c1, c2]
        ])
        let a1Index = try XCTUnwrap(store.nodeIndex(id: a1.id))

        let updatedStore = try store.replacingAllocatedSizes(
            [(nodeIndex: a1Index, allocatedSize: 50)],
            cancellationCheck: {}
        )

        XCTAssertEqual(updatedStore.node(id: c1.id), c1)
        XCTAssertEqual(updatedStore.node(id: c2.id), c2)
        XCTAssertEqual(updatedStore.node(id: dirC.id), dirC)
        XCTAssertEqual(updatedStore.childIDs(of: dirC.id), [c1.id, c2.id])
        XCTAssertEqual(updatedStore.childIDs(of: root.id), [dirA.id, dirC.id])
        XCTAssertEqual(updatedStore.root.allocatedSize, 63)
    }

    func testRemovingSubtreeSaturatesAncestorTotalsAndRepairsAccessibility() throws {
        let maximum = makeFileNode(id: "/root/maximum.bin", name: "maximum.bin", size: .max)
        let tiny = makeFileNode(id: "/root/tiny.bin", name: "tiny.bin", size: 1)
        let inaccessible = makeFileNode(
            id: "/root/inaccessible.bin",
            name: "inaccessible.bin",
            size: 10,
            isAccessible: false
        )
        let staleRoot = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(
            rootID: staleRoot.id,
            nodesByID: [
                staleRoot.id: staleRoot,
                maximum.id: maximum,
                tiny.id: tiny,
                inaccessible.id: inaccessible,
            ],
            childIDsByID: [staleRoot.id: [maximum.id, inaccessible.id, tiny.id]]
        )

        let updatedStore = try XCTUnwrap(store.removingSubtree(id: inaccessible.id))

        XCTAssertEqual(updatedStore.root.allocatedSize, Int64.max)
        XCTAssertEqual(updatedStore.root.logicalSize, Int64.max)
        XCTAssertEqual(updatedStore.root.descendantFileCount, 2)
        XCTAssertTrue(updatedStore.root.isAccessible)
        XCTAssertEqual(updatedStore.aggregateStats.accessibleItemCount, 3)
        XCTAssertEqual(updatedStore.aggregateStats.inaccessibleItemCount, 0)
    }

    func testLogicalScopeRemovalRepairsAggregateAccessibility() throws {
        let accessible = makeFileNode(
            id: "/root/accessible.bin",
            name: "accessible.bin",
            size: 1
        )
        let inaccessible = makeFileNode(
            id: "/root/folder/inaccessible.bin",
            name: "inaccessible.bin",
            size: 1,
            isAccessible: false
        )
        let folder = makeDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [inaccessible],
            isAccessible: false,
            isSelfAccessible: true
        )
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [folder, accessible],
            isAccessible: false,
            isSelfAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, accessible],
            folder.id: [inaccessible],
        ])
        let scope = try XCTUnwrap(store.logicalScope(rootedAt: root.id))
        let materializedScope = try scope.materialized(cancellationCheck: {})

        let expected = try XCTUnwrap(materializedScope.removingSubtree(id: inaccessible.id))
        let updatedStore = try XCTUnwrap(scope.removingSubtree(id: inaccessible.id))

        assertEquivalent(updatedStore, expected)
        XCTAssertTrue(updatedStore.root.isAccessible)
        XCTAssertTrue(try XCTUnwrap(updatedStore.node(id: folder.id)).isAccessible)
        XCTAssertEqual(updatedStore.aggregateStats.accessibleItemCount, 3)
        XCTAssertEqual(updatedStore.aggregateStats.inaccessibleItemCount, 0)
        XCTAssertEqual(
            updatedStore.aggregateStats.accessibleItemCount +
                updatedStore.aggregateStats.inaccessibleItemCount,
            updatedStore.nodeCount
        )
    }

    func testRemovingSubtreeHonorsCancellationDuringCompaction() {
        let children = (0..<1_024).map { index in
            makeFileNode(
                id: "/root/folder/item-\(index).bin",
                name: "item-\(index).bin",
                size: 1
            )
        }
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: children)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: children,
        ])
        var checkCount = 0

        XCTAssertThrowsError(try store.removingSubtree(
            id: folder.id,
            cancellationCheck: {
                checkCount += 1
                if checkCount == 10 {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(store.nodeCount, children.count + 2)
        XCTAssertNotNil(store.node(id: folder.id))
    }

    func testRemovingWideSiblingHonorsCancellationAcrossRepairPasses() {
        let children = (0..<1_025).map { index in
            makeFileNode(
                id: "/root/item-\(index).bin",
                name: "item-\(index).bin",
                size: 1
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        for cancellationCheckLimit in [6, 21] {
            var cancellationCheckCount = 0
            XCTAssertThrowsError(try store.removingSubtree(
                id: children[512].id,
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount == cancellationCheckLimit {
                        throw CancellationError()
                    }
                }
            )) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(cancellationCheckCount, cancellationCheckLimit)
        }
        guard let logicalScope = store.logicalScope(rootedAt: root.id) else {
            XCTFail("Expected logical scope.")
            return
        }
        var logicalScopeCheckCount = 0
        XCTAssertThrowsError(try logicalScope.removingSubtree(
            id: children[512].id,
            cancellationCheck: {
                logicalScopeCheckCount += 1
                if logicalScopeCheckCount == 10 {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(logicalScopeCheckCount, 10)
        XCTAssertEqual(store.nodeCount, children.count + 1)
        XCTAssertNotNil(store.node(id: children[512].id))
    }

    func testLogicalScopeWideRemovalHonorsCancellationDuringDirectoryRepair() throws {
        let children = (0..<1_025).map { index in
            makeFileNode(
                id: "/root/item-\(index).bin",
                name: "item-\(index).bin",
                size: 1
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let scope = try XCTUnwrap(store.logicalScope(rootedAt: root.id))
        // Checks before repair reach the first combined child-order/totals entry.
        // This probe requires the next periodic check after 256 surviving children.
        let firstPeriodicDirectoryTotalsCheck = 37
        var cancellationCheckCount = 0

        XCTAssertThrowsError(try scope.removingSubtree(
            id: children[512].id,
            cancellationCheck: {
                cancellationCheckCount += 1
                if cancellationCheckCount == firstPeriodicDirectoryTotalsCheck {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationCheckCount, firstPeriodicDirectoryTotalsCheck)
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

        var iteratedIDs: [String] = []
        store.forEachIndexedNodeID(excludingRoot: true) { id in
            iteratedIDs.append(id)
        }
        XCTAssertEqual(iteratedIDs, ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])
    }

    func testCompactIndexInitializerPreservesTopologyAndCompatibilityViews() throws {
        let nested = makeFileNode(id: "/root/folder/nested.txt", name: "nested.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [sibling, folder])
        let nodes = [root, folder, nested, sibling]
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let folderIndex = FileTreeNodeIndex(rawValue: 1)
        let nestedIndex = FileTreeNodeIndex(rawValue: 2)
        let siblingIndex = FileTreeNodeIndex(rawValue: 3)
        let stats = ScanAggregateStats(
            totalAllocatedSize: 12,
            totalLogicalSize: 12,
            fileCount: 2,
            directoryCount: 2,
            accessibleItemCount: 4,
            inaccessibleItemCount: 0
        )

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: [
                [siblingIndex, folderIndex],
                [nestedIndex],
                [],
                [],
            ],
            parentIndices: [nil, rootIndex, folderIndex, rootIndex],
            orderedNodeIndices: [rootIndex, siblingIndex, folderIndex, nestedIndex],
            aggregateStats: stats
        )

        XCTAssertEqual(store.nodeIndex(id: folder.id), folderIndex)
        XCTAssertEqual(store.node(at: nestedIndex)?.id, nested.id)
        XCTAssertEqual(store.parentIndex(of: nestedIndex), folderIndex)
        XCTAssertEqual(store.childIndices(of: rootIndex), [siblingIndex, folderIndex])
        XCTAssertEqual(store.parentID(of: nested.id), folder.id)
        XCTAssertEqual(store.childIDs(of: root.id), [sibling.id, folder.id])
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, sibling.id, folder.id, nested.id])
        XCTAssertEqual(store.path(to: nested.id).map(\.id), [root.id, folder.id, nested.id])

        XCTAssertEqual(store.nodesByID, Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }))
        XCTAssertEqual(store.childIDsByID, [
            root.id: [sibling.id, folder.id],
            folder.id: [nested.id],
        ])
        XCTAssertEqual(store.parentIDByID, [
            folder.id: root.id,
            nested.id: folder.id,
            sibling.id: root.id,
        ])
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, stats.totalAllocatedSize)
        XCTAssertEqual(store.aggregateStats.totalLogicalSize, stats.totalLogicalSize)
        XCTAssertEqual(store.aggregateStats.fileCount, stats.fileCount)
        XCTAssertEqual(store.aggregateStats.directoryCount, stats.directoryCount)

        let scopedStore = try XCTUnwrap(store.subtree(rootedAt: folder.id))

        XCTAssertEqual(scopedStore.indexedNodeIDs(), [folder.id, nested.id])
        XCTAssertEqual(scopedStore.childIDs(of: folder.id), [nested.id])
        XCTAssertEqual(scopedStore.parentID(of: nested.id), folder.id)
        XCTAssertNil(scopedStore.parentID(of: folder.id))
        XCTAssertNil(scopedStore.node(id: sibling.id))
        XCTAssertEqual(scopedStore.aggregateStats.fileCount, 1)
        XCTAssertEqual(scopedStore.aggregateStats.directoryCount, 1)

        let logicalScope = try XCTUnwrap(store.logicalScope(rootedAt: folder.id))

        XCTAssertNotEqual(logicalScope.contentID, store.contentID)
        XCTAssertEqual(logicalScope.backingStorageID, store.backingStorageID)
        XCTAssertEqual(logicalScope.backingNodeCapacity, store.nodeCount)
        XCTAssertNotEqual(scopedStore.backingStorageID, store.backingStorageID)
        XCTAssertEqual(scopedStore.backingNodeCapacity, 2)
        XCTAssertEqual(logicalScope.rootID, folder.id)
        XCTAssertEqual(logicalScope.root, folder)
        XCTAssertEqual(logicalScope.nodeCount, 2)
        XCTAssertEqual(logicalScope.indexedNodeIndices(), [folderIndex, nestedIndex])
        XCTAssertEqual(logicalScope.indexedNodeIDs(), [folder.id, nested.id])
        XCTAssertEqual(logicalScope.indexedNodeIDs(excludingRoot: true), [nested.id])
        XCTAssertEqual(logicalScope.nodesByID, [folder.id: folder, nested.id: nested])
        XCTAssertEqual(logicalScope.childIDsByID, [folder.id: [nested.id]])
        XCTAssertEqual(logicalScope.parentIDByID, [nested.id: folder.id])
        XCTAssertEqual(logicalScope.childIndices(of: folderIndex), [nestedIndex])
        XCTAssertEqual(logicalScope.parentIndex(of: nestedIndex), folderIndex)
        XCTAssertNil(logicalScope.parentIndex(of: folderIndex))
        XCTAssertNil(logicalScope.node(id: root.id))
        XCTAssertNil(logicalScope.node(id: sibling.id))
        XCTAssertNil(logicalScope.node(at: rootIndex))
        XCTAssertNil(logicalScope.parentID(of: folder.id))
        XCTAssertEqual(logicalScope.path(to: nested.id).map(\.id), [folder.id, nested.id])
        XCTAssertTrue(logicalScope.isAncestor(folder.id, of: nested.id))
        XCTAssertFalse(logicalScope.isAncestor(root.id, of: nested.id))
        XCTAssertEqual(logicalScope.aggregateStats.fileCount, 1)
        XCTAssertEqual(logicalScope.aggregateStats.directoryCount, 1)
    }

    func testLogicalScopePreservesCountsAccessibilityAndNestedScoping() throws {
        let summarized = makeTestSummarizedDirectoryNode(
            id: "/root/Home/Summary",
            name: "Summary",
            size: 30,
            descendantFileCount: 7
        )
        let inaccessible = makeFileNode(
            id: "/root/Home/Private.bin",
            name: "Private.bin",
            size: 20,
            isAccessible: false
        )
        let home = makeDirectoryNode(
            id: "/root/Home",
            name: "Home",
            children: [summarized, inaccessible]
        )
        let sibling = makeFileNode(id: "/root/System.bin", name: "System.bin", size: 100)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [home, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [home, sibling],
            home.id: [summarized, inaccessible],
        ])

        let homeScope = try XCTUnwrap(store.logicalScope(rootedAt: home.id))

        XCTAssertEqual(homeScope.root.allocatedSize, 50)
        XCTAssertEqual(homeScope.aggregateStats.fileCount, 8)
        XCTAssertEqual(homeScope.aggregateStats.directoryCount, 2)
        XCTAssertEqual(homeScope.aggregateStats.accessibleItemCount, 1)
        XCTAssertEqual(homeScope.aggregateStats.inaccessibleItemCount, 2)
        XCTAssertEqual(homeScope.subtreeNodeCount(rootedAt: home.id), 3)
        XCTAssertEqual(homeScope.subtreeNodeCount(rootedAt: root.id), 0)

        let nestedScope = try XCTUnwrap(homeScope.logicalScope(rootedAt: summarized.id))

        XCTAssertEqual(nestedScope.backingStorageID, store.backingStorageID)
        XCTAssertEqual(nestedScope.backingNodeCapacity, store.nodeCount)
        XCTAssertEqual(nestedScope.rootID, summarized.id)
        XCTAssertEqual(nestedScope.nodeCount, 1)
        XCTAssertEqual(nestedScope.aggregateStats.fileCount, 7)
        XCTAssertEqual(nestedScope.aggregateStats.directoryCount, 1)
        XCTAssertNil(nestedScope.node(id: inaccessible.id))
        XCTAssertNil(nestedScope.parent(of: summarized.id))
    }

    func testLogicalScopeReownsHardLinkAndCloneAllocationAndRepairsOrder() throws {
        let hardLinkIdentity = FileIdentity(device: 9, inode: 1)
        let cloneIdentity = CloneIdentity(device: 9, cloneID: 2)
        let outsideHardLink = sharedFileNode(
            id: "/root/A/hard.bin",
            allocatedSize: 100,
            fileIdentity: hardLinkIdentity,
            linkCount: 2
        )
        let visibleHardLink = sharedFileNode(
            id: "/root/Home/z-hard.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: hardLinkIdentity,
            linkCount: 2
        )
        let outsideClone = sharedFileNode(
            id: "/root/A/clone.bin",
            allocatedSize: 100,
            dataAllocatedSize: 80,
            fileIdentity: FileIdentity(device: 9, inode: 2),
            cloneIdentity: cloneIdentity
        )
        let visibleClone = sharedFileNode(
            id: "/root/Home/z-clone.bin",
            allocatedSize: 20,
            unduplicatedAllocatedSize: 100,
            dataAllocatedSize: 80,
            fileIdentity: FileIdentity(device: 9, inode: 3),
            cloneIdentity: cloneIdentity
        )
        let regular = makeFileNode(id: "/root/Home/regular.bin", name: "regular.bin", size: 50)
        let outside = makeDirectoryNode(
            id: "/root/A",
            name: "A",
            children: [outsideHardLink, outsideClone]
        )
        let home = makeDirectoryNode(
            id: "/root/Home",
            name: "Home",
            children: [visibleHardLink, visibleClone, regular]
        )
        let root = makeDirectoryNode(id: "/root", name: "root", children: [outside, home])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [outside, home],
            outside.id: [outsideHardLink, outsideClone],
            home.id: [visibleHardLink, visibleClone, regular],
        ])

        XCTAssertEqual(store.childIDs(of: home.id), [regular.id, visibleClone.id, visibleHardLink.id])

        let scope = try XCTUnwrap(store.logicalScope(rootedAt: home.id))

        XCTAssertEqual(scope.root.allocatedSize, 250)
        XCTAssertEqual(scope.aggregateStats.totalAllocatedSize, 250)
        XCTAssertEqual(scope.node(id: visibleHardLink.id)?.allocatedSize, 100)
        XCTAssertEqual(scope.node(id: visibleClone.id)?.allocatedSize, 100)
        XCTAssertEqual(
            scope.childIDs(of: home.id),
            [visibleClone.id, visibleHardLink.id, regular.id]
        )
        XCTAssertEqual(
            scope.indexedNodeIDs(),
            [home.id, visibleClone.id, visibleHardLink.id, regular.id]
        )
        XCTAssertNil(scope.node(id: outsideHardLink.id))
        XCTAssertNil(scope.node(id: outsideClone.id))

        let materializedScope = try scope.materialized(cancellationCheck: {})
        let expectedFiltered = try XCTUnwrap(try materializedScope.removingSubtree(
            id: regular.id,
            cancellationCheck: {}
        ))
        let filtered = try XCTUnwrap(try scope.removingSubtree(
            id: regular.id,
            cancellationCheck: {}
        ))
        assertEquivalent(filtered, expectedFiltered)
        XCTAssertEqual(filtered.root.allocatedSize, 200)
        XCTAssertEqual(filtered.nodeCount, 3)
        XCTAssertNil(filtered.node(id: regular.id))
        XCTAssertNil(filtered.node(id: outsideHardLink.id))
        XCTAssertEqual(filtered.node(id: visibleHardLink.id)?.allocatedSize, 100)
        XCTAssertEqual(filtered.node(id: visibleClone.id)?.allocatedSize, 100)

        let batchRemovalIDs = [regular.id, visibleClone.id]
        let expectedBatch = materializedScope.removingSubtrees(rootedAt: batchRemovalIDs)
        let filteredBatch = scope.removingSubtrees(rootedAt: batchRemovalIDs)
        assertEquivalent(filteredBatch, expectedBatch)

        let rescannedRegular = makeFileNode(id: regular.id, name: regular.name, size: 75)
        let replaced = try XCTUnwrap(try scope.replacingSubtree(
            id: regular.id,
            with: FileTreeStore(root: rescannedRegular),
            cancellationCheck: {}
        ))
        XCTAssertEqual(replaced.root.allocatedSize, 275)
        XCTAssertEqual(replaced.node(id: regular.id)?.allocatedSize, 75)
        XCTAssertNil(replaced.node(id: outsideHardLink.id))
    }

    func testWideTreeChildMapDoesNotReserveOneEntryPerChild() {
        let children = (0..<1_024).map { index in
            makeFileNode(
                id: "/root/item-\(index).txt",
                name: "item-\(index).txt",
                size: 1
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        let childMap = store.childIDsByID

        XCTAssertEqual(childMap[root.id], children.map(\.id))
        XCTAssertEqual(childMap.count, 1)
        XCTAssertLessThan(childMap.capacity, children.count)
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

    func testChildrenByIDInitializerDropsLaterDuplicateNodeIDs() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertEqual(store.children(of: root.id).map(\.name), ["kept.txt"])
        XCTAssertEqual(store.node(id: kept.id)?.name, "kept.txt")
        XCTAssertEqual(store.parent(of: kept.id)?.id, root.id)
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, kept.id])
        XCTAssertEqual(store.root.allocatedSize, kept.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, kept.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, kept.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testChildrenByIDInitializerRepairsNestedDuplicateTotals() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [shared, folder],
            folder.id: [shared],
        ])

        XCTAssertEqual(Set(store.children(of: root.id).map(\.id)), Set([shared.id, folder.id]))
        XCTAssertTrue(store.children(of: folder.id).isEmpty)
        XCTAssertEqual(store.node(id: folder.id)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.logicalSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.descendantFileCount, 0)
        XCTAssertEqual(store.root.allocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, shared.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testChildrenByIDInitializerRepairsAccessibilityAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [kept, dropped],
            isAccessible: false,
            isSelfAccessible: true
        )

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertTrue(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 2)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 0)
    }

    func testChildrenByIDInitializerPreservesSelfInaccessibleDirectoryAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped], isAccessible: false)

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, dropped],
        ])

        XCTAssertFalse(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 1)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 1)
    }

    func testChildrenByIDInitializerOrdersByKeptChildrenWhenDuplicateIsLarger() {
        let kept = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 1)
        let sibling = makeFileNode(id: "/root/b.txt", name: "b.txt", size: 50)
        let dropped = makeFileNode(id: kept.id, name: "dropped-a.txt", size: 100)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, sibling, dropped])

        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [kept, sibling, dropped],
        ])

        XCTAssertEqual(store.children(of: root.id).map(\.id), [sibling.id, kept.id])
        XCTAssertEqual(store.root.allocatedSize, sibling.allocatedSize + kept.allocatedSize)
    }

    func testFlatInitializerDropsDuplicateChildReferences() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])
        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [
                root.id: root,
                shared.id: shared,
                folder.id: folder,
            ],
            childIDsByID: [
                root.id: [shared.id, folder.id, shared.id],
                folder.id: [shared.id],
            ]
        )

        XCTAssertEqual(store.children(of: root.id).map(\.id), [shared.id, folder.id])
        XCTAssertTrue(store.children(of: folder.id).isEmpty)
        XCTAssertEqual(store.parent(of: shared.id)?.id, root.id)
        XCTAssertEqual(store.indexedNodeIDs(), [root.id, shared.id, folder.id])
        XCTAssertEqual(store.node(id: folder.id)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.logicalSize, 0)
        XCTAssertEqual(store.node(id: folder.id)?.descendantFileCount, 0)
        XCTAssertEqual(store.root.allocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.root.logicalSize, shared.logicalSize)
        XCTAssertEqual(store.root.descendantFileCount, 1)
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, shared.allocatedSize)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)
    }

    func testFlatInitializerPreservesPrecomputedStatsForEmptyChildArrays() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let precomputedStats = ScanAggregateStats(
            totalAllocatedSize: 99,
            totalLogicalSize: 101,
            fileCount: 42,
            directoryCount: 7,
            accessibleItemCount: 6,
            inaccessibleItemCount: 1
        )

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []],
            aggregateStats: precomputedStats
        )

        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, precomputedStats.totalAllocatedSize)
        XCTAssertEqual(store.aggregateStats.totalLogicalSize, precomputedStats.totalLogicalSize)
        XCTAssertEqual(store.aggregateStats.fileCount, precomputedStats.fileCount)
        XCTAssertEqual(store.aggregateStats.directoryCount, precomputedStats.directoryCount)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, precomputedStats.accessibleItemCount)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, precomputedStats.inaccessibleItemCount)
    }

    func testFlatInitializerPreservesInaccessibleEmptyMaterializedDirectory() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [], isAccessible: false)

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []]
        )

        XCTAssertFalse(store.root.isAccessible)
        XCTAssertEqual(store.aggregateStats.accessibleItemCount, 0)
        XCTAssertEqual(store.aggregateStats.inaccessibleItemCount, 1)
    }

    func testReplacingSubtreeRejectsReplacementIDsOutsideOldSubtree() throws {
        let targetChild = makeFileNode(id: "/root/target/old.txt", name: "old.txt", size: 4)
        let target = makeDirectoryNode(id: "/root/target", name: "target", children: [targetChild])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [target, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [target, sibling],
            target.id: [targetChild],
        ])
        let collidingReplacementChild = makeFileNode(id: sibling.id, name: "collision.txt", size: 99)
        let replacementRoot = makeDirectoryNode(
            id: target.id,
            name: "target",
            children: [collidingReplacementChild]
        )
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [collidingReplacementChild],
        ])

        XCTAssertThrowsError(
            try store.replacingSubtree(
                id: target.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reuses an existing node ID"))
            XCTAssertTrue(error.localizedDescription.contains(sibling.id))
        }
        XCTAssertNil(store.replacingSubtree(id: target.id, with: replacementStore))
        XCTAssertEqual(store.node(id: sibling.id)?.name, sibling.name)
    }

    func testSharedAllocationMetadataIgnoresDirectoryLinkCounts() throws {
        let ordinaryFile = makeFileNode(
            id: "/root/ordinary.dat",
            name: "ordinary.dat",
            size: 4
        )
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [ordinaryFile],
            linkCount: 42
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [ordinaryFile]]
        )

        XCTAssertFalse(try store.subtreeContainsSharedAllocationMetadata(
            rootedAt: root.id,
            cancellationCheck: {}
        ))
    }

    func testVerifiedRootIDInitProjectsSuppliedTopology() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [sibling, folder])

        let store = FileTreeStore(
            verifiedRootID: root.id,
            nodesByID: [
                root.id: root,
                sibling.id: sibling,
                folder.id: folder,
                leaf.id: leaf,
            ],
            childIDsByID: [
                root.id: [sibling.id, folder.id],
                folder.id: [leaf.id],
            ],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: 12,
                totalLogicalSize: 12,
                fileCount: 2,
                directoryCount: 1,
                accessibleItemCount: 3,
                inaccessibleItemCount: 0
            )
        )

        XCTAssertEqual(store.rootID, root.id)
        XCTAssertEqual(store.nodesByID[root.id], root)
        XCTAssertEqual(store.nodesByID[leaf.id], leaf)
        XCTAssertEqual(store.childIDsByID[root.id], [sibling.id, folder.id])
        XCTAssertEqual(store.childIDsByID[folder.id], [leaf.id])
        XCTAssertEqual(store.parentIDByID[sibling.id], root.id)
        XCTAssertEqual(store.parentIDByID[folder.id], root.id)
        XCTAssertEqual(store.parentIDByID[leaf.id], folder.id)
        XCTAssertNil(store.parentIDByID[root.id])
        XCTAssertEqual(store.aggregateStats.totalAllocatedSize, 12)
        XCTAssertEqual(store.aggregateStats.fileCount, 2)
    }

    func testSubtreeNodeCountStopsAtLimit() {
        let files = (0..<10).map { index in
            makeFileNode(
                id: "/root/file-\(index).dat",
                name: "file-\(index).dat",
                size: 1
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: files)
        let store = FileTreeStore(root: root, childrenByID: [root.id: files])

        XCTAssertEqual(store.subtreeNodeCount(rootedAt: root.id, upTo: 4), 4)
        XCTAssertEqual(store.subtreeNodeCount(rootedAt: root.id, upTo: 0), 0)
        XCTAssertEqual(store.subtreeNodeCount(rootedAt: "/missing", upTo: 4), 0)
        XCTAssertEqual(store.subtreeNodeCount(rootedAt: root.id), files.count + 1)
        XCTAssertEqual(store.subtreeNodeCount(rootedAt: root.id, upTo: .max), files.count + 1)

        let nestedFolder = makeDirectoryNode(id: "/root/nested", name: "nested", children: files)
        let nestedRoot = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [nestedFolder]
        )
        let nestedStore = FileTreeStore(
            root: nestedRoot,
            childrenByID: [
                nestedRoot.id: [nestedFolder],
                nestedFolder.id: files,
            ]
        )

        XCTAssertEqual(nestedStore.subtreeNodeCount(rootedAt: nestedRoot.id, upTo: 5), 5)
        XCTAssertEqual(nestedStore.subtreeNodeCount(rootedAt: nestedFolder.id, upTo: 7), 7)
    }

    func testReplacingRootCanChangeRootID() throws {
        let oldChild = makeFileNode(id: "/root/old.txt", name: "old.txt", size: 4)
        let oldRoot = makeDirectoryNode(id: "/root", name: "root", children: [oldChild])
        let store = FileTreeStore(root: oldRoot, childrenByID: [
            oldRoot.id: [oldChild],
        ])
        let newChild = makeFileNode(id: "/replacement/new.txt", name: "new.txt", size: 12)
        let newRoot = makeDirectoryNode(id: "/replacement", name: "replacement", children: [newChild])
        let replacementStore = FileTreeStore(root: newRoot, childrenByID: [
            newRoot.id: [newChild],
        ])

        let updated = try XCTUnwrap(
            try store.replacingSubtree(
                id: oldRoot.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        )

        XCTAssertEqual(updated.root.id, newRoot.id)
        XCTAssertEqual(updated.children(of: newRoot.id).map(\.id), [newChild.id])
        XCTAssertNil(updated.node(id: oldRoot.id))
        XCTAssertNil(updated.node(id: oldChild.id))
    }

    func testReplacingDisjointSubtreesRebuildsSharedAncestors() throws {
        let oldAFile = makeFileNode(id: "/root/A/old.txt", name: "old.txt", size: 5)
        let oldBFile = makeFileNode(id: "/root/B/old.txt", name: "old.txt", size: 7)
        let oldA = makeDirectoryNode(id: "/root/A", name: "A", children: [oldAFile])
        let oldB = makeDirectoryNode(id: "/root/B", name: "B", children: [oldBFile])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 3)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [oldA, oldB, sibling],
            oldA.id: [oldAFile],
            oldB.id: [oldBFile],
        ])

        let newAFile = makeFileNode(id: "/root/A/new.txt", name: "new.txt", size: 20)
        let newA = makeDirectoryNode(id: oldA.id, name: "A", children: [newAFile])
        let newBFile = makeFileNode(id: "/root/B/new.txt", name: "new.txt", size: 10)
        let newBExtra = makeFileNode(id: "/root/B/extra.txt", name: "extra.txt", size: 2)
        let newB = makeDirectoryNode(id: oldB.id, name: "B", children: [newBFile, newBExtra])

        let updated = try XCTUnwrap(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: newA, childrenByID: [newA.id: [newAFile]]),
                oldB.id: FileTreeStore(root: newB, childrenByID: [newB.id: [newBFile, newBExtra]]),
            ],
            cancellationCheck: {}
        ))

        XCTAssertNil(updated.node(id: oldAFile.id))
        XCTAssertNil(updated.node(id: oldBFile.id))
        XCTAssertEqual(updated.children(of: root.id).map(\.id), [newA.id, newB.id, sibling.id])
        XCTAssertEqual(updated.children(of: newA.id).map(\.id), [newAFile.id])
        XCTAssertEqual(updated.children(of: newB.id).map(\.id), [newBFile.id, newBExtra.id])
        XCTAssertEqual(updated.root.allocatedSize, 35)
        XCTAssertEqual(updated.root.logicalSize, 35)
        XCTAssertEqual(updated.root.descendantFileCount, 4)
        XCTAssertEqual(updated.aggregateStats.fileCount, 4)
        XCTAssertEqual(updated.aggregateStats.directoryCount, 3)
    }

    func testReplacingSubtreesCanChangeRootID() throws {
        let oldChild = makeFileNode(id: "/root/old.txt", name: "old.txt", size: 5)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldChild])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldChild]])
        let newChild = makeFileNode(id: "/replacement/new.txt", name: "new.txt", size: 9)
        let replacementRoot = makeDirectoryNode(
            id: "/replacement",
            name: "replacement",
            children: [newChild]
        )

        let updated = try XCTUnwrap(try store.replacingSubtrees(
            [
                root.id: FileTreeStore(
                    root: replacementRoot,
                    childrenByID: [replacementRoot.id: [newChild]]
                ),
            ],
            cancellationCheck: {}
        ))

        XCTAssertEqual(updated.rootID, replacementRoot.id)
        XCTAssertEqual(updated.root.allocatedSize, 9)
        XCTAssertEqual(updated.children(of: replacementRoot.id), [newChild])
        XCTAssertNil(updated.node(id: root.id))
    }

    func testReplacingSubtreesRejectsOverlappingTargets() throws {
        let leaf = makeFileNode(id: "/root/folder/leaf.txt", name: "leaf.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [leaf],
        ])

        XCTAssertThrowsError(try store.replacingSubtrees(
            [
                folder.id: FileTreeStore(root: folder, childrenByID: [folder.id: [leaf]]),
                leaf.id: FileTreeStore(root: leaf),
            ],
            cancellationCheck: {}
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("must be disjoint"))
        }
    }

    func testReplacingSubtreesRejectsIDsSharedByReplacementTrees() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let sharedID = "/root/shared.txt"
        let firstShared = makeFileNode(id: sharedID, name: "shared.txt", size: 2)
        let secondShared = makeFileNode(id: sharedID, name: "shared.txt", size: 3)

        XCTAssertThrowsError(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: firstShared),
                oldB.id: FileTreeStore(root: secondShared),
            ],
            cancellationCheck: {}
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(sharedID))
        }
        XCTAssertEqual(store.root.allocatedSize, 2)
    }

    func testReplacingSubtreesRejectsIDRemovedByAnotherTarget() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let replacementB = makeFileNode(id: "/root/replacement-B", name: "replacement-B", size: 2)

        XCTAssertThrowsError(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: oldB),
                oldB.id: FileTreeStore(root: replacementB),
            ],
            cancellationCheck: {}
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(oldB.id))
        }
    }

    func testReplacingSubtreesRebalancesHardLinksAcrossReplacementBoundaries() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let identity = FileIdentity(device: 9, inode: 42)
        let firstLink = FileNodeRecord(
            id: "/root/A/link.bin",
            url: URL(filePath: "/root/A/link.bin"),
            name: "link.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 4_096,
            logicalSize: 4_096,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: 2,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let secondLink = FileNodeRecord(
            id: "/root/B/link.bin",
            url: URL(filePath: "/root/B/link.bin"),
            name: "link.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 4_096,
            logicalSize: 4_096,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: 2,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )

        let updated = try XCTUnwrap(try store.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: firstLink),
                oldB.id: FileTreeStore(root: secondLink),
            ],
            cancellationCheck: {}
        ))

        XCTAssertEqual(updated.root.allocatedSize, 4_096)
        XCTAssertEqual(updated.root.logicalSize, 8_192)
        XCTAssertEqual(updated.node(id: firstLink.id)?.allocatedSize, 4_096)
        XCTAssertEqual(updated.node(id: secondLink.id)?.allocatedSize, 0)
    }

    func testDeepTreeIndexingAndAggregateStatsAvoidRecursiveTraversal() throws {
        let depth = 5_000
        let leafID = "/root/file.txt"
        let leaf = makeFileNode(id: leafID, name: "file.txt", size: 12)
        var nodesByID = [leaf.id: leaf]
        var childIDsByID: [String: [String]] = [:]
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
            childID = nodeID
        }

        let root = makeDirectoryNode(id: "/root", name: "root", children: [nodesByID[childID]!])
        nodesByID[root.id] = root
        childIDsByID[root.id] = [childID]

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )

        XCTAssertEqual(store.path(to: leafID).count, depth + 2)
        XCTAssertEqual(store.aggregateStats.directoryCount, depth + 1)
        XCTAssertEqual(store.aggregateStats.fileCount, 1)

        let updatedStore = try XCTUnwrap(store.removingSubtree(id: leafID))

        XCTAssertEqual(updatedStore.nodeCount, depth + 1)
        XCTAssertEqual(updatedStore.root.allocatedSize, 0)
        XCTAssertEqual(updatedStore.aggregateStats.directoryCount, depth + 1)
        XCTAssertEqual(updatedStore.aggregateStats.fileCount, 0)
    }

    func testSubtreeProjectionHonorsCancellationAcrossWideDirectories() {
        let children = (0..<1_024).map { offset in
            makeFileNode(
                id: "/root/file-\(offset).bin",
                name: "file-\(offset).bin",
                size: 1
            )
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        var cancellationCheckCount = 0

        XCTAssertThrowsError(try store.subtree(
            rootedAt: root.id,
            cancellationCheck: {
                cancellationCheckCount += 1
                if cancellationCheckCount >= 4 {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(cancellationCheckCount, 4)

        cancellationCheckCount = 0
        XCTAssertThrowsError(try store.logicalScope(
            rootedAt: root.id,
            cancellationCheck: {
                cancellationCheckCount += 1
                if cancellationCheckCount >= 4 {
                    throw CancellationError()
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(cancellationCheckCount, 4)
    }

    func testVolumeReconciliationUpdatesAndReordersExistingRemainderWithoutChangingTopology() throws {
        let mebibyte: Int64 = 1_024 * 1_024
        let nested = makeFileNode(id: "/root/folder/nested.bin", name: "nested.bin", size: 300 * mebibyte)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let payload = makeFileNode(id: "/root/payload.bin", name: "payload.bin", size: 200 * mebibyte)
        let remainder = FileNodeRecord(
            id: "/root#system-unattributed",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 32 * mebibyte,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, payload, remainder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, payload, remainder],
            folder.id: [nested],
        ])
        let originalStats = store.aggregateStats
        let target = ScanTarget(
            url: URL(filePath: root.id, directoryHint: .isDirectory),
            kind: .volume
        )

        let grown = VolumeCapacityAccounting.reconciledStore(
            store,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 1_200 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: false
        )
        let grownRemainder = try XCTUnwrap(grown.node(id: remainder.id))

        XCTAssertNotEqual(grown.contentID, store.contentID)
        XCTAssertNotEqual(grown.backingStorageID, store.backingStorageID)
        XCTAssertEqual(grown.root.allocatedSize, 1_200 * mebibyte)
        XCTAssertEqual(grownRemainder.allocatedSize, 700 * mebibyte)
        XCTAssertEqual(grownRemainder.name, "System & Unattributed")
        XCTAssertTrue(grownRemainder.isSynthetic)
        XCTAssertTrue(grownRemainder.isAccessible)
        XCTAssertEqual(grownRemainder.logicalSize, 0)
        XCTAssertEqual(grown.childIDs(of: root.id), [remainder.id, folder.id, payload.id])
        XCTAssertEqual(
            grown.indexedNodeIDs(),
            [root.id, remainder.id, folder.id, nested.id, payload.id]
        )
        XCTAssertEqual(grown.parentID(of: remainder.id), root.id)
        XCTAssertEqual(grown.parentID(of: nested.id), folder.id)
        XCTAssertEqual(grown.aggregateStats.fileCount, originalStats.fileCount)
        XCTAssertEqual(grown.aggregateStats.directoryCount, originalStats.directoryCount)
        XCTAssertEqual(grown.aggregateStats.accessibleItemCount, originalStats.accessibleItemCount)
        XCTAssertEqual(grown.aggregateStats.inaccessibleItemCount, originalStats.inaccessibleItemCount)

        let shrunk = VolumeCapacityAccounting.reconciledStore(
            grown,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 532 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: true
        )
        let shrunkRemainder = try XCTUnwrap(shrunk.node(id: remainder.id))

        XCTAssertNotEqual(shrunk.contentID, grown.contentID)
        XCTAssertEqual(shrunk.root.allocatedSize, 532 * mebibyte)
        XCTAssertEqual(shrunkRemainder.allocatedSize, 32 * mebibyte)
        XCTAssertEqual(shrunkRemainder.name, "Excluded & Unattributed")
        XCTAssertEqual(shrunk.childIDs(of: root.id), [folder.id, payload.id, remainder.id])
        XCTAssertEqual(
            shrunk.indexedNodeIDs(),
            [root.id, folder.id, nested.id, payload.id, remainder.id]
        )
        XCTAssertEqual(shrunk.aggregateStats.fileCount, originalStats.fileCount)
        XCTAssertEqual(shrunk.aggregateStats.directoryCount, originalStats.directoryCount)
        XCTAssertEqual(shrunk.aggregateStats.accessibleItemCount, originalStats.accessibleItemCount)
        XCTAssertEqual(shrunk.aggregateStats.inaccessibleItemCount, originalStats.inaccessibleItemCount)
    }

    func testVolumeReconciliationAddsAndRemovesRemainderWithoutMaterializingTreeMaps() throws {
        let mebibyte: Int64 = 1_024 * 1_024
        let nested = makeFileNode(id: "/root/folder/nested.bin", name: "nested.bin", size: 100 * mebibyte)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let payload = makeFileNode(id: "/root/payload.bin", name: "payload.bin", size: 100 * mebibyte)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, payload])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, payload],
            folder.id: [nested],
        ])
        let originalStats = store.aggregateStats
        let target = ScanTarget(
            url: URL(filePath: root.id, directoryHint: .isDirectory),
            kind: .volume
        )

        let grown = VolumeCapacityAccounting.reconciledStore(
            store,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 400 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: false
        )
        let remainderID = root.id + "#system-unattributed"

        XCTAssertEqual(grown.nodeCount, store.nodeCount + 1)
        XCTAssertEqual(grown.node(id: remainderID)?.allocatedSize, 200 * mebibyte)
        XCTAssertEqual(grown.parentID(of: nested.id), folder.id)
        XCTAssertEqual(grown.aggregateStats.accessibleItemCount, originalStats.accessibleItemCount + 1)

        let restored = VolumeCapacityAccounting.reconciledStore(
            grown,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 200 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: false
        )

        XCTAssertEqual(restored.nodeCount, store.nodeCount)
        XCTAssertNil(restored.node(id: remainderID))
        XCTAssertEqual(restored.indexedNodeIDs(), store.indexedNodeIDs())
        XCTAssertEqual(restored.parentID(of: nested.id), folder.id)
        XCTAssertEqual(restored.aggregateStats.totalAllocatedSize, originalStats.totalAllocatedSize)
        XCTAssertEqual(restored.aggregateStats.totalLogicalSize, originalStats.totalLogicalSize)
        XCTAssertEqual(restored.aggregateStats.fileCount, originalStats.fileCount)
        XCTAssertEqual(restored.aggregateStats.directoryCount, originalStats.directoryCount)
        XCTAssertEqual(restored.aggregateStats.accessibleItemCount, originalStats.accessibleItemCount)
        XCTAssertEqual(restored.aggregateStats.inaccessibleItemCount, originalStats.inaccessibleItemCount)
    }
}

private func assertEquivalent(
    _ actual: FileTreeStore,
    _ expected: FileTreeStore,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectedNodeIDs = expected.indexedNodeIDs()
    XCTAssertEqual(actual.indexedNodeIDs(), expectedNodeIDs, file: file, line: line)
    XCTAssertEqual(actual.nodesByID, expected.nodesByID, file: file, line: line)
    XCTAssertEqual(actual.childIDsByID, expected.childIDsByID, file: file, line: line)
    XCTAssertEqual(actual.parentIDByID, expected.parentIDByID, file: file, line: line)
    XCTAssertEqual(
        actual.aggregateStats.totalAllocatedSize,
        expected.aggregateStats.totalAllocatedSize,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.aggregateStats.totalLogicalSize,
        expected.aggregateStats.totalLogicalSize,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.aggregateStats.fileCount,
        expected.aggregateStats.fileCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.aggregateStats.directoryCount,
        expected.aggregateStats.directoryCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.aggregateStats.accessibleItemCount,
        expected.aggregateStats.accessibleItemCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.aggregateStats.inaccessibleItemCount,
        expected.aggregateStats.inaccessibleItemCount,
        file: file,
        line: line
    )
}

private func makeFileNode(
    id: String,
    name: String,
    size: Int64,
    isAccessible: Bool = true
) -> FileNodeRecord {
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
        isAccessible: isAccessible,
        isSelfAccessible: isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func sharedFileNode(
    id: String,
    allocatedSize: Int64,
    unduplicatedAllocatedSize: Int64? = nil,
    dataAllocatedSize: Int64? = nil,
    fileIdentity: FileIdentity,
    linkCount: UInt64 = 1,
    cloneIdentity: CloneIdentity? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: URL(filePath: id).lastPathComponent,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: allocatedSize,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        dataAllocatedSize: dataAllocatedSize,
        logicalSize: unduplicatedAllocatedSize ?? allocatedSize,
        descendantFileCount: 1,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        cloneIdentity: cloneIdentity,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isAccessible: Bool = true,
    isSelfAccessible: Bool? = nil
) -> FileNodeRecord {
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
        isAccessible: isAccessible,
        isSelfAccessible: isSelfAccessible ?? isAccessible,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
