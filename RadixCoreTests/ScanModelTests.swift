import XCTest
@testable import RadixCore

final class ScanModelTests: XCTestCase {
    func testScanTargetInfersMountedVolumeRoots() {
        let volumeURL = URL(filePath: "/Volumes/External Drive", directoryHint: .isDirectory)
        let folderURL = URL(filePath: "/Users/example/Documents", directoryHint: .isDirectory)

        XCTAssertEqual(
            ScanTarget.inferredKind(for: volumeURL, mountedVolumeURLs: [volumeURL]),
            .volume
        )
        XCTAssertEqual(
            ScanTarget.inferredKind(for: folderURL, mountedVolumeURLs: [volumeURL]),
            .folder
        )
        XCTAssertEqual(
            ScanTarget.inferredKind(for: URL(filePath: "/", directoryHint: .isDirectory), mountedVolumeURLs: nil),
            .volume
        )
    }

    func testSupportsMoveToTrashRejectsSyntheticNodesAndRootPath() {
        let rootNode = makeNode(id: "/", isDirectory: true, isSynthetic: false, isAccessible: true)
        let syntheticNode = makeNode(id: "/System & Unattributed", isDirectory: true, isSynthetic: true, isAccessible: true)
        let folderNode = makeNode(id: "/Users/example/Documents", isDirectory: true, isSynthetic: false, isAccessible: true)

        XCTAssertFalse(rootNode.supportsMoveToTrash)
        XCTAssertFalse(syntheticNode.supportsMoveToTrash)
        XCTAssertTrue(folderNode.supportsMoveToTrash)
    }

    func testTrashSafetyPolicyRejectsProtectedRoots() {
        let policy = makeTrashSafetyPolicy()
        let protectedPaths = [
            "/",
            "/System",
            "/Library",
            "/Applications",
            "/Users",
            "/Volumes",
            "/Users/example",
            "/System/Volumes/Data/Users/example",
            "/System/Volumes/Data/Applications",
            "/Volumes/External",
            "/ExampleFirmlink",
            "/System/Volumes/Data/ExampleFirmlink",
            "/System/Library/Caches",
            "/System/Volumes/Data/System/Library/Caches"
        ]

        for path in protectedPaths {
            let reason = policy.blockReason(for: URL(filePath: path, directoryHint: .isDirectory))
            XCTAssertEqual(reason?.path, standardizedTestPath(path), path)
        }
    }

    func testTrashSafetyPolicyAllowsDescendantsOfProtectedRoots() {
        let policy = makeTrashSafetyPolicy()
        let allowedPaths = [
            "/Applications/Example.app",
            "/Users/example/Downloads/file.dmg",
            "/Volumes/External/file.txt",
            "/ExampleFirmlink/child",
            "/System/Volumes/Data/Applications/Example.app"
        ]

        for path in allowedPaths {
            XCTAssertNil(
                policy.blockReason(for: URL(filePath: path)),
                path
            )
        }
    }

    func testSupportsMoveToTrashRejectsTrashSafetyProtectedRoots() {
        let systemNode = makeNode(id: "/System", isDirectory: true, isSynthetic: false, isAccessible: true)
        let libraryNode = makeNode(id: "/Library", isDirectory: true, isSynthetic: false, isAccessible: true)
        let applicationsNode = makeNode(id: "/Applications", isDirectory: true, isSynthetic: false, isAccessible: true)
        let applicationsChildNode = makeNode(id: "/Applications/Example.app", isDirectory: true, isSynthetic: false, isAccessible: true)

        XCTAssertFalse(systemNode.supportsMoveToTrash)
        XCTAssertFalse(libraryNode.supportsMoveToTrash)
        XCTAssertFalse(applicationsNode.supportsMoveToTrash)
        XCTAssertTrue(applicationsChildNode.supportsMoveToTrash)
    }

    func testSupportsMoveToTrashRejectsActiveVolumeRoot() {
        let volumeTarget = ScanTarget(
            url: URL(filePath: "/Volumes/External", directoryHint: .isDirectory),
            kind: .volume
        )
        let volumeRootNode = makeNode(id: volumeTarget.id, isDirectory: true, isSynthetic: false, isAccessible: true)
        let childNode = makeNode(id: volumeTarget.id + "/file.txt", isDirectory: false, isSynthetic: false, isAccessible: true)

        XCTAssertFalse(volumeRootNode.supportsMoveToTrash(activeTarget: volumeTarget))
        XCTAssertTrue(childNode.supportsMoveToTrash(activeTarget: volumeTarget))
    }

