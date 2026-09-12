import Foundation
import Testing

@testable import RadixCore

struct FileTreeStoreTests {
    @Test
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

        #expect(store.root.allocatedSize == Int64.max)
        #expect(store.root.logicalSize == Int64.max)
        #expect(store.root.descendantFileCount == 2)
    }

    @Test
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

        #expect(store.aggregateStats.fileCount == Int.max)
    }

    @Test
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

        #expect(store.aggregateStats.fileCount == 7)
        #expect(store.aggregateStats.directoryCount == 1)

        let file = makeFileNode(id: "/root/Hybrid.pkg/file.bin", name: "file.bin", size: 10)
        let expandedStore = FileTreeStore(
            root: summarizedPackage,
            childrenByID: [summarizedPackage.id: [file]]
        )

        #expect(expandedStore.root.isPackage)
        #expect(expandedStore.root.isAutoSummarized)
        #expect(expandedStore.aggregateStats.fileCount == 1)
        #expect(expandedStore.aggregateStats.directoryCount == 1)
    }

    @Test
    func testPathAndAncestorLookup() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: [leaf],
            ])

        #expect(store.path(to: leaf.id).map(\.name) == ["root", "folder", "file.txt"])
        #expect(store.isAncestor(root.id, of: leaf.id))
        #expect(store.isAncestor(folder.id, of: leaf.id))
        #expect(!(store.isAncestor(leaf.id, of: folder.id)))
        #expect(store.parent(of: leaf.id)?.id == folder.id)
    }

    @Test
    func testTopLevelNodeIDsDropsDescendantsOfQueuedParents() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [leaf],
            ])

        #expect(store.topLevelNodeIDs(from: [leaf.id, folder.id, sibling.id, folder.id]) == [folder.id, sibling.id])
        #expect(store.isNodeOrDescendant(leaf.id, of: [folder.id]))
        #expect(!(store.isNodeOrDescendant(sibling.id, of: [folder.id])))
    }

    @Test
    func testPreparedNodeSetPreservesMissingSiblingAndNestedSemantics() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [leaf],
            ])

        let prepared = store.preparedNodeSet(for: [folder.id, "/missing"])

        #expect(store.isNodeOrDescendant(folder.id, of: prepared))
        #expect(store.isNodeOrDescendant(leaf.id, of: prepared))
        #expect(!(store.isNodeOrDescendant(root.id, of: prepared)))
        #expect(!(store.isNodeOrDescendant(sibling.id, of: prepared)))
        #expect(!(store.isNodeOrDescendant("/missing", of: prepared)))
    }

    @Test
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

        #expect(result == siblings.map(\.id))
    }

    @Test
    func testRemovingSubtreesRemovesQueuedParentsAndRepairsTotals() {
        let leaf = makeFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [leaf],
            ])

        let updatedStore = store.removingSubtrees(rootedAt: [leaf.id, folder.id])

        #expect(updatedStore.node(id: folder.id) == nil)
        #expect(updatedStore.node(id: leaf.id) == nil)
        #expect(updatedStore.children(of: root.id).map(\.id) == [sibling.id])
        #expect(updatedStore.root.allocatedSize == sibling.allocatedSize)
        #expect(updatedStore.root.descendantFileCount == 1)
        #expect(updatedStore.aggregateStats.fileCount == 1)
        #expect(updatedStore.aggregateStats.directoryCount == 1)
    }

    @Test
    func testRemovingSubtreesRootReturnsEmptyRootStore() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        let updatedStore = store.removingSubtrees(rootedAt: [root.id])

        #expect(updatedStore.root.id == root.id)
        #expect(updatedStore.root.allocatedSize == 0)
        #expect(updatedStore.root.descendantFileCount == 0)
        #expect(updatedStore.children(of: root.id).isEmpty)
        #expect(updatedStore.aggregateStats.fileCount == 0)
    }

    @Test
    func testRemovingSubtreesRepairsAndResortsSharedAncestors() {
        let retained = makeFileNode(id: "/root/folder/retained.bin", name: "retained.bin", size: 1)
        let removed = makeFileNode(id: "/root/folder/removed.bin", name: "removed.bin", size: 99)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [removed, retained])
        let sibling = makeFileNode(id: "/root/sibling.bin", name: "sibling.bin", size: 50)
        let unrelated = makeFileNode(id: "/root/unrelated.bin", name: "unrelated.bin", size: 4)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling, unrelated])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling, unrelated],
                folder.id: [removed, retained],
            ])

        let updatedStore = store.removingSubtrees(rootedAt: [removed.id, unrelated.id])

        #expect(updatedStore.children(of: folder.id).map(\.id) == [retained.id])
        #expect(updatedStore.children(of: root.id).map(\.id) == [sibling.id, folder.id])
        #expect(updatedStore.indexedNodeIDs() == [root.id, sibling.id, folder.id, retained.id])
        #expect(updatedStore.node(id: folder.id)?.allocatedSize == 1)
        #expect(updatedStore.root.allocatedSize == 51)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 51)
        #expect(updatedStore.aggregateStats.fileCount == 2)
    }

    @Test
    func testLogicalScopeRemovalRepairsOrderAndTraversal() throws {
        let retained = makeFileNode(id: "/root/folder/retained.bin", name: "retained.bin", size: 1)
        let removed = makeFileNode(id: "/root/folder/removed.bin", name: "removed.bin", size: 99)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [removed, retained])
        let sibling = makeFileNode(id: "/root/sibling.bin", name: "sibling.bin", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [removed, retained],
            ])
        let scope = try #require(store.logicalScope(rootedAt: root.id))
        let materializedScope = try scope.materialized(cancellationCheck: {})

        let expected = try #require(materializedScope.removingSubtree(id: removed.id))
        let updatedStore = try #require(scope.removingSubtree(id: removed.id))

        assertEquivalent(updatedStore, expected)
        #expect(updatedStore.childIDs(of: root.id) == [sibling.id, folder.id])
        #expect(updatedStore.indexedNodeIDs() == [root.id, sibling.id, folder.id, retained.id])
    }

    @Test
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [first, second, sibling],
                first.id: [firstRemoved, firstRetained],
                second.id: [secondRetained, secondRemoved],
            ])

        let updatedStore = store.removingSubtrees(
            rootedAt: [firstRemoved.id, secondRemoved.id]
        )

        #expect(updatedStore.childIDs(of: root.id) == [second.id, sibling.id, first.id])
        #expect(updatedStore.root.allocatedSize == 140)
        #expect(updatedStore.aggregateStats.fileCount == 3)
    }

    @Test
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
            let nodeIndex = try #require(store.nodeIndex(id: child.id))
            return (nodeIndex: nodeIndex, allocatedSize: Int64(index + 1))
        }

        let updatedStore = try store.replacingAllocatedSizes(
            replacements,
            cancellationCheck: {}
        )

        #expect(updatedStore.childIDs(of: root.id) == children.reversed().map(\.id))
        #expect(updatedStore.root.allocatedSize == store.root.allocatedSize)
    }

    @Test
    func testReplacingOneAllocatedSizeReinsertsChangedChild() throws {
        let first = makeFileNode(id: "/root/first.bin", name: "first.bin", size: 40)
        let second = makeFileNode(id: "/root/second.bin", name: "second.bin", size: 30)
        let third = makeFileNode(id: "/root/third.bin", name: "third.bin", size: 20)
        let fourth = makeFileNode(id: "/root/fourth.bin", name: "fourth.bin", size: 10)
        let children = [first, second, third, fourth]
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let secondIndex = try #require(store.nodeIndex(id: second.id))
        let thirdIndex = try #require(store.nodeIndex(id: third.id))

        let movedLater = try store.replacingAllocatedSizes(
            [(nodeIndex: secondIndex, allocatedSize: 5)],
            cancellationCheck: {}
        )
        let movedEarlier = try store.replacingAllocatedSizes(
            [(nodeIndex: thirdIndex, allocatedSize: 50)],
            cancellationCheck: {}
        )

        #expect(movedLater.childIDs(of: root.id) == [first.id, third.id, fourth.id, second.id])
        #expect(movedEarlier.childIDs(of: root.id) == [third.id, first.id, second.id, fourth.id])
    }

    @Test
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
            let nodeIndex = try #require(store.nodeIndex(id: child.id))
            return (nodeIndex: nodeIndex, allocatedSize: Int64(index + 1))
        }
        // The replacement, ancestor, traversal, and repair passes account for
        // four checks per child; this margin reaches the ordering merge.
        let cancellationCheckLimit = children.count * 4 + 12
        var cancellationCheckCount = 0

        #expect(throws: CancellationError.self) {
            try store.replacingAllocatedSizes(
                replacements,
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount == cancellationCheckLimit {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(cancellationCheckCount == cancellationCheckLimit)
        #expect(store.childIDs(of: root.id) == children.map(\.id))
    }

    @Test
    func testReplacingAllocatedSizesRepairsNestedAncestorRollups() throws {
        let a1 = makeFileNode(id: "/root/a/a1.bin", name: "a1.bin", size: 40)
        let a2 = makeFileNode(id: "/root/a/a2.bin", name: "a2.bin", size: 30)
        let dirA = makeDirectoryNode(id: "/root/a", name: "a", children: [a1, a2])
        let b1 = makeFileNode(id: "/root/b/b1.bin", name: "b1.bin", size: 10)
        let dirB = makeDirectoryNode(id: "/root/b", name: "b", children: [b1])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [dirA, dirB])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [dirA, dirB],
                dirA.id: [a1, a2],
                dirB.id: [b1],
            ])
        let a1Index = try #require(store.nodeIndex(id: a1.id))
        let b1Index = try #require(store.nodeIndex(id: b1.id))

        let updatedStore = try store.replacingAllocatedSizes(
            [
                (nodeIndex: a1Index, allocatedSize: 5),
                (nodeIndex: b1Index, allocatedSize: 100),
            ],
            cancellationCheck: {}
        )

        #expect(updatedStore.node(id: dirA.id)?.allocatedSize == 35)
        #expect(updatedStore.node(id: dirA.id)?.descendantFileCount == 2)
        #expect(updatedStore.node(id: dirB.id)?.allocatedSize == 100)
        #expect(updatedStore.root.allocatedSize == 135)
        #expect(updatedStore.root.descendantFileCount == 3)
        #expect(updatedStore.aggregateStats.fileCount == 3)
        #expect(updatedStore.aggregateStats.accessibleItemCount == 6)
        #expect(updatedStore.childIDs(of: dirA.id) == [a2.id, a1.id])
        #expect(updatedStore.childIDs(of: root.id) == [dirB.id, dirA.id])
    }

    @Test
    func testReplacingAllocatedSizesLeavesUnaffectedBranchesUntouched() throws {
        let a1 = makeFileNode(id: "/root/a/a1.bin", name: "a1.bin", size: 20)
        let dirA = makeDirectoryNode(id: "/root/a", name: "a", children: [a1])
        let c1 = makeFileNode(id: "/root/c/c1.bin", name: "c1.bin", size: 9)
        let c2 = makeFileNode(id: "/root/c/c2.bin", name: "c2.bin", size: 4)
        let dirC = makeDirectoryNode(id: "/root/c", name: "c", children: [c1, c2])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [dirA, dirC])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [dirA, dirC],
                dirA.id: [a1],
                dirC.id: [c1, c2],
            ])
        let a1Index = try #require(store.nodeIndex(id: a1.id))

        let updatedStore = try store.replacingAllocatedSizes(
            [(nodeIndex: a1Index, allocatedSize: 50)],
            cancellationCheck: {}
        )

        #expect(updatedStore.node(id: c1.id) == c1)
        #expect(updatedStore.node(id: c2.id) == c2)
        #expect(updatedStore.node(id: dirC.id) == dirC)
        #expect(updatedStore.childIDs(of: dirC.id) == [c1.id, c2.id])
        #expect(updatedStore.childIDs(of: root.id) == [dirA.id, dirC.id])
        #expect(updatedStore.root.allocatedSize == 63)
    }

    @Test
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

        let updatedStore = try #require(store.removingSubtree(id: inaccessible.id))

        #expect(updatedStore.root.allocatedSize == Int64.max)
        #expect(updatedStore.root.logicalSize == Int64.max)
        #expect(updatedStore.root.descendantFileCount == 2)
        #expect(updatedStore.root.isAccessible)
        #expect(updatedStore.aggregateStats.accessibleItemCount == 3)
        #expect(updatedStore.aggregateStats.inaccessibleItemCount == 0)
    }

    @Test
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, accessible],
                folder.id: [inaccessible],
            ])
        let scope = try #require(store.logicalScope(rootedAt: root.id))
        let materializedScope = try scope.materialized(cancellationCheck: {})

        let expected = try #require(materializedScope.removingSubtree(id: inaccessible.id))
        let updatedStore = try #require(scope.removingSubtree(id: inaccessible.id))

        assertEquivalent(updatedStore, expected)
        #expect(updatedStore.root.isAccessible)
        #expect(try #require(updatedStore.node(id: folder.id)).isAccessible)
        #expect(updatedStore.aggregateStats.accessibleItemCount == 3)
        #expect(updatedStore.aggregateStats.inaccessibleItemCount == 0)
        #expect(
            updatedStore.aggregateStats.accessibleItemCount + updatedStore.aggregateStats.inaccessibleItemCount
                == updatedStore.nodeCount)
    }

    @Test
    func testRemovingSubtreeHonorsCancellationDuringCompaction() throws {
        let children = (0..<1_024).map { index in
            makeFileNode(
                id: "/root/folder/item-\(index).bin",
                name: "item-\(index).bin",
                size: 1
            )
        }
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: children)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: children,
            ])
        var checkCount = 0

        #expect(throws: CancellationError.self) {
            try store.removingSubtree(
                id: folder.id,
                cancellationCheck: {
                    checkCount += 1
                    if checkCount == 10 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(store.nodeCount == children.count + 2)
        #expect(store.node(id: folder.id) != nil)
    }

    @Test
    func testRemovingWideSiblingHonorsCancellationAcrossRepairPasses() throws {
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
            #expect(throws: CancellationError.self) {
                try store.removingSubtree(
                    id: children[512].id,
                    cancellationCheck: {
                        cancellationCheckCount += 1
                        if cancellationCheckCount == cancellationCheckLimit {
                            throw CancellationError()
                        }
                    }
                )
            }
            #expect(cancellationCheckCount == cancellationCheckLimit)
        }
        guard let logicalScope = store.logicalScope(rootedAt: root.id) else {
            Issue.record("Expected logical scope.")
            return
        }
        var logicalScopeCheckCount = 0
        #expect(throws: CancellationError.self) {
            try logicalScope.removingSubtree(
                id: children[512].id,
                cancellationCheck: {
                    logicalScopeCheckCount += 1
                    if logicalScopeCheckCount == 10 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(logicalScopeCheckCount == 10)
        #expect(store.nodeCount == children.count + 1)
        #expect(store.node(id: children[512].id) != nil)
    }

    @Test
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
        let scope = try #require(store.logicalScope(rootedAt: root.id))
        // Checks before repair reach the first combined child-order/totals entry.
        // This probe requires the next periodic check after 256 surviving children.
        let firstPeriodicDirectoryTotalsCheck = 37
        var cancellationCheckCount = 0

        #expect(throws: CancellationError.self) {
            try scope.removingSubtree(
                id: children[512].id,
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount == firstPeriodicDirectoryTotalsCheck {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(cancellationCheckCount == firstPeriodicDirectoryTotalsCheck)
    }

    @Test
    func testIndexedNodeIDsPreserveTraversalOrderAndCanExcludeRoot() {
        let first = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 12)
        let nested = makeFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [first, folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [first, folder],
                folder.id: [nested],
            ])

        #expect(store.indexedNodeIDs() == ["/root", "/root/a.txt", "/root/folder", "/root/folder/b.txt"])
        #expect(store.indexedNodeIDs(excludingRoot: true) == ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])

        var iteratedIDs: [String] = []
        store.forEachIndexedNodeID(excludingRoot: true) { id in
            iteratedIDs.append(id)
        }
        #expect(iteratedIDs == ["/root/a.txt", "/root/folder", "/root/folder/b.txt"])
    }

    @Test
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

        #expect(store.nodeIndex(id: folder.id) == folderIndex)
        #expect(store.node(at: nestedIndex)?.id == nested.id)
        #expect(store.parentIndex(of: nestedIndex) == folderIndex)
        #expect(store.childIndices(of: rootIndex) == [siblingIndex, folderIndex])
        #expect(store.parentID(of: nested.id) == folder.id)
        #expect(store.childIDs(of: root.id) == [sibling.id, folder.id])
        #expect(store.indexedNodeIDs() == [root.id, sibling.id, folder.id, nested.id])
        #expect(store.path(to: nested.id).map(\.id) == [root.id, folder.id, nested.id])

        #expect(store.nodesByID == Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }))
        #expect(
            store.childIDsByID == [
                root.id: [sibling.id, folder.id],
                folder.id: [nested.id],
            ])
        #expect(
            store.parentIDByID == [
                folder.id: root.id,
                nested.id: folder.id,
                sibling.id: root.id,
            ])
        #expect(store.aggregateStats.totalAllocatedSize == stats.totalAllocatedSize)
        #expect(store.aggregateStats.totalLogicalSize == stats.totalLogicalSize)
        #expect(store.aggregateStats.fileCount == stats.fileCount)
        #expect(store.aggregateStats.directoryCount == stats.directoryCount)

        let scopedStore = try #require(store.subtree(rootedAt: folder.id))

        #expect(scopedStore.indexedNodeIDs() == [folder.id, nested.id])
        #expect(scopedStore.childIDs(of: folder.id) == [nested.id])
        #expect(scopedStore.parentID(of: nested.id) == folder.id)
        #expect(scopedStore.parentID(of: folder.id) == nil)
        #expect(scopedStore.node(id: sibling.id) == nil)
        #expect(scopedStore.aggregateStats.fileCount == 1)
        #expect(scopedStore.aggregateStats.directoryCount == 1)

        let logicalScope = try #require(store.logicalScope(rootedAt: folder.id))

        #expect(logicalScope.contentID != store.contentID)
        #expect(logicalScope.backingStorageID == store.backingStorageID)
        #expect(logicalScope.backingNodeCapacity == store.nodeCount)
        #expect(scopedStore.backingStorageID != store.backingStorageID)
        #expect(scopedStore.backingNodeCapacity == 2)
        #expect(logicalScope.rootID == folder.id)
        #expect(logicalScope.root == folder)
        #expect(logicalScope.nodeCount == 2)
        #expect(logicalScope.indexedNodeIndices() == [folderIndex, nestedIndex])
        #expect(logicalScope.indexedNodeIDs() == [folder.id, nested.id])
        #expect(logicalScope.indexedNodeIDs(excludingRoot: true) == [nested.id])
        #expect(logicalScope.nodesByID == [folder.id: folder, nested.id: nested])
        #expect(logicalScope.childIDsByID == [folder.id: [nested.id]])
        #expect(logicalScope.parentIDByID == [nested.id: folder.id])
        #expect(logicalScope.childIndices(of: folderIndex) == [nestedIndex])
        #expect(logicalScope.parentIndex(of: nestedIndex) == folderIndex)
        #expect(logicalScope.parentIndex(of: folderIndex) == nil)
        #expect(logicalScope.node(id: root.id) == nil)
        #expect(logicalScope.node(id: sibling.id) == nil)
        #expect(logicalScope.node(at: rootIndex) == nil)
        #expect(logicalScope.parentID(of: folder.id) == nil)
        #expect(logicalScope.path(to: nested.id).map(\.id) == [folder.id, nested.id])
        #expect(logicalScope.isAncestor(folder.id, of: nested.id))
        #expect(!(logicalScope.isAncestor(root.id, of: nested.id)))
        #expect(logicalScope.aggregateStats.fileCount == 1)
        #expect(logicalScope.aggregateStats.directoryCount == 1)
    }

    @Test
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [home, sibling],
                home.id: [summarized, inaccessible],
            ])

        let homeScope = try #require(store.logicalScope(rootedAt: home.id))

        #expect(homeScope.root.allocatedSize == 50)
        #expect(homeScope.aggregateStats.fileCount == 8)
        #expect(homeScope.aggregateStats.directoryCount == 2)
        #expect(homeScope.aggregateStats.accessibleItemCount == 1)
        #expect(homeScope.aggregateStats.inaccessibleItemCount == 2)
        #expect(homeScope.subtreeNodeCount(rootedAt: home.id) == 3)
        #expect(homeScope.subtreeNodeCount(rootedAt: root.id) == 0)

        let nestedScope = try #require(homeScope.logicalScope(rootedAt: summarized.id))

        #expect(nestedScope.backingStorageID == store.backingStorageID)
        #expect(nestedScope.backingNodeCapacity == store.nodeCount)
        #expect(nestedScope.rootID == summarized.id)
        #expect(nestedScope.nodeCount == 1)
        #expect(nestedScope.aggregateStats.fileCount == 7)
        #expect(nestedScope.aggregateStats.directoryCount == 1)
        #expect(nestedScope.node(id: inaccessible.id) == nil)
        #expect(nestedScope.parent(of: summarized.id) == nil)
    }

    @Test
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [outside, home],
                outside.id: [outsideHardLink, outsideClone],
                home.id: [visibleHardLink, visibleClone, regular],
            ])

        #expect(store.childIDs(of: home.id) == [regular.id, visibleClone.id, visibleHardLink.id])

        let scope = try #require(store.logicalScope(rootedAt: home.id))

        #expect(scope.root.allocatedSize == 250)
        #expect(scope.aggregateStats.totalAllocatedSize == 250)
        #expect(scope.node(id: visibleHardLink.id)?.allocatedSize == 100)
        #expect(scope.node(id: visibleClone.id)?.allocatedSize == 100)
        #expect(scope.childIDs(of: home.id) == [visibleClone.id, visibleHardLink.id, regular.id])
        #expect(scope.indexedNodeIDs() == [home.id, visibleClone.id, visibleHardLink.id, regular.id])
        #expect(scope.node(id: outsideHardLink.id) == nil)
        #expect(scope.node(id: outsideClone.id) == nil)

        let materializedScope = try scope.materialized(cancellationCheck: {})
        let expectedFiltered = try #require(
            try materializedScope.removingSubtree(
                id: regular.id,
                cancellationCheck: {}
            ))
        let filtered = try #require(
            try scope.removingSubtree(
                id: regular.id,
                cancellationCheck: {}
            ))
        assertEquivalent(filtered, expectedFiltered)
        #expect(filtered.root.allocatedSize == 200)
        #expect(filtered.nodeCount == 3)
        #expect(filtered.node(id: regular.id) == nil)
        #expect(filtered.node(id: outsideHardLink.id) == nil)
        #expect(filtered.node(id: visibleHardLink.id)?.allocatedSize == 100)
        #expect(filtered.node(id: visibleClone.id)?.allocatedSize == 100)

        let batchRemovalIDs = [regular.id, visibleClone.id]
        let expectedBatch = materializedScope.removingSubtrees(rootedAt: batchRemovalIDs)
        let filteredBatch = scope.removingSubtrees(rootedAt: batchRemovalIDs)
        assertEquivalent(filteredBatch, expectedBatch)

        let rescannedRegular = makeFileNode(id: regular.id, name: regular.name, size: 75)
        let replaced = try #require(
            try scope.replacingSubtree(
                id: regular.id,
                with: FileTreeStore(root: rescannedRegular),
                cancellationCheck: {}
            ))
        #expect(replaced.root.allocatedSize == 275)
        #expect(replaced.node(id: regular.id)?.allocatedSize == 75)
        #expect(replaced.node(id: outsideHardLink.id) == nil)
    }

    @Test
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

        #expect(childMap[root.id] == children.map(\.id))
        #expect(childMap.count == 1)
        #expect(childMap.capacity < children.count)
    }

    @Test
    func testEmptyStoreFallsBackToRootPath() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [])
        let store = FileTreeStore(root: root)

        #expect(store.path(to: nil).map(\.id) == [root.id])
        #expect(store.children(of: nil).count == 0)
    }

    @Test
    func testUnknownNodeFallsBackToRootPath() {
        let child = makeFileNode(id: "/root/child.txt", name: "child.txt", size: 12)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])

        #expect(store.path(to: "/root/missing").map(\.id) == [root.id])
        #expect(store.node(id: "/root/missing") == nil)
        #expect(store.parent(of: "/root/missing") == nil)
    }

    @Test
    func testChildrenPrefixPreservesOrderAndLimit() {
        let children = (0..<6).map { index in
            makeFileNode(id: "/root/item-\(index).txt", name: "item-\(index).txt", size: Int64(10 - index))
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        #expect(store.childrenPrefix(of: root.id, maxCount: 3).map(\.id) == children.prefix(3).map(\.id))
        #expect(store.childrenPrefix(of: root.id, maxCount: 99).count == children.count)
        #expect(store.childrenPrefix(of: root.id, maxCount: 0).isEmpty)
    }

    @Test
    func testChildrenByIDInitializerDropsLaterDuplicateNodeIDs() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [kept, dropped]
            ])

        #expect(store.children(of: root.id).map(\.name) == ["kept.txt"])
        #expect(store.node(id: kept.id)?.name == "kept.txt")
        #expect(store.parent(of: kept.id)?.id == root.id)
        #expect(store.indexedNodeIDs() == [root.id, kept.id])
        #expect(store.root.allocatedSize == kept.allocatedSize)
        #expect(store.root.logicalSize == kept.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == kept.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test
    func testChildrenByIDInitializerRepairsNestedDuplicateTotals() {
        let shared = makeFileNode(id: "/root/shared.txt", name: "shared.txt", size: 12)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [shared])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [shared, folder])

        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [shared, folder],
                folder.id: [shared],
            ])

        #expect(Set(store.children(of: root.id).map(\.id)) == Set([shared.id, folder.id]))
        #expect(store.children(of: folder.id).isEmpty)
        #expect(store.node(id: folder.id)?.allocatedSize == 0)
        #expect(store.node(id: folder.id)?.logicalSize == 0)
        #expect(store.node(id: folder.id)?.descendantFileCount == 0)
        #expect(store.root.allocatedSize == shared.allocatedSize)
        #expect(store.root.logicalSize == shared.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == shared.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test
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

        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [kept, dropped]
            ])

        #expect(store.root.isAccessible)
        #expect(store.aggregateStats.accessibleItemCount == 2)
        #expect(store.aggregateStats.inaccessibleItemCount == 0)
    }

    @Test
    func testChildrenByIDInitializerPreservesSelfInaccessibleDirectoryAfterDroppingDuplicates() {
        let kept = makeFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeFileNode(id: kept.id, name: "dropped.txt", size: 50, isAccessible: false)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, dropped], isAccessible: false)

        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [kept, dropped]
            ])

        #expect(!(store.root.isAccessible))
        #expect(store.aggregateStats.accessibleItemCount == 1)
        #expect(store.aggregateStats.inaccessibleItemCount == 1)
    }

    @Test
    func testChildrenByIDInitializerOrdersByKeptChildrenWhenDuplicateIsLarger() {
        let kept = makeFileNode(id: "/root/a.txt", name: "a.txt", size: 1)
        let sibling = makeFileNode(id: "/root/b.txt", name: "b.txt", size: 50)
        let dropped = makeFileNode(id: kept.id, name: "dropped-a.txt", size: 100)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [kept, sibling, dropped])

        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [kept, sibling, dropped]
            ])

        #expect(store.children(of: root.id).map(\.id) == [sibling.id, kept.id])
        #expect(store.root.allocatedSize == sibling.allocatedSize + kept.allocatedSize)
    }

    @Test
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

        #expect(store.children(of: root.id).map(\.id) == [shared.id, folder.id])
        #expect(store.children(of: folder.id).isEmpty)
        #expect(store.parent(of: shared.id)?.id == root.id)
        #expect(store.indexedNodeIDs() == [root.id, shared.id, folder.id])
        #expect(store.node(id: folder.id)?.allocatedSize == 0)
        #expect(store.node(id: folder.id)?.logicalSize == 0)
        #expect(store.node(id: folder.id)?.descendantFileCount == 0)
        #expect(store.root.allocatedSize == shared.allocatedSize)
        #expect(store.root.logicalSize == shared.logicalSize)
        #expect(store.root.descendantFileCount == 1)
        #expect(store.aggregateStats.totalAllocatedSize == shared.allocatedSize)
        #expect(store.aggregateStats.fileCount == 1)
    }

    @Test
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

        #expect(store.aggregateStats.totalAllocatedSize == precomputedStats.totalAllocatedSize)
        #expect(store.aggregateStats.totalLogicalSize == precomputedStats.totalLogicalSize)
        #expect(store.aggregateStats.fileCount == precomputedStats.fileCount)
        #expect(store.aggregateStats.directoryCount == precomputedStats.directoryCount)
        #expect(store.aggregateStats.accessibleItemCount == precomputedStats.accessibleItemCount)
        #expect(store.aggregateStats.inaccessibleItemCount == precomputedStats.inaccessibleItemCount)
    }

    @Test
    func testFlatInitializerPreservesInaccessibleEmptyMaterializedDirectory() {
        let root = makeDirectoryNode(id: "/root", name: "root", children: [], isAccessible: false)

        let store = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [root.id: []]
        )

        #expect(!(store.root.isAccessible))
        #expect(store.aggregateStats.accessibleItemCount == 0)
        #expect(store.aggregateStats.inaccessibleItemCount == 1)
    }

    @Test
    func testReplacingSubtreeRejectsReplacementIDsOutsideOldSubtree() throws {
        let targetChild = makeFileNode(id: "/root/target/old.txt", name: "old.txt", size: 4)
        let target = makeDirectoryNode(id: "/root/target", name: "target", children: [targetChild])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 8)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [target, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [target, sibling],
                target.id: [targetChild],
            ])
        let collidingReplacementChild = makeFileNode(id: sibling.id, name: "collision.txt", size: 99)
        let replacementRoot = makeDirectoryNode(
            id: target.id,
            name: "target",
            children: [collidingReplacementChild]
        )
        let replacementStore = FileTreeStore(
            root: replacementRoot,
            childrenByID: [
                replacementRoot.id: [collidingReplacementChild]
            ])

        #expect {
            try store.replacingSubtree(
                id: target.id,
                with: replacementStore,
                cancellationCheck: {}
            )
        } throws: { error in
            #expect(error.localizedDescription.contains("reuses an existing node ID"))
            #expect(error.localizedDescription.contains(sibling.id))
            return true
        }
        #expect(store.replacingSubtree(id: target.id, with: replacementStore) == nil)
        #expect(store.node(id: sibling.id)?.name == sibling.name)
    }

    @Test
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

        #expect(
            !(try store.subtreeContainsSharedAllocationMetadata(
                rootedAt: root.id,
                cancellationCheck: {}
            )))
    }

    @Test
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

        #expect(store.rootID == root.id)
        #expect(store.nodesByID[root.id] == root)
        #expect(store.nodesByID[leaf.id] == leaf)
        #expect(store.childIDsByID[root.id] == [sibling.id, folder.id])
        #expect(store.childIDsByID[folder.id] == [leaf.id])
        #expect(store.parentIDByID[sibling.id] == root.id)
        #expect(store.parentIDByID[folder.id] == root.id)
        #expect(store.parentIDByID[leaf.id] == folder.id)
        #expect(store.parentIDByID[root.id] == nil)
        #expect(store.aggregateStats.totalAllocatedSize == 12)
        #expect(store.aggregateStats.fileCount == 2)
    }

    @Test
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

        #expect(store.subtreeNodeCount(rootedAt: root.id, upTo: 4) == 4)
        #expect(store.subtreeNodeCount(rootedAt: root.id, upTo: 0) == 0)
        #expect(store.subtreeNodeCount(rootedAt: "/missing", upTo: 4) == 0)
        #expect(store.subtreeNodeCount(rootedAt: root.id) == files.count + 1)
        #expect(store.subtreeNodeCount(rootedAt: root.id, upTo: .max) == files.count + 1)

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

        #expect(nestedStore.subtreeNodeCount(rootedAt: nestedRoot.id, upTo: 5) == 5)
        #expect(nestedStore.subtreeNodeCount(rootedAt: nestedFolder.id, upTo: 7) == 7)
    }

    @Test
    func testReplacingRootCanChangeRootID() throws {
        let oldChild = makeFileNode(id: "/root/old.txt", name: "old.txt", size: 4)
        let oldRoot = makeDirectoryNode(id: "/root", name: "root", children: [oldChild])
        let store = FileTreeStore(
            root: oldRoot,
            childrenByID: [
                oldRoot.id: [oldChild]
            ])
        let newChild = makeFileNode(id: "/replacement/new.txt", name: "new.txt", size: 12)
        let newRoot = makeDirectoryNode(id: "/replacement", name: "replacement", children: [newChild])
        let replacementStore = FileTreeStore(
            root: newRoot,
            childrenByID: [
                newRoot.id: [newChild]
            ])

        let updated = try #require(
            try store.replacingSubtree(
                id: oldRoot.id,
                with: replacementStore,
                cancellationCheck: {}
            ))

        #expect(updated.root.id == newRoot.id)
        #expect(updated.children(of: newRoot.id).map(\.id) == [newChild.id])
        #expect(updated.node(id: oldRoot.id) == nil)
        #expect(updated.node(id: oldChild.id) == nil)
    }

    @Test
    func testReplacingDisjointSubtreesRebuildsSharedAncestors() throws {
        let oldAFile = makeFileNode(id: "/root/A/old.txt", name: "old.txt", size: 5)
        let oldBFile = makeFileNode(id: "/root/B/old.txt", name: "old.txt", size: 7)
        let oldA = makeDirectoryNode(id: "/root/A", name: "A", children: [oldAFile])
        let oldB = makeDirectoryNode(id: "/root/B", name: "B", children: [oldBFile])
        let sibling = makeFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 3)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [oldA, oldB, sibling],
                oldA.id: [oldAFile],
                oldB.id: [oldBFile],
            ])

        let newAFile = makeFileNode(id: "/root/A/new.txt", name: "new.txt", size: 20)
        let newA = makeDirectoryNode(id: oldA.id, name: "A", children: [newAFile])
        let newBFile = makeFileNode(id: "/root/B/new.txt", name: "new.txt", size: 10)
        let newBExtra = makeFileNode(id: "/root/B/extra.txt", name: "extra.txt", size: 2)
        let newB = makeDirectoryNode(id: oldB.id, name: "B", children: [newBFile, newBExtra])

        let updated = try #require(
            try store.replacingSubtrees(
                [
                    oldA.id: FileTreeStore(root: newA, childrenByID: [newA.id: [newAFile]]),
                    oldB.id: FileTreeStore(root: newB, childrenByID: [newB.id: [newBFile, newBExtra]]),
                ],
                cancellationCheck: {}
            ))

        #expect(updated.node(id: oldAFile.id) == nil)
        #expect(updated.node(id: oldBFile.id) == nil)
        #expect(updated.children(of: root.id).map(\.id) == [newA.id, newB.id, sibling.id])
        #expect(updated.children(of: newA.id).map(\.id) == [newAFile.id])
        #expect(updated.children(of: newB.id).map(\.id) == [newBFile.id, newBExtra.id])
        #expect(updated.root.allocatedSize == 35)
        #expect(updated.root.logicalSize == 35)
        #expect(updated.root.descendantFileCount == 4)
        #expect(updated.aggregateStats.fileCount == 4)
        #expect(updated.aggregateStats.directoryCount == 3)
    }

    @Test
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

        let updated = try #require(
            try store.replacingSubtrees(
                [
                    root.id: FileTreeStore(
                        root: replacementRoot,
                        childrenByID: [replacementRoot.id: [newChild]]
                    )
                ],
                cancellationCheck: {}
            ))

        #expect(updated.rootID == replacementRoot.id)
        #expect(updated.root.allocatedSize == 9)
        #expect(updated.children(of: replacementRoot.id) == [newChild])
        #expect(updated.node(id: root.id) == nil)
    }

    @Test
    func testReplacingSubtreesRejectsOverlappingTargets() throws {
        let leaf = makeFileNode(id: "/root/folder/leaf.txt", name: "leaf.txt", size: 4)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: [leaf],
            ])

        #expect {
            try store.replacingSubtrees(
                [
                    folder.id: FileTreeStore(root: folder, childrenByID: [folder.id: [leaf]]),
                    leaf.id: FileTreeStore(root: leaf),
                ],
                cancellationCheck: {}
            )
        } throws: { error in
            #expect(error.localizedDescription.contains("must be disjoint"))
            return true
        }
    }

    @Test
    func testReplacingSubtreesRejectsIDsSharedByReplacementTrees() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let sharedID = "/root/shared.txt"
        let firstShared = makeFileNode(id: sharedID, name: "shared.txt", size: 2)
        let secondShared = makeFileNode(id: sharedID, name: "shared.txt", size: 3)

        #expect {
            try store.replacingSubtrees(
                [
                    oldA.id: FileTreeStore(root: firstShared),
                    oldB.id: FileTreeStore(root: secondShared),
                ],
                cancellationCheck: {}
            )
        } throws: { error in
            #expect(error.localizedDescription.contains(sharedID))
            return true
        }
        #expect(store.root.allocatedSize == 2)
    }

    @Test
    func testReplacingSubtreesRejectsIDRemovedByAnotherTarget() throws {
        let oldA = makeFileNode(id: "/root/A", name: "A", size: 1)
        let oldB = makeFileNode(id: "/root/B", name: "B", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [oldA, oldB])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let replacementB = makeFileNode(id: "/root/replacement-B", name: "replacement-B", size: 2)

        #expect {
            try store.replacingSubtrees(
                [
                    oldA.id: FileTreeStore(root: oldB),
                    oldB.id: FileTreeStore(root: replacementB),
                ],
                cancellationCheck: {}
            )
        } throws: { error in
            #expect(error.localizedDescription.contains(oldB.id))
            return true
        }
    }

    @Test
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

        let updated = try #require(
            try store.replacingSubtrees(
                [
                    oldA.id: FileTreeStore(root: firstLink),
                    oldB.id: FileTreeStore(root: secondLink),
                ],
                cancellationCheck: {}
            ))

        #expect(updated.root.allocatedSize == 4_096)
        #expect(updated.root.logicalSize == 8_192)
        #expect(updated.node(id: firstLink.id)?.allocatedSize == 4_096)
        #expect(updated.node(id: secondLink.id)?.allocatedSize == 0)
    }

    @Test
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

        #expect(store.path(to: leafID).count == depth + 2)
        #expect(store.aggregateStats.directoryCount == depth + 1)
        #expect(store.aggregateStats.fileCount == 1)

        let updatedStore = try #require(store.removingSubtree(id: leafID))

        #expect(updatedStore.nodeCount == depth + 1)
        #expect(updatedStore.root.allocatedSize == 0)
        #expect(updatedStore.aggregateStats.directoryCount == depth + 1)
        #expect(updatedStore.aggregateStats.fileCount == 0)
    }

    @Test
    func testSubtreeProjectionHonorsCancellationAcrossWideDirectories() throws {
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

        #expect(throws: CancellationError.self) {
            try store.subtree(
                rootedAt: root.id,
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount >= 4 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(cancellationCheckCount >= 4)

        cancellationCheckCount = 0
        #expect(throws: CancellationError.self) {
            try store.logicalScope(
                rootedAt: root.id,
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount >= 4 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(cancellationCheckCount >= 4)
    }

    @Test
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
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
        let grownRemainder = try #require(grown.node(id: remainder.id))

        #expect(grown.contentID != store.contentID)
        #expect(grown.backingStorageID != store.backingStorageID)
        #expect(grown.root.allocatedSize == 1_200 * mebibyte)
        #expect(grownRemainder.allocatedSize == 700 * mebibyte)
        #expect(grownRemainder.name == "System & Unattributed")
        #expect(grownRemainder.isSynthetic)
        #expect(grownRemainder.isAccessible)
        #expect(grownRemainder.logicalSize == 0)
        #expect(grown.childIDs(of: root.id) == [remainder.id, folder.id, payload.id])
        #expect(grown.indexedNodeIDs() == [root.id, remainder.id, folder.id, nested.id, payload.id])
        #expect(grown.parentID(of: remainder.id) == root.id)
        #expect(grown.parentID(of: nested.id) == folder.id)
        #expect(grown.aggregateStats.fileCount == originalStats.fileCount)
        #expect(grown.aggregateStats.directoryCount == originalStats.directoryCount)
        #expect(grown.aggregateStats.accessibleItemCount == originalStats.accessibleItemCount)
        #expect(grown.aggregateStats.inaccessibleItemCount == originalStats.inaccessibleItemCount)

        let shrunk = VolumeCapacityAccounting.reconciledStore(
            grown,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 532 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: true
        )
        let shrunkRemainder = try #require(shrunk.node(id: remainder.id))

        #expect(shrunk.contentID != grown.contentID)
        #expect(shrunk.root.allocatedSize == 532 * mebibyte)
        #expect(shrunkRemainder.allocatedSize == 32 * mebibyte)
        #expect(shrunkRemainder.name == "Excluded & Unattributed")
        #expect(shrunk.childIDs(of: root.id) == [folder.id, payload.id, remainder.id])
        #expect(shrunk.indexedNodeIDs() == [root.id, folder.id, nested.id, payload.id, remainder.id])
        #expect(shrunk.aggregateStats.fileCount == originalStats.fileCount)
        #expect(shrunk.aggregateStats.directoryCount == originalStats.directoryCount)
        #expect(shrunk.aggregateStats.accessibleItemCount == originalStats.accessibleItemCount)
        #expect(shrunk.aggregateStats.inaccessibleItemCount == originalStats.inaccessibleItemCount)
    }

    @Test
    func testVolumeReconciliationAddsAndRemovesRemainderWithoutMaterializingTreeMaps() {
        let mebibyte: Int64 = 1_024 * 1_024
        let nested = makeFileNode(id: "/root/folder/nested.bin", name: "nested.bin", size: 100 * mebibyte)
        let folder = makeDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let payload = makeFileNode(id: "/root/payload.bin", name: "payload.bin", size: 100 * mebibyte)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [folder, payload])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
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

        #expect(grown.nodeCount == store.nodeCount + 1)
        #expect(grown.node(id: remainderID)?.allocatedSize == 200 * mebibyte)
        #expect(grown.parentID(of: nested.id) == folder.id)
        #expect(grown.aggregateStats.accessibleItemCount == originalStats.accessibleItemCount + 1)

        let restored = VolumeCapacityAccounting.reconciledStore(
            grown,
            target: target,
            capacity: VolumeCapacitySnapshot(
                totalCapacity: 200 * mebibyte,
                availableCapacity: 0
            ),
            hasActiveExclusions: false
        )

        #expect(restored.nodeCount == store.nodeCount)
        #expect(restored.node(id: remainderID) == nil)
        #expect(restored.indexedNodeIDs() == store.indexedNodeIDs())
        #expect(restored.parentID(of: nested.id) == folder.id)
        #expect(restored.aggregateStats.totalAllocatedSize == originalStats.totalAllocatedSize)
        #expect(restored.aggregateStats.totalLogicalSize == originalStats.totalLogicalSize)
        #expect(restored.aggregateStats.fileCount == originalStats.fileCount)
        #expect(restored.aggregateStats.directoryCount == originalStats.directoryCount)
        #expect(restored.aggregateStats.accessibleItemCount == originalStats.accessibleItemCount)
        #expect(restored.aggregateStats.inaccessibleItemCount == originalStats.inaccessibleItemCount)
    }
}

