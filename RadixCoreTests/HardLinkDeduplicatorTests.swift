import XCTest
@testable import RadixCore

final class HardLinkDeduplicatorTests: XCTestCase {
    func testHardLinkDedupRebuildsOnlyAffectedAncestorChains() {
        let rootID = "/root"
        let affectedID = "/root/Affected"
        let firstLinkID = "/root/Affected/a.bin"
        let duplicateLinkID = "/root/Affected/z.bin"
        let unrelatedCount = 64

        var nodesByID: [String: FileNodeRecord] = [
            affectedID: makeDirectory(id: affectedID, allocatedSize: 200, descendantFileCount: 2),
            firstLinkID: makeFile(id: firstLinkID, allocatedSize: 100),
            duplicateLinkID: makeFile(id: duplicateLinkID, allocatedSize: 100)
        ]
        var childIDsByID: [String: [String]] = [
            affectedID: [firstLinkID, duplicateLinkID]
        ]
        var parentIDByID: [String: String] = [
            affectedID: rootID,
            firstLinkID: affectedID,
            duplicateLinkID: affectedID
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
        let store = HardLinkDeduplicator.deduplicatedStore(
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
            hardLinkClaims: [
                HardLinkClaim(identity: identity, ownerNodeID: firstLinkID, path: firstLinkID, allocatedSize: 100),
                HardLinkClaim(identity: identity, ownerNodeID: duplicateLinkID, path: duplicateLinkID, allocatedSize: 100)
            ],
            minimumAllocatedSizeByNodeID: [:]
        )

        XCTAssertEqual(store.node(id: duplicateLinkID)?.allocatedSize, 0)
        XCTAssertEqual(store.node(id: affectedID)?.allocatedSize, 100)
        XCTAssertEqual(store.root.allocatedSize, rootAllocatedSize - 100)

        for index in 0..<unrelatedCount {
            let directoryID = "/root/Unrelated\(index)"
            XCTAssertEqual(
                store.childIDsByID[directoryID],
                ["\(directoryID)/a-small.bin", "\(directoryID)/z-large.bin"]
            )
        }
    }

    func testRemovingWinningOwnerRestoresRemainingHardLinkSize() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let winner = makeFile(id: "/root/a.bin", allocatedSize: 100, identity: identity)
        let remaining = makeFile(id: "/root/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let root = makeDirectory(id: "/root", children: [winner, remaining])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [winner, remaining]])

        let updatedStore = try XCTUnwrap(store.removingSubtree(id: winner.id))

        XCTAssertNil(updatedStore.node(id: winner.id))
        XCTAssertEqual(updatedStore.node(id: remaining.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.root.allocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 100)
    }

    func testScopingToHardLinkLoserRestoresVisibleClaimSize() throws {
        let identity = FileIdentity(device: 1, inode: 43)
        let winner = makeFile(id: "/root/A/a.bin", allocatedSize: 100, identity: identity)
        let loser = makeFile(id: "/root/Z/z.bin", allocatedSize: 0, unduplicatedAllocatedSize: 100, identity: identity)
        let winnerDirectory = makeDirectory(id: "/root/A", children: [winner])
        let loserDirectory = makeDirectory(id: "/root/Z", children: [loser])
        let root = makeDirectory(id: "/root", children: [winnerDirectory, loserDirectory])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [winnerDirectory, loserDirectory],
            winnerDirectory.id: [winner],
            loserDirectory.id: [loser]
        ])

        let scopedStore = try XCTUnwrap(store.subtree(rootedAt: loserDirectory.id))

        XCTAssertEqual(scopedStore.root.allocatedSize, 100)
        XCTAssertEqual(scopedStore.node(id: loser.id)?.allocatedSize, 100)
        XCTAssertNil(scopedStore.node(id: winner.id))
    }

    func testReplacingSummarizedParentRebalancesVisibleHardLinks() throws {
        let identity = FileIdentity(device: 1, inode: 44)
        let siblingFile = makeFile(id: "/root/sibling/a.bin", allocatedSize: 100, identity: identity)
        let sibling = makeDirectory(id: "/root/sibling", children: [siblingFile])
        let summarized = makeDirectory(id: "/root/folder", allocatedSize: 0, descendantFileCount: 1)
        let root = makeDirectory(id: "/root", children: [sibling, summarized])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [sibling, summarized],
            sibling.id: [siblingFile]
        ])

        let replacementFile = makeFile(
            id: "/root/folder/z.bin",
            allocatedSize: 0,
            unduplicatedAllocatedSize: 100,
            identity: identity
        )
        let replacementRoot = makeDirectory(id: summarized.id, children: [replacementFile])
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [replacementFile]
        ])

        let updatedStore = try XCTUnwrap(store.replacingSubtree(id: summarized.id, with: replacementStore))

        XCTAssertEqual(updatedStore.node(id: replacementFile.id)?.allocatedSize, 100)
        XCTAssertEqual(updatedStore.node(id: siblingFile.id)?.allocatedSize, 0)
        XCTAssertEqual(updatedStore.root.allocatedSize, 100)
        XCTAssertEqual(updatedStore.aggregateStats.totalAllocatedSize, 100)
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
