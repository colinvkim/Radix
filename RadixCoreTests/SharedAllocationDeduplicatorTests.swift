import Foundation
import Testing

@testable import RadixCore

struct SharedAllocationDeduplicatorTests {
    @Test
    func testClaimEvaluatesPathOnlyForSharedAllocationCandidates() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        var pathEvaluationCount = 0
        func evaluatedPath() -> String {
            pathEvaluationCount += 1
            return "/root/file.bin"
        }
        let ordinaryMetadata = NodeMetadata(
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            logicalSize: 100,
            allocatedSize: 100,
            lastModified: nil,
            isReadable: true,
            volumeCapacity: nil,
            fileIdentity: identity,
            linkCount: 1
        )

        #expect(
            SharedAllocationDeduplicator.claim(
                for: ordinaryMetadata,
                ownerNodeID: "/root",
                path: evaluatedPath()
            ) == nil)
        #expect(pathEvaluationCount == 0)

        let hardLinkMetadata = NodeMetadata(
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            logicalSize: 100,
            allocatedSize: 100,
            lastModified: nil,
            isReadable: true,
            volumeCapacity: nil,
            fileIdentity: identity,
            linkCount: 2
        )
        let claim = try #require(
            SharedAllocationDeduplicator.claim(
                for: hardLinkMetadata,
                ownerNodeID: "/root",
                path: evaluatedPath()
            ))

        #expect(pathEvaluationCount == 1)
        #expect(claim.path == "/root/file.bin")
    }

    @Test
    func testRemovingWinningOwnerRepairsAndResortsPromotedOwnerAncestors() throws {
        let identity = FileIdentity(device: 1, inode: 43)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let promoted = makeFile(
            id: "/root/B/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let sibling = makeFile(id: "/root/B/m.bin", allocatedSize: 50, linkCount: 1)
        let firstDirectory = makeDirectory(id: "/root/A", children: [winner])
        let secondDirectory = makeDirectory(id: "/root/B", children: [sibling, promoted])
        let root = makeDirectory(id: "/root", children: [firstDirectory, secondDirectory])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [firstDirectory, secondDirectory],
                firstDirectory.id: [winner],
                secondDirectory.id: [sibling, promoted],
            ])

        let updatedStore = try #require(store.removingSubtree(id: firstDirectory.id))

        #expect(updatedStore.node(id: winner.id) == nil)
        #expect(updatedStore.node(id: promoted.id)?.allocatedSize == 100)
        #expect(updatedStore.node(id: secondDirectory.id)?.allocatedSize == 150)
        #expect(updatedStore.childIDs(of: secondDirectory.id) == [promoted.id, sibling.id])
        #expect(updatedStore.root.allocatedSize == 150)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 150)
    }

    @Test
    func testBatchRemovalPromotesRemainingHardLinkOwnerOnce() throws {
        let identity = FileIdentity(device: 1, inode: 142)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(
            id: "/root/B/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let unrelated = makeFile(id: "/root/unrelated.bin", allocatedSize: 25, linkCount: 1)
        let firstDirectory = makeDirectory(id: "/root/A", children: [winner])
        let secondDirectory = makeDirectory(id: "/root/B", children: [loser])
        let root = makeDirectory(id: "/root", children: [firstDirectory, secondDirectory, unrelated])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [firstDirectory, secondDirectory, unrelated],
                firstDirectory.id: [winner],
                secondDirectory.id: [loser],
            ])

        let updatedStore = try store.removingSubtrees(rootedAt: [firstDirectory.id, unrelated.id], cancellationCheck: {})

        #expect(updatedStore.node(id: firstDirectory.id) == nil)
        #expect(updatedStore.node(id: unrelated.id) == nil)
        #expect(updatedStore.node(id: loser.id)?.allocatedSize == 100)
        #expect(updatedStore.node(id: secondDirectory.id)?.allocatedSize == 100)
        #expect(updatedStore.root.allocatedSize == 100)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 100)
        #expect(updatedStore.aggregateStats.fileCount == 1)
    }

    @Test
    func testRootReplacementKeepsAlreadyBalancedContentIdentity() throws {
        let identity = FileIdentity(device: 1, inode: 99)
        let winner = makeFile(id: "/root/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(
            id: "/root/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let root = makeDirectory(id: "/root", children: [winner, loser])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [winner, loser]])

        let rebalancedStore = try #require(try FileTreeStore(root: root).replacingSubtrees(
            [root.id: store], cancellationCheck: {}
        ))

        #expect(rebalancedStore.contentID == store.contentID)
        #expect(rebalancedStore.root == store.root)
    }

    @Test
    func testScopingToHardLinkLoserRestoresVisibleClaimSize() throws {
        let identity = FileIdentity(device: 1, inode: 43)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(id: "/root/Z/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let winnerDirectory = makeDirectory(id: "/root/A", children: [winner])
        let loserDirectory = makeDirectory(id: "/root/Z", children: [loser])
        let root = makeDirectory(id: "/root", children: [winnerDirectory, loserDirectory])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [winnerDirectory, loserDirectory],
                winnerDirectory.id: [winner],
                loserDirectory.id: [loser],
            ])

        let scopedStore = try #require(store.subtree(rootedAt: loserDirectory.id))

        #expect(scopedStore.root.allocatedSize == 100)
        #expect(scopedStore.node(id: loser.id)?.allocatedSize == 100)
        #expect(scopedStore.node(id: winner.id) == nil)
    }

    @Test
    func testReplacingSummarizedParentRebalancesVisibleHardLinks() throws {
        let identity = FileIdentity(device: 1, inode: 44)
        let siblingFile = makeFile(id: "/root/sibling/a.bin", allocatedSize: 100, identity: identity)
        let sibling = makeDirectory(id: "/root/sibling", children: [siblingFile])
        let summarized = makeDirectory(id: "/root/folder", allocatedSize: 0, descendantFileCount: 1)
        let root = makeDirectory(id: "/root", children: [sibling, summarized])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [sibling, summarized],
                sibling.id: [siblingFile],
            ])

        let replacementFile = makeFile(
            id: "/root/folder/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let replacementRoot = makeDirectory(id: summarized.id, children: [replacementFile])
        let replacementStore = FileTreeStore(
            root: replacementRoot,
            childrenByID: [
                replacementRoot.id: [replacementFile]
            ])

        let updatedStore = try #require(try store.replacingSubtrees([summarized.id: replacementStore], cancellationCheck: {}))

        #expect(updatedStore.node(id: replacementFile.id)?.allocatedSize == 100)
        #expect(updatedStore.node(id: siblingFile.id)?.allocatedSize == 0)
        #expect(updatedStore.root.allocatedSize == 100)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 100)
    }

    private func makeDirectory(
        id: String,
        allocatedSize: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        makeNode(
            id: id,
            isDirectory: true,
            allocatedSize: allocatedSize,
            descendantFileCount: descendantFileCount
        )
    }

    private func makeDirectory(id: String, children: [FileNodeRecord]) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: URL(filePath: id).lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
    }

    private func makeFile(
        id: String,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 2
    ) -> FileNodeRecord {
        makeNode(
            id: id,
            isDirectory: false,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            descendantFileCount: 1,
            identity: identity,
            linkCount: linkCount
        )
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        descendantFileCount: Int,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 1
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: linkCount,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}