    func testActionAvailabilityUsesSharedFileActionRules() {
        let volumeTarget = ScanTarget(
            url: URL(filePath: "/Volumes/External", directoryHint: .isDirectory),
            kind: .volume
        )
        let volumeRootNode = makeNode(id: volumeTarget.id, isDirectory: true, isSynthetic: false, isAccessible: true)
        let regularFile = makeNode(id: volumeTarget.id + "/file.txt", isDirectory: false, isSynthetic: false, isAccessible: true)
        let syntheticNode = makeNode(id: volumeTarget.id + "/system", isDirectory: false, isSynthetic: true, isAccessible: true)

        let volumeRootAvailability = volumeRootNode.actionAvailability(activeTarget: volumeTarget)
        XCTAssertTrue(volumeRootAvailability.canOpen)
        XCTAssertTrue(volumeRootAvailability.canPreviewWithQuickLook)
        XCTAssertTrue(volumeRootAvailability.canRevealInFinder)
        XCTAssertTrue(volumeRootAvailability.canCopyPath)
        XCTAssertFalse(volumeRootAvailability.canMoveToTrash)

        let regularFileAvailability = regularFile.actionAvailability(activeTarget: volumeTarget)
        XCTAssertTrue(regularFileAvailability.canOpen)
        XCTAssertTrue(regularFileAvailability.canMoveToTrash)

        let syntheticAvailability = syntheticNode.actionAvailability(activeTarget: volumeTarget)
        XCTAssertFalse(syntheticAvailability.canOpen)
        XCTAssertFalse(syntheticAvailability.canPreviewWithQuickLook)
        XCTAssertFalse(syntheticAvailability.canRevealInFinder)
        XCTAssertFalse(syntheticAvailability.canCopyPath)
        XCTAssertFalse(syntheticAvailability.canMoveToTrash)

        XCTAssertEqual(
            FileNodeActionAvailability(node: nil, activeTarget: volumeTarget),
            FileNodeActionAvailability(
                canOpen: false,
                canPreviewWithQuickLook: false,
                canRevealInFinder: false,
                canCopyPath: false,
                canMoveToTrash: false
            )
        )
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
        let symlink = makeNode(
            id: "/root/link",
            isDirectory: false,
            isSymbolicLink: true,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 5
        )

        let children = [small, largeInaccessible, symlink]
        let directory = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(FileTreeStore.sortedChildren(children).map(\.name), ["z.txt", "a.txt", "link"])
        XCTAssertEqual(directory.allocatedSize, 35)
        XCTAssertEqual(directory.logicalSize, 35)
        XCTAssertEqual(directory.descendantFileCount, 2)
        XCTAssertFalse(directory.isAccessible)
        XCTAssertFalse(directory.isAutoSummarized)
    }

    func testSnapshotReplacingNodeRebuildsAncestorsAndPreservesWarnings() throws {
        let staleLeaf = makeNode(id: "/root/folder/stale.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 5)
        let summarizedFolder = makeNode(
            id: "/root/folder",
            isDirectory: true,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 5,
            descendantFileCount: 42,
            isAutoSummarized: true
        )
        let sibling = makeNode(id: "/root/sibling.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 8)
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [summarizedFolder, sibling],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root, childrenByID: [root.id: [summarizedFolder, sibling]])

        let originalWarning = ScanWarning(path: "/root/folder", message: "original", category: .fileSystem)
        let snapshot = makeSnapshot(root: root, treeStore: treeStore, warnings: [originalWarning])

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
        let expandedFolder = FileNodeRecord.directory(
            id: "/root/folder",
            url: URL(filePath: "/root/folder", directoryHint: .isDirectory),
            name: "folder",
            children: [accessibleExpandedLeaf, inaccessibleExpandedLeaf],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let expandedStore = FileTreeStore(root: expandedFolder, childrenByID: [
            expandedFolder.id: [accessibleExpandedLeaf, inaccessibleExpandedLeaf],
        ])
        let expansionWarning = ScanWarning(path: "/root/folder/z.txt", message: "expanded", category: .permissionDenied)

        let updatedSnapshot = try XCTUnwrap(
            snapshot.replacingNode(
                id: summarizedFolder.id,
                with: expandedStore,
                additionalWarnings: [expansionWarning]
            )
        )

        let updatedFolder = try XCTUnwrap(updatedSnapshot.treeStore.node(id: summarizedFolder.id))
        let updatedChildren = updatedSnapshot.treeStore.children(of: updatedFolder.id)
        XCTAssertFalse(updatedFolder.isAutoSummarized)
        XCTAssertEqual(updatedChildren.map(\.name), ["z.txt", "a.txt"])
        XCTAssertEqual(updatedFolder.descendantFileCount, 2)
        XCTAssertFalse(updatedFolder.isAccessible)
        XCTAssertEqual(updatedSnapshot.aggregateStats.fileCount, 3)
        XCTAssertFalse(updatedSnapshot.root.isAccessible)
        XCTAssertEqual(updatedSnapshot.scanWarnings.count, 2)
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [originalWarning.path, expansionWarning.path])
        XCTAssertNotEqual(staleLeaf.id, updatedChildren.first?.id)
    }

    func testSnapshotReplacingMissingNodeReturnsNil() {
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root)
        let snapshot = makeSnapshot(root: root, treeStore: treeStore)

        XCTAssertNil(snapshot.replacingNode(id: "/root/missing", with: treeStore))
    }

