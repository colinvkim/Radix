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

    func testDirectoryBuilderAppliesCoreTreeInvariants() {
        let small = makeNode(id: "/root/a.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 10)
        let largeInaccessible = makeNode(id: "/root/z.txt", isDirectory: false, isSynthetic: false, isAccessible: false, allocatedSize: 20)
        let symlink = FileNode(
            id: "/root/link",
            url: URL(filePath: "/root/link"),
            name: "link",
            isDirectory: false,
            isSymbolicLink: true,
            allocatedSize: 5,
            logicalSize: 5,
            children: [],
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )

        let directory = FileNode.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [small, largeInaccessible, symlink],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(directory.children.map(\.name), ["z.txt", "a.txt", "link"])
        XCTAssertEqual(directory.allocatedSize, 35)
        XCTAssertEqual(directory.logicalSize, 35)
        XCTAssertEqual(directory.descendantFileCount, 2)
        XCTAssertFalse(directory.isAccessible)
        XCTAssertFalse(directory.isAutoSummarized)
    }

    func testSnapshotReplacingNodeRebuildsAncestorsAndPreservesWarnings() throws {
        let staleLeaf = makeNode(id: "/root/folder/stale.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 5)
        let summarizedFolder = FileNode(
            id: "/root/folder",
            url: URL(filePath: "/root/folder", directoryHint: .isDirectory),
            name: "folder",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 5,
            logicalSize: 5,
            children: [],
            descendantFileCount: 42,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let sibling = makeNode(id: "/root/sibling.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 8)
        let root = FileNode.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [summarizedFolder, sibling],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        let originalWarning = ScanWarning(path: "/root/folder", message: "original", category: .fileSystem)
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: URL(filePath: "/root", directoryHint: .isDirectory)),
            root: root,
            startedAt: .distantPast,
            finishedAt: .now,
            scanWarnings: [originalWarning],
            aggregateStats: root.aggregateStats,
            isComplete: true
        )

        let inaccessibleExpandedLeaf = makeNode(
            id: "/root/folder/z.txt",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: false,
            allocatedSize: 20
        )
        let accessibleExpandedLeaf = makeNode(
            id: "/root/folder/a.txt",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 10
        )
        let expandedFolder = FileNode.directory(
            id: "/root/folder",
            url: URL(filePath: "/root/folder", directoryHint: .isDirectory),
            name: "folder",
            children: [accessibleExpandedLeaf, inaccessibleExpandedLeaf],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let expansionWarning = ScanWarning(path: "/root/folder/z.txt", message: "expanded", category: .permissionDenied)

        let updatedSnapshot = try XCTUnwrap(
            snapshot.replacingNode(
                id: summarizedFolder.id,
                with: expandedFolder,
                additionalWarnings: [expansionWarning]
            )
        )

        let updatedFolder = try XCTUnwrap(updatedSnapshot.root.children.first(where: { $0.id == summarizedFolder.id }))
        XCTAssertFalse(updatedFolder.isAutoSummarized)
        XCTAssertEqual(updatedFolder.children.map(\.name), ["z.txt", "a.txt"])
        XCTAssertEqual(updatedFolder.descendantFileCount, 2)
        XCTAssertFalse(updatedFolder.isAccessible)
        XCTAssertEqual(updatedSnapshot.aggregateStats.fileCount, 3)
        XCTAssertFalse(updatedSnapshot.root.isAccessible)
        XCTAssertEqual(updatedSnapshot.scanWarnings.count, 2)
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [originalWarning.path, expansionWarning.path])
        XCTAssertNotEqual(staleLeaf.id, updatedFolder.children.first?.id)
    }

    func testSnapshotReplacingMissingNodeReturnsNil() {
        let root = FileNode.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: URL(filePath: "/root", directoryHint: .isDirectory)),
            root: root,
            startedAt: .distantPast,
            finishedAt: .now,
            scanWarnings: [],
            aggregateStats: root.aggregateStats,
            isComplete: true
        )

        XCTAssertNil(snapshot.replacingNode(id: "/root/missing", with: root))
    }

    func testPostTrashActionMatchesCurrentSelectionPolicy() {
        XCTAssertEqual(
            ScanPostTrashAction.afterRemovingNode(activeTargetID: "/scan/root", removedNodeID: "/scan/root"),
            .clearActiveScan
        )
        XCTAssertEqual(
            ScanPostTrashAction.afterRemovingNode(activeTargetID: "/scan/root", removedNodeID: "/scan/root/file.txt"),
            .rescanActiveScan
        )
        XCTAssertEqual(
            ScanPostTrashAction.afterRemovingNode(activeTargetID: nil, removedNodeID: "/scan/root"),
            .none
        )
    }

    func testSnapshotReplacingNodeDeduplicatesWarningsByContent() throws {
        let child = makeNode(id: "/root/folder", isDirectory: true, isSynthetic: false, isAccessible: true)
        let root = FileNode.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [child],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        let existingWarning = ScanWarning(
            path: "/root/folder",
            message: "Permission denied",
            category: .permissionDenied
        )
        let duplicateWarning = ScanWarning(
            path: "/root/folder",
            message: "Permission denied",
            category: .permissionDenied
        )
        let distinctWarning = ScanWarning(
            path: "/root/folder/other",
            message: "File system error",
            category: .fileSystem
        )

        let snapshot = ScanSnapshot(
            target: ScanTarget(url: URL(filePath: "/root", directoryHint: .isDirectory)),
            root: root,
            startedAt: .distantPast,
            finishedAt: .now,
            scanWarnings: [existingWarning],
            aggregateStats: root.aggregateStats,
            isComplete: true
        )

        let replacement = FileNode.directory(
            id: "/root/folder",
            url: URL(filePath: "/root/folder", directoryHint: .isDirectory),
            name: "folder",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        let updatedSnapshot = try XCTUnwrap(
            snapshot.replacingNode(
                id: child.id,
                with: replacement,
                additionalWarnings: [duplicateWarning, distinctWarning]
            )
        )

        XCTAssertEqual(updatedSnapshot.scanWarnings.count, 2)
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [
            existingWarning.path,
            distinctWarning.path
        ])
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.message), [
            existingWarning.message,
            distinctWarning.message
        ])
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        isSynthetic: Bool,
        isAccessible: Bool,
        allocatedSize: Int64 = 64
    ) -> FileNode {
        FileNode(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent.isEmpty ? id : URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
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
