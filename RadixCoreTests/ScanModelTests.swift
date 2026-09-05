import XCTest
@testable import RadixCore

final class ScanModelTests: XCTestCase {
    func testScanMetricsCurrentItemNameIsNilForEmptyPath() {
        let metrics = ScanMetrics()

        XCTAssertNil(metrics.currentItemName)
    }

    func testScanMetricsCurrentItemNameUsesLastPathComponent() {
        var metrics = ScanMetrics()
        metrics.currentPath = "/Users/example/Downloads/archive.zip"

        XCTAssertEqual(metrics.currentItemName, "archive.zip")
    }

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

    func testDisplayNameWithKnownPathPreservesRootAndLiteralComponents() throws {
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let volumeName = try rootURL.resourceValues(forKeys: [.volumeNameKey]).volumeName ?? "Startup Disk"
        let cases: [(URL, String)] = [
            (rootURL, volumeName),
            (URL(filePath: "/Users/example/file-2.txt", directoryHint: .notDirectory), "file-2.txt"),
            (URL(filePath: "/Users/example/folder/", directoryHint: .isDirectory), "folder"),
            (
                URL(filePath: "/Users/example/alias/文件-cafe\u{301}-100% #?.dat", directoryHint: .notDirectory),
                "文件-cafe\u{301}-100% #?.dat"
            )
        ]
        for (url, expected) in cases {
            XCTAssertEqual(ScanTarget.displayName(for: url), expected)
            XCTAssertEqual(ScanTarget.displayName(for: url, knownPath: url.path), expected)
        }
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

    func testSupportsMoveToTrashUsesInjectedTrashSafetyPolicy() {
        let policy = makeTrashSafetyPolicy()
        let mountedRootNode = makeNode(id: "/Volumes/External", isDirectory: true, isSynthetic: false, isAccessible: true)
        let mountedChildNode = makeNode(id: "/Volumes/External/file.txt", isDirectory: false, isSynthetic: false, isAccessible: true)

        XCTAssertFalse(mountedRootNode.supportsMoveToTrash(trashSafetyPolicy: policy))
        XCTAssertFalse(mountedRootNode.supportsMoveToTrash(activeTarget: nil, trashSafetyPolicy: policy))
        XCTAssertTrue(mountedChildNode.supportsMoveToTrash(activeTarget: nil, trashSafetyPolicy: policy))
        XCTAssertFalse(
            FileNodeActionAvailability(
                node: mountedRootNode,
                activeTarget: nil,
                trashSafetyPolicy: policy
            ).canMoveToTrash
        )
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

    func testMultiNodeActionAvailabilityAllowsOnlyBulkSafeActions() {
        let first = makeNode(id: "/Users/example/Downloads/first.txt", isDirectory: false, isSynthetic: false, isAccessible: true)
        let second = makeNode(id: "/Users/example/Downloads/second.txt", isDirectory: false, isSynthetic: false, isAccessible: true)
        let syntheticNode = makeNode(id: "/Users/example/Downloads/system", isDirectory: false, isSynthetic: true, isAccessible: true)

        let availability = FileNodeActionAvailability(nodes: [first, second], activeTarget: nil)
        XCTAssertFalse(availability.canOpen)
        XCTAssertFalse(availability.canPreviewWithQuickLook)
        XCTAssertTrue(availability.canRevealInFinder)
        XCTAssertTrue(availability.canCopyPath)
        XCTAssertTrue(availability.canMoveToTrash)

        let mixedAvailability = FileNodeActionAvailability(nodes: [first, syntheticNode], activeTarget: nil)
        XCTAssertFalse(mixedAvailability.canRevealInFinder)
        XCTAssertFalse(mixedAvailability.canCopyPath)
        XCTAssertFalse(mixedAvailability.canMoveToTrash)
    }

    func testFileNodeActionsDescribePresentationAndAvailability() {
        let availability = FileNodeActionAvailability(
            canOpen: true,
            canPreviewWithQuickLook: false,
            canRevealInFinder: true,
            canCopyPath: false,
            canMoveToTrash: true
        )

        XCTAssertEqual(
            FileNodeAction.allCases.map(\.title),
            ["Quick Look", "Reveal in Finder", "Open", "Open in Terminal", "Copy Path", "Move to Trash"]
        )
        XCTAssertEqual(FileNodeAction.open.systemImageName, "arrow.up.forward.app")
        XCTAssertEqual(FileNodeAction.openInTerminal.systemImageName, "terminal")
        XCTAssertEqual(FileNodeAction.moveToTrash.systemImageName, "trash")
        XCTAssertFalse(FileNodeAction.quickLook.isEnabled(in: availability))
        XCTAssertTrue(FileNodeAction.revealInFinder.isEnabled(in: availability))
        XCTAssertTrue(FileNodeAction.open.isEnabled(in: availability))
        XCTAssertTrue(FileNodeAction.openInTerminal.isEnabled(in: availability))
        XCTAssertFalse(FileNodeAction.copyPath.isEnabled(in: availability))
        XCTAssertTrue(FileNodeAction.moveToTrash.isEnabled(in: availability))

        if #available(macOS 15.0, *) {
            XCTAssertEqual(FileNodeAction.quickLook.systemImageName, "document.viewfinder")
            XCTAssertEqual(FileNodeAction.copyPath.systemImageName, "document.on.document")
        } else {
            XCTAssertEqual(FileNodeAction.quickLook.systemImageName, "doc.viewfinder")
            XCTAssertEqual(FileNodeAction.copyPath.systemImageName, "doc.on.doc")
        }
    }

    func testTerminalActionTargetsFoldersAndContainingFolders() {
        let folder = makeNode(
            id: "/Users/example/Downloads",
            isDirectory: true,
            isSynthetic: false,
            isAccessible: true
        )
        let file = makeNode(
            id: "/Users/example/Downloads/archive.zip",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true
        )
        let package = makeNode(
            id: "/Users/example/Downloads/Example.app",
            isDirectory: true,
            isPackage: true,
            isSynthetic: false,
            isAccessible: true
        )
        let symbolicLink = makeNode(
            id: "/Users/example/Downloads/shortcut",
            isDirectory: true,
            isSymbolicLink: true,
            isSynthetic: false,
            isAccessible: true
        )

        XCTAssertEqual(folder.terminalDirectoryURL, folder.url)
        XCTAssertEqual(FileNodeAction.openInTerminal.title(for: folder), "Open in Terminal")

        for node in [file, package, symbolicLink] {
            XCTAssertEqual(
                node.terminalDirectoryURL,
                URL(filePath: "/Users/example/Downloads", directoryHint: .isDirectory)
            )
            XCTAssertEqual(
                FileNodeAction.openInTerminal.title(for: node),
                "Open Containing Folder in Terminal"
            )
        }
    }

    func testSecondaryStatusTextReflectsAccessibilityAndSyntheticState() {
        let readableNode = makeNode(id: "/Users/example/file.txt", isDirectory: false, isSynthetic: false, isAccessible: true)
        let limitedNode = makeNode(id: "/Users/example/private", isDirectory: true, isSynthetic: false, isAccessible: false)
        let syntheticNode = makeNode(id: "/System & Unattributed", isDirectory: true, isSynthetic: true, isAccessible: true)

        XCTAssertNil(readableNode.secondaryStatusText)

        XCTAssertEqual(limitedNode.secondaryStatusText, "Limited access")

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

    func testSnapshotReplacingNodeRebuildsAncestorsAndReplacesStaleWarnings() throws {
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
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [expansionWarning.path])
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

    func testSubtreeUpdateRefreshesAPFSCapacityWithoutReconcilingItIntoTree() {
        let target = ScanTarget(
            url: URL(filePath: "/volume", directoryHint: .isDirectory),
            kind: .volume
        )
        let file = makeNode(
            id: "/volume/file.dat",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 40
        )
        let root = FileNodeRecord.directory(
            id: target.id,
            url: target.url,
            name: "volume",
            children: [file],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let snapshot = ScanSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: .now,
            finishedAt: .now,
            scanWarnings: [],
            isComplete: true,
            scanOptions: ScanOptions(),
            volumeCapacity: nil
        )
        let refreshedCapacity = VolumeCapacitySnapshot(
            totalCapacity: 1_000_000_000,
            availableCapacity: 300_000_000
        )

        let updated = snapshot.updatedAfterSubtreeRescan(
            finishedAt: .now,
            volumeCapacity: refreshedCapacity,
            reconcilesVolumeCapacity: false
        )

        XCTAssertEqual(updated.volumeCapacity, refreshedCapacity)
        XCTAssertEqual(updated.root.allocatedSize, 40)
        XCTAssertEqual(updated.treeStore.children(of: root.id).map(\.id), [file.id])
    }

    func testSnapshotRemovingNodeRemovesSubtreeAndRebuildsAncestors() throws {
        let removedLeaf = makeNode(
            id: "/root/folder/removed.bin",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 80
        )
        let keptLeaf = makeNode(
            id: "/root/folder/kept.txt",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 5
        )
        let folder = FileNodeRecord.directory(
            id: "/root/folder",
            url: URL(filePath: "/root/folder", directoryHint: .isDirectory),
            name: "folder",
            children: [removedLeaf, keptLeaf],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let sibling = makeNode(
            id: "/root/sibling.txt",
            isDirectory: false,
            isSynthetic: false,
            isAccessible: true,
            allocatedSize: 20
        )
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [folder, sibling],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let treeStore = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, sibling],
            folder.id: [removedLeaf, keptLeaf],
        ])
        let removedWarning = ScanWarning(path: removedLeaf.id, message: "removed", category: .fileSystem)
        let retainedWarning = ScanWarning(path: keptLeaf.id, message: "kept", category: .fileSystem)
        let snapshot = makeSnapshot(
            root: root,
            treeStore: treeStore,
            warnings: [removedWarning, retainedWarning]
        )

        let updatedSnapshot = try XCTUnwrap(snapshot.removingNode(id: removedLeaf.id))

        XCTAssertEqual(updatedSnapshot.id, snapshot.id)
        let updatedFolder = try XCTUnwrap(updatedSnapshot.treeStore.node(id: folder.id))
        XCTAssertNil(updatedSnapshot.treeStore.node(id: removedLeaf.id))
        XCTAssertEqual(updatedSnapshot.treeStore.children(of: folder.id).map(\.id), [keptLeaf.id])
        XCTAssertEqual(updatedFolder.allocatedSize, 5)
        XCTAssertEqual(updatedFolder.logicalSize, 5)
        XCTAssertEqual(updatedFolder.descendantFileCount, 1)
        XCTAssertEqual(updatedSnapshot.root.allocatedSize, 25)
        XCTAssertEqual(updatedSnapshot.root.descendantFileCount, 2)
        XCTAssertEqual(updatedSnapshot.treeStore.children(of: root.id).map(\.id), [sibling.id, folder.id])
        XCTAssertEqual(updatedSnapshot.aggregateStats.totalAllocatedSize, 25)
        XCTAssertEqual(updatedSnapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(updatedSnapshot.aggregateStats.directoryCount, 2)
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [retainedWarning.path])
    }