    func testSnapshotScopedToDescendantUsesSubtreeAndFiltersWarnings() throws {
        let docsFile = makeNode(id: "/root/Documents/report.pdf", isDirectory: false, isSynthetic: false, isAccessible: true)
        let cacheFile = makeNode(id: "/root/Library/cache.db", isDirectory: false, isSynthetic: false, isAccessible: true)
        let docs = FileNodeRecord.directory(
            id: "/root/Documents",
            url: URL(filePath: "/root/Documents", directoryHint: .isDirectory),
            name: "Documents",
            children: [docsFile],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let library = FileNodeRecord.directory(
            id: "/root/Library",
            url: URL(filePath: "/root/Library", directoryHint: .isDirectory),
            name: "Library",
            children: [cacheFile],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [docs, library],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root, childrenByID: [
            root.id: [docs, library],
            docs.id: [docsFile],
            library.id: [cacheFile],
        ])
        let docsWarning = ScanWarning(path: "/root/Documents/private", message: "docs", category: .permissionDenied)
        let libraryWarning = ScanWarning(path: "/root/Library/private", message: "library", category: .permissionDenied)
        let snapshot = makeSnapshot(root: root, treeStore: treeStore, warnings: [docsWarning, libraryWarning])
        let docsTarget = ScanTarget(url: docs.url)

        let scopedSnapshot = try XCTUnwrap(snapshot.scoped(to: docsTarget))

        XCTAssertEqual(scopedSnapshot.target, docsTarget)
        XCTAssertEqual(scopedSnapshot.root.id, docs.id)
        XCTAssertEqual(scopedSnapshot.treeStore.children(of: docs.id).map(\.id), [docsFile.id])
        XCTAssertNil(scopedSnapshot.treeStore.node(id: library.id))
        XCTAssertEqual(scopedSnapshot.aggregateStats.totalAllocatedSize, docs.allocatedSize)
        XCTAssertEqual(scopedSnapshot.aggregateStats.fileCount, 1)
        XCTAssertEqual(scopedSnapshot.scanWarnings.map(\.path), [docsWarning.path])
    }

    func testSnapshotScopedToMissingTargetReturnsNil() {
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root)
        let snapshot = makeSnapshot(root: root, treeStore: treeStore)

        XCTAssertNil(snapshot.scoped(to: ScanTarget(url: URL(filePath: "/root/Missing", directoryHint: .isDirectory))))
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
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [child],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root, childrenByID: [root.id: [child]])

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

        let snapshot = makeSnapshot(root: root, treeStore: treeStore, warnings: [existingWarning])
        let replacement = FileNodeRecord.directory(
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
                with: FileTreeStore(root: replacement),
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

    private func makeSnapshot(
        root: FileNodeRecord,
        treeStore: FileTreeStore,
        warnings: [ScanWarning] = []
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: ScanTarget(url: URL(filePath: root.id, directoryHint: .isDirectory)),
            treeStore: treeStore,
            startedAt: .distantPast,
            finishedAt: .now,
            scanWarnings: warnings,
            aggregateStats: treeStore.aggregateStats,
            isComplete: true
        )
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        isSynthetic: Bool,
        isAccessible: Bool,
        allocatedSize: Int64 = 64,
        descendantFileCount: Int? = nil,
        isAutoSummarized: Bool = false
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            name: URL(filePath: id).lastPathComponent.isEmpty ? id : URL(filePath: id).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount ?? (isDirectory || isSymbolicLink ? 0 : 1),
            lastModified: nil,
            isPackage: false,
            isAccessible: isAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }

    private func makeTrashSafetyPolicy() -> TrashSafetyPolicy {
        TrashSafetyPolicy(
            homeDirectory: URL(filePath: "/Users/example", directoryHint: .isDirectory),
            mountedVolumeURLs: [
                URL(filePath: "/Volumes/External", directoryHint: .isDirectory)
            ],
            firmlinkEntries: [
                TrashSafetyPolicy.FirmlinkEntry(
                    visiblePath: "/Applications",
                    dataRelativePath: "Applications"
                ),
                TrashSafetyPolicy.FirmlinkEntry(
                    visiblePath: "/ExampleFirmlink",
                    dataRelativePath: "ExampleFirmlink"
                ),
                TrashSafetyPolicy.FirmlinkEntry(
                    visiblePath: "/System/Library/Caches",
                    dataRelativePath: "System/Library/Caches"
                )
            ]
        )
    }

    private func standardizedTestPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
