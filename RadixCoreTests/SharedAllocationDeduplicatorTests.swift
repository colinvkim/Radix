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
    func testHardLinkDedupRebuildsOnlyAffectedAncestorChains() {
        let rootID = "/root"
        let affectedID = "/root/Affected"
        let firstLinkID = "/root/Affected/a.bin"
        let duplicateLinkID = "/root/Affected/z.bin"
        let unrelatedCount = 64

        var nodesByID: [String: FileNodeRecord] = [
            affectedID: makeDirectory(id: affectedID, allocatedSize: 200, descendantFileCount: 2),
            firstLinkID: makeFile(id: firstLinkID, allocatedSize: 100),
            duplicateLinkID: makeFile(id: duplicateLinkID, allocatedSize: 100),
        ]
        var childIDsByID: [String: [String]] = [
            affectedID: [firstLinkID, duplicateLinkID]
        ]
        var parentIDByID: [String: String] = [
            affectedID: rootID,
            firstLinkID: affectedID,
            duplicateLinkID: affectedID,
        ]
        var rootChildIDs = [affectedID]

        for index in 0..<unrelatedCount {
            let directoryID = "/root/Unrelated\(index)"
            let smallID = "\(directoryID)/a-small.bin"
            let largeID = "\(directoryID)/z-large.bin"

            nodesByID[directoryID] = makeDirectory(id: directoryID, allocatedSize: 21, descendantFileCount: 2)
            nodesByID[smallID] = makeFile(id: smallID, allocatedSize: 1)
            nodesByID[largeID] = makeFile(id: largeID, allocatedSize: 20)
            childIDsByID[directoryID] = [smallID, largeID]
            parentIDByID[directoryID] = rootID
            parentIDByID[smallID] = directoryID
            parentIDByID[largeID] = directoryID
            rootChildIDs.append(directoryID)
        }

        let rootAllocatedSize = Int64(200 + unrelatedCount * 21)
        nodesByID[rootID] = makeDirectory(
            id: rootID,
            allocatedSize: rootAllocatedSize,
            descendantFileCount: 2 + unrelatedCount * 2
        )
        childIDsByID[rootID] = rootChildIDs

        let identity = FileIdentity(device: 1, inode: 42)
        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: rootAllocatedSize,
                totalLogicalSize: rootAllocatedSize,
                fileCount: 2 + unrelatedCount * 2,
                directoryCount: 2 + unrelatedCount,
                accessibleItemCount: nodesByID.count,
                inaccessibleItemCount: 0
            ),
            sharedAllocationClaims: [
                SharedAllocationClaim(
                    identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                SharedAllocationClaim(
                    identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100),
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        #expect(store.node(id: duplicateLinkID)?.allocatedSize == 0)
        #expect(store.node(id: affectedID)?.allocatedSize == 100)
        #expect(store.root.allocatedSize == rootAllocatedSize - 100)

        for index in 0..<unrelatedCount {
            let directoryID = "/root/Unrelated\(index)"
            #expect(store.childIDsByID[directoryID] == ["\(directoryID)/a-small.bin", "\(directoryID)/z-large.bin"])
        }
    }

    @Test
    func testHardLinkDedupRebuildsDeepAncestorsBottomUp() {
        let rootID = "/root"
        let parentID = "/root/Parent"
        let nestedID = "/root/Parent/Nested"
        let firstLinkID = "/root/Parent/Nested/a.bin"
        let duplicateLinkID = "/root/Parent/Nested/z.bin"
        let siblingID = "/root/sibling.bin"
        let identity = FileIdentity(device: 1, inode: 45)
        let totalAllocatedSize: Int64 = 250

        let store = SharedAllocationDeduplicator.deduplicatedStore(
            rootID: rootID,
            nodesByID: [
                rootID: makeDirectory(id: rootID, allocatedSize: totalAllocatedSize, descendantFileCount: 3),
                parentID: makeDirectory(id: parentID, allocatedSize: 200, descendantFileCount: 2),
                nestedID: makeDirectory(id: nestedID, allocatedSize: 200, descendantFileCount: 2),
                firstLinkID: makeFile(id: firstLinkID, allocatedSize: 100),
                duplicateLinkID: makeFile(id: duplicateLinkID, allocatedSize: 100),
                siblingID: makeFile(id: siblingID, allocatedSize: 50, linkCount: 1),
            ],
            childIDsByID: [
                rootID: [parentID, siblingID],
                parentID: [nestedID],
                nestedID: [firstLinkID, duplicateLinkID],
            ],
            parentIDByID: [
                parentID: rootID,
                nestedID: parentID,
                firstLinkID: nestedID,
                duplicateLinkID: nestedID,
                siblingID: rootID,
            ],
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: totalAllocatedSize,
                totalLogicalSize: totalAllocatedSize,
                fileCount: 3,
                directoryCount: 3,
                accessibleItemCount: 6,
                inaccessibleItemCount: 0
            ),
            sharedAllocationClaims: [
                SharedAllocationClaim(
                    identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                SharedAllocationClaim(
                    identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100),
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        #expect(store.node(id: duplicateLinkID)?.allocatedSize == 0)
        #expect(store.node(id: nestedID)?.allocatedSize == 100)
        #expect(store.node(id: parentID)?.allocatedSize == 100)
        #expect(store.root.allocatedSize == 150)
        #expect(store.aggregateStats.totalAllocatedSize == 150)
    }

    @Test
    func testRemovingWinningOwnerRestoresRemainingHardLinkSize() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let winner = makeFile(id: "/root/a.bin", allocatedSize: 100, identity: identity)
        let remaining = makeFile(
            id: "/root/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let root = makeDirectory(id: "/root", children: [winner, remaining])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [winner, remaining]])

        let updatedStore = try #require(store.removingSubtree(id: winner.id))

        #expect(updatedStore.node(id: winner.id) == nil)
        #expect(updatedStore.node(id: remaining.id)?.allocatedSize == 100)
        #expect(updatedStore.root.allocatedSize == 100)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 100)
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

        #expect(updatedStore.node(id: promoted.id)?.allocatedSize == 100)
        #expect(updatedStore.node(id: secondDirectory.id)?.allocatedSize == 150)
        #expect(updatedStore.childIDs(of: secondDirectory.id) == [promoted.id, sibling.id])
        #expect(updatedStore.root.allocatedSize == 150)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 150)
    }

    @Test
    func testBatchRemovalPromotesRemainingHardLinkOwnerOnce() {
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

        let updatedStore = store.removingSubtrees(rootedAt: [firstDirectory.id, unrelated.id])

        #expect(updatedStore.node(id: firstDirectory.id) == nil)
        #expect(updatedStore.node(id: unrelated.id) == nil)
        #expect(updatedStore.node(id: loser.id)?.allocatedSize == 100)
        #expect(updatedStore.node(id: secondDirectory.id)?.allocatedSize == 100)
        #expect(updatedStore.root.allocatedSize == 100)
        #expect(updatedStore.aggregateStats.totalAllocatedSize == 100)
        #expect(updatedStore.aggregateStats.fileCount == 1)
    }

    @Test
    func testRebalancingAlreadyCorrectOwnersReturnsOriginalStore() throws {
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

        let rebalancedStore = try SharedAllocationDeduplicator.rebalancedStore(store)

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

        let updatedStore = try #require(store.replacingSubtree(id: summarized.id, with: replacementStore))

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
