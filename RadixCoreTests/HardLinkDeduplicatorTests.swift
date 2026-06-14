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

    private func makeFile(id: String, allocatedSize: Int64) -> FileNodeRecord {
        makeNode(
            id: id,
            isDirectory: false,
            allocatedSize: allocatedSize,
            descendantFileCount: 1
        )
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}