private func assertEquivalent(
    _ actual: FileTreeStore,
    _ expected: FileTreeStore,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let expectedNodeIDs = expected.indexedNodeIDs()
    #expect(actual.indexedNodeIDs() == expectedNodeIDs, sourceLocation: sourceLocation)
    #expect(actual.nodesByID == expected.nodesByID, sourceLocation: sourceLocation)
    #expect(actual.childIDsByID == expected.childIDsByID, sourceLocation: sourceLocation)
    #expect(actual.parentIDByID == expected.parentIDByID, sourceLocation: sourceLocation)
    #expect(
        actual.aggregateStats.totalAllocatedSize == expected.aggregateStats.totalAllocatedSize,
        sourceLocation: sourceLocation)
    #expect(
        actual.aggregateStats.totalLogicalSize == expected.aggregateStats.totalLogicalSize,
        sourceLocation: sourceLocation)
    #expect(actual.aggregateStats.fileCount == expected.aggregateStats.fileCount, sourceLocation: sourceLocation)
    #expect(
        actual.aggregateStats.directoryCount == expected.aggregateStats.directoryCount, sourceLocation: sourceLocation)
    #expect(
        actual.aggregateStats.accessibleItemCount == expected.aggregateStats.accessibleItemCount,
        sourceLocation: sourceLocation)
    #expect(
        actual.aggregateStats.inaccessibleItemCount == expected.aggregateStats.inaccessibleItemCount,
        sourceLocation: sourceLocation)
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