    func testSnapshotRemovingMissingOrRootNodeReturnsNil() {
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

        XCTAssertNil(snapshot.removingNode(id: "/root/missing"))
        XCTAssertNil(snapshot.removingNode(id: root.id))
    }

    func testSnapshotRemovesMultipleSubtreesAndTheirWarningsTogether() throws {
        let first = makeNode(id: "/root/first/file.bin", isDirectory: false, isSynthetic: false, isAccessible: true)
        let firstDirectory = FileNodeRecord.directory(
            id: "/root/first",
            url: URL(filePath: "/root/first", directoryHint: .isDirectory),
            name: "first",
            children: [first],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let second = makeNode(id: "/root/second.bin", isDirectory: false, isSynthetic: false, isAccessible: true)
        let retained = makeNode(id: "/root/retained.bin", isDirectory: false, isSynthetic: false, isAccessible: true)
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [firstDirectory, second, retained],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [firstDirectory, second, retained],
            firstDirectory.id: [first],
        ])
        let removedWarnings = [
            ScanWarning(path: first.id, message: "first", category: .fileSystem),
            ScanWarning(path: second.id, message: "second", category: .fileSystem),
        ]
        let retainedWarning = ScanWarning(path: retained.id, message: "retained", category: .fileSystem)
        let prefixSiblingWarning = ScanWarning(
            path: "/root/first-other/file.bin",
            message: "prefix sibling",
            category: .fileSystem
        )
        let snapshot = makeSnapshot(
            root: root,
            treeStore: store,
            warnings: removedWarnings + [retainedWarning, prefixSiblingWarning]
        )

        let updated = try XCTUnwrap(snapshot.removingNodes(ids: [firstDirectory.id, first.id, second.id]))

        XCTAssertNil(updated.treeStore.node(id: firstDirectory.id))
        XCTAssertNil(updated.treeStore.node(id: first.id))
        XCTAssertNil(updated.treeStore.node(id: second.id))
        XCTAssertNotNil(updated.treeStore.node(id: retained.id))
        XCTAssertEqual(updated.scanWarnings.map(\.path), [retained.id, prefixSiblingWarning.path])
        XCTAssertEqual(updated.aggregateStats.fileCount, 1)
        XCTAssertNil(snapshot.removingNodes(ids: []))
        XCTAssertNil(snapshot.removingNodes(ids: ["/root/missing"]))
        XCTAssertNil(snapshot.removingNodes(ids: [root.id, second.id]))
    }

    func testSnapshotScopedToDescendantUsesLogicalScopeAndFiltersWarnings() throws {
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
        XCTAssertNotEqual(scopedSnapshot.treeStore.contentID, snapshot.treeStore.contentID)
        XCTAssertEqual(scopedSnapshot.treeStore.nodeCount, 2)
        XCTAssertNil(scopedSnapshot.treeStore.parent(of: docs.id))
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
            .removeFromActiveScan
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
                additionalWarnings: [duplicateWarning, duplicateWarning, distinctWarning]
            )
        )

        XCTAssertEqual(updatedSnapshot.id, snapshot.id)
        XCTAssertEqual(updatedSnapshot.scanWarnings.count, 2)
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [
            duplicateWarning.path,
            distinctWarning.path
        ])
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.message), [
            duplicateWarning.message,
            distinctWarning.message
        ])
    }

    func testSnapshotReplacingSubtreesPrunesStaleWarningsAndMergesReplacementWarnings() throws {
        let oldA = makeNode(id: "/root/A", isDirectory: false, isSynthetic: false, isAccessible: false, allocatedSize: 5)
        let oldB = makeNode(id: "/root/B", isDirectory: false, isSynthetic: false, isAccessible: false, allocatedSize: 7)
        let kept = makeNode(id: "/root/kept.txt", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 3)
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [oldA, oldB, kept],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB, kept]])
        let staleA = ScanWarning(path: "/root/A", message: "stale A", category: .permissionDenied)
        let staleBDescendant = ScanWarning(path: "/root/B/child", message: "stale B", category: .fileSystem)
        let retained = ScanWarning(path: kept.id, message: "retained", category: .fileSystem)
        let snapshot = makeSnapshot(root: root, treeStore: store, warnings: [staleA, retained, staleBDescendant])

        let newA = makeNode(id: oldA.id, isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 11)
        let newB = makeNode(id: oldB.id, isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 13)
        let newWarning = ScanWarning(path: "/root/B/new-child", message: "new", category: .fileSystem)
        let duplicateNewWarning = ScanWarning(path: newWarning.path, message: newWarning.message, category: newWarning.category)

        let updated = try XCTUnwrap(try snapshot.replacingSubtrees(
            [
                oldA.id: FileTreeStore(root: newA),
                oldB.id: FileTreeStore(root: newB),
            ],
            additionalWarnings: [newWarning, duplicateNewWarning],
            cancellationCheck: {}
        ))

        XCTAssertEqual(updated.root.allocatedSize, 27)
        XCTAssertEqual(updated.scanWarnings.map(\.path), [retained.path, newWarning.path])
        XCTAssertEqual(updated.scanWarnings.map(\.message), [retained.message, newWarning.message])
    }

    func testSnapshotTransformServiceReplacesSubtrees() async throws {
        let oldA = makeNode(id: "/root/A", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 5)
        let oldB = makeNode(id: "/root/B", isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 7)
        let root = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: [oldA, oldB],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldA, oldB]])
        let snapshot = makeSnapshot(root: root, treeStore: store)
        let newA = makeNode(id: oldA.id, isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 10)
        let newB = makeNode(id: oldB.id, isDirectory: false, isSynthetic: false, isAccessible: true, allocatedSize: 20)

        let transformed = try await ScanSnapshotTransformService().replacingSubtrees(
            in: snapshot,
            replacements: [
                oldA.id: FileTreeStore(root: newA),
                oldB.id: FileTreeStore(root: newB),
            ]
        )
        let updated = try XCTUnwrap(transformed)

        XCTAssertEqual(updated.root.allocatedSize, 30)
        XCTAssertEqual(Set(updated.treeStore.children(of: root.id).map(\.id)), Set([oldA.id, oldB.id]))
    }

    func testPermissionAdvisorSuppressesSuggestionWhenFullDiskAccessGranted() {
        let exampleHome = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let root = makeNode(id: "/", isDirectory: true, isSynthetic: false, isAccessible: true)
        let snapshot = makeSnapshot(
            root: root,
            treeStore: FileTreeStore(root: root),
            warnings: [
                ScanWarning(
                    path: "/Users/example/Library/Mail",
                    message: "Permission denied",
                    category: .permissionDenied
                )
            ]
        )

        // FDA-unlockable warning present, but access is already granted: no nag.
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: snapshot,
                fullDiskAccessStatus: .granted,
                homeDirectory: exampleHome
            )
        )
        XCTAssertTrue(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: snapshot,
                fullDiskAccessStatus: .notGranted,
                homeDirectory: exampleHome
            )
        )
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: snapshot,
                fullDiskAccessStatus: .unknown,
                homeDirectory: exampleHome
            )
        )
    }

    func testPermissionAdvisorIgnoresSystemPathsFullDiskAccessCannotUnlock() {
        let root = makeNode(id: "/", isDirectory: true, isSynthetic: false, isAccessible: true)
        // Paths that stay unreadable even with FDA granted. These must never
        // drive the suggestion, otherwise granting FDA never clears the prompt.
        let snapshot = makeSnapshot(
            root: root,
            treeStore: FileTreeStore(root: root),
            warnings: [
                ScanWarning(
                    path: "/Library/Caches/com.apple.iconservices.store",
                    message: "Permission denied",
                    category: .permissionDenied
                ),
                ScanWarning(
                    path: "/Library/Application Support/com.apple.TCC",
                    message: "Permission denied",
                    category: .permissionDenied
                )
            ]
        )

        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot, fullDiskAccessStatus: .notGranted)
        )
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot, fullDiskAccessStatus: .unknown)
        )
    }

    func testPermissionAdvisorCanEvaluateSelectionScopedWarnings() {
        let exampleHome = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let unlockableWarning = ScanWarning(
            path: "/Users/example/Library/Mail",
            message: "Permission denied",
            category: .permissionDenied
        )
        let permanentlyProtectedWarning = ScanWarning(
            path: "/Library/Application Support/com.apple.TCC",
            message: "Permission denied",
            category: .permissionDenied
        )

        XCTAssertTrue(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: [unlockableWarning],
                fullDiskAccessStatus: .notGranted,
                homeDirectory: exampleHome
            )
        )
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: [permanentlyProtectedWarning],
                fullDiskAccessStatus: .notGranted,
                homeDirectory: exampleHome
            )
        )
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: [unlockableWarning],
                fullDiskAccessStatus: .granted,
                homeDirectory: exampleHome
            )
        )
        XCTAssertFalse(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: [
                    ScanWarning(
                        path: "/Users/example/Library/MailBackup",
                        message: "Permission denied",
                        category: .permissionDenied
                    )
                ],
                fullDiskAccessStatus: .notGranted,
                homeDirectory: exampleHome
            )
        )
        for unrelatedPath in [
            "/tmp/Library/Mail",
            "/Users/other/Library/Mail",
        ] {
            XCTAssertFalse(
                PermissionAdvisor.shouldSuggestFullDiskAccess(
                    for: [
                        ScanWarning(
                            path: unrelatedPath,
                            message: "Permission denied",
                            category: .permissionDenied
                        )
                    ],
                    fullDiskAccessStatus: .notGranted,
                    homeDirectory: exampleHome
                )
            )
        }
        XCTAssertTrue(
            PermissionAdvisor.shouldSuggestFullDiskAccess(
                for: [
                    ScanWarning(
                        path: "/System/Volumes/Data/Users/example/Library/Mail/V10",
                        message: "Permission denied",
                        category: .permissionDenied
                    )
                ],
                fullDiskAccessStatus: .notGranted,
                homeDirectory: exampleHome
            )
        )
    }

    func testPermissionAdvisorPreservesAdviceForLiveAndSavedScans() {
        let exampleHome = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let warnings = [
            ScanWarning(
                path: "/Users/example/Library/Mail",
                message: "Permission denied",
                category: .permissionDenied
            )
        ]
        let importedSource = ScanSnapshotSource.imported(
            ImportedSnapshotContext(
                sourceURL: URL(filePath: "/tmp/example.radixscan"),
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            )
        )

        XCTAssertEqual(
            PermissionAdvisor.fullDiskAccessAdvice(
                for: warnings,
                fullDiskAccessStatus: .notGranted,
                snapshotSource: .live,
                homeDirectory: exampleHome
            ),
            .openSettings
        )
        XCTAssertEqual(
            PermissionAdvisor.fullDiskAccessAdvice(
                for: warnings,
                fullDiskAccessStatus: .granted,
                snapshotSource: .live,
                homeDirectory: exampleHome
            ),
            .rescanMayBeNeeded
        )
        XCTAssertEqual(
            PermissionAdvisor.fullDiskAccessAdvice(
                for: warnings,
                fullDiskAccessStatus: .unknown,
                snapshotSource: .live,
                homeDirectory: exampleHome
            ),
            .none
        )
        XCTAssertEqual(
            PermissionAdvisor.fullDiskAccessAdvice(
                for: warnings,
                fullDiskAccessStatus: .notGranted,
                snapshotSource: importedSource,
                homeDirectory: exampleHome
            ),
            .savedScanIsHistorical
        )
    }

    func testPermissionAdvisorClassifiesOnlyVerifiedExpectedMacOSProtection() {
        let expectedWarnings = [
            ScanWarning(
                path: "/Library/Application Support/com.apple.TCC",
                message: "Permission denied",
                category: .permissionDenied
            ),
            ScanWarning(
                path: "/Library/Caches/com.apple.iconservices.store",
                message: "Permission denied",
                category: .permissionDenied
            ),
        ]
        let arbitraryPermissionFailure = ScanWarning(
            path: "/Users/example/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let historicalFullDiskAccessPath = ScanWarning(
            path: "/Users/example/Library/Mail",
            message: "Permission denied",
            category: .permissionDenied
        )

        XCTAssertTrue(expectedWarnings.allSatisfy(PermissionAdvisor.isExpectedMacOSProtection))
        XCTAssertFalse(PermissionAdvisor.isExpectedMacOSProtection(arbitraryPermissionFailure))
        XCTAssertFalse(PermissionAdvisor.isExpectedMacOSProtection(historicalFullDiskAccessPath))
    }

    func testPermissionAdvisorExcludesExpectedProtectionFromWarningsRequiringAttention() {
        let expectedProtection = ScanWarning(
            path: "/Library/Application Support/com.apple.TCC",
            message: "Permission denied",
            category: .permissionDenied
        )
        let arbitraryPermissionFailure = ScanWarning(
            path: "/Users/example/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let fileSystemFailure = ScanWarning(
            path: "/Users/example/Damaged",
            message: "Input/output error",
            category: .fileSystem
        )

        let warnings = PermissionAdvisor.warningsRequiringUserAttention([
            expectedProtection,
            arbitraryPermissionFailure,
            fileSystemFailure,
        ])

        XCTAssertEqual(
            warnings.map(\.path),
            [arbitraryPermissionFailure.path, fileSystemFailure.path]
        )
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
            isComplete: true
        )
    }

    private func makeNode(
        id: String,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        isPackage: Bool = false,
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
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isAccessible,
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
