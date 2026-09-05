import XCTest
@testable import RadixCore

final class ScanComparisonServiceTests: XCTestCase {
    func testLogicalScopeComparesIdenticallyToMaterializedSubtree() async throws {
        let visible = makeTestFileNode(id: "/root/Home/file.bin", name: "file.bin", size: 25)
        let home = makeTestDirectoryNode(id: "/root/Home", name: "Home", children: [visible])
        let outside = makeTestFileNode(id: "/root/System.bin", name: "System.bin", size: 100)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [home, outside])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [home, outside],
            home.id: [visible],
        ])
        let logicalScope = try XCTUnwrap(store.logicalScope(rootedAt: home.id))
        let materializedScope = try XCTUnwrap(store.subtree(rootedAt: home.id))

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: logicalScope.root, store: logicalScope),
            after: makeTestSnapshot(root: materializedScope.root, store: materializedScope)
        )

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.fileCountDelta, 0)
    }

    func testComparesSnapshotsByRelativePathAcrossDifferentRoots() async throws {
        let beforeFile = makeTestFileNode(id: "/before/shared.bin", name: "shared.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeFile])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeFile]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(id: "/after/shared.bin", name: "shared.bin", size: 25)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterFile])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterFile]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "shared.bin")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 15)
        XCTAssertEqual(comparison.summary.allocatedDelta, 15)
        XCTAssertEqual(comparison.summary.grewCount, 1)
    }

    func testAddedAndRemovedDirectoriesSuppressDescendantRows() async throws {
        let removedChild = makeTestFileNode(id: "/root/removed/child.bin", name: "child.bin", size: 30)
        let removedFolder = makeTestDirectoryNode(id: "/root/removed", name: "removed", children: [removedChild])
        let sharedBefore = makeTestFileNode(id: "/root/shared.bin", name: "shared.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [removedFolder, sharedBefore]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [removedFolder, sharedBefore],
            removedFolder.id: [removedChild],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let addedChild = makeTestFileNode(id: "/root/added/child.bin", name: "child.bin", size: 80)
        let addedFolder = makeTestDirectoryNode(id: "/root/added", name: "added", children: [addedChild])
        let sharedAfter = makeTestFileNode(id: "/root/shared.bin", name: "shared.bin", size: 45)
        let afterRoot = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [addedFolder, sharedAfter]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [addedFolder, sharedAfter],
            addedFolder.id: [addedChild],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(
            comparison.rows.map { "\($0.kind.rawValue):\($0.relativePath)" },
            [
                "added:added",
                "grew:shared.bin",
                "removed:removed",
            ]
        )
        XCTAssertFalse(comparison.rows.contains { $0.relativePath.contains("child.bin") })
        XCTAssertEqual(comparison.summary.addedCount, 1)
        XCTAssertEqual(comparison.summary.removedCount, 1)
        XCTAssertEqual(comparison.summary.grewCount, 1)
        XCTAssertEqual(comparison.summary.changedCount, 1)
    }

    func testNestedFileGrowthDoesNotEmitAncestorDirectoryRows() async throws {
        let beforeLeaf = makeTestFileNode(id: "/root/a/b/file.bin", name: "file.bin", size: 10)
        let beforeInner = makeTestDirectoryNode(id: "/root/a/b", name: "b", children: [beforeLeaf])
        let beforeOuter = makeTestDirectoryNode(id: "/root/a", name: "a", children: [beforeInner])
        let beforeRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [beforeOuter])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeOuter],
            beforeOuter.id: [beforeInner],
            beforeInner.id: [beforeLeaf],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/root/a/b/file.bin", name: "file.bin", size: 100)
        let afterInner = makeTestDirectoryNode(id: "/root/a/b", name: "b", children: [afterLeaf])
        let afterOuter = makeTestDirectoryNode(id: "/root/a", name: "a", children: [afterInner])
        let afterRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [afterOuter])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterOuter],
            afterOuter.id: [afterInner],
            afterInner.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "a/b/file.bin")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 90)
        XCTAssertFalse(comparison.rows.contains { $0.isDirectory })
        XCTAssertEqual(comparison.summary.fileCountDelta, 0)
        XCTAssertEqual(comparison.summary.grewCount, 1)
        XCTAssertEqual(comparison.summary.changedCount, 1)
        // The aggregate delta still reflects the full change even though no directory row is emitted.
        XCTAssertEqual(comparison.summary.allocatedDelta, 90)
    }

    func testSummarizedLeafDirectoryGrowthEmitsRow() async throws {
        // An auto-summarized directory is a leaf node with no indexed children, so its size
        // change has no descendant rows to represent it and must be reported directly.
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/before/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterCache = makeTestSummarizedDirectoryNode(id: "/after/cache", name: "cache", size: 500)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterCache]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "cache")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertTrue(comparison.rows[0].isDirectory)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 400)
        XCTAssertEqual(comparison.summary.grewCount, 1)
    }

    func testExpandedVersionOfSummarizedDirectorySuppressesMaterializedDescendants() async throws {
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/root/cache/file.bin", name: "file.bin", size: 100)
        let afterCache = makeTestDirectoryNode(id: "/root/cache", name: "cache", children: [afterLeaf])
        let afterRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterCache],
            afterCache.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.changedCount, 0)
    }

    func testMaterializationBoundaryDiscoveryChecksEveryChangedPathAncestor() async throws {
        let beforeCache = makeTestSummarizedDirectoryNode(
            id: "/before/a/cache",
            name: "cache",
            size: 100
        )
        let beforeA = makeTestDirectoryNode(id: "/before/a", name: "a", children: [beforeCache])
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeA])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeA],
            beforeA.id: [beforeCache],
        ])

        let afterLeaf = makeTestFileNode(id: "/after/a/cache/file.bin", name: "file.bin", size: 100)
        let afterCache = makeTestDirectoryNode(id: "/after/a/cache", name: "cache", children: [afterLeaf])
        let afterA = makeTestDirectoryNode(id: "/after/a", name: "a", children: [afterCache])
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterA])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterA],
            afterA.id: [afterCache],
            afterCache.id: [afterLeaf],
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }

    func testExpandedVersionOfSummarizedDirectoryReportsOnlyBoundaryDelta() async throws {
        let beforeCache = makeTestSummarizedDirectoryNode(id: "/before/cache", name: "cache", size: 100)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [beforeCache])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeCache]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLeaf = makeTestFileNode(id: "/after/cache/file.bin", name: "file.bin", size: 150)
        let afterCache = makeTestDirectoryNode(id: "/after/cache", name: "cache", children: [afterLeaf])
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [afterCache])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterCache],
            afterCache.id: [afterLeaf],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "cache")
        XCTAssertEqual(comparison.rows[0].kind, .grew)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 50)
        XCTAssertEqual(comparison.summary.allocatedDelta, 50)
    }

    func testNewHardLinkDoesNotMoveAllocatedSizeFromSharedPath() async throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let beforeShared = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 1
        )
        let beforeRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [beforeShared])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeShared]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterNewLink = makeTestFileNode(
            id: "/root/a/new.bin",
            name: "new.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let afterFolder = makeTestDirectoryNode(id: "/root/a", name: "a", children: [afterNewLink])
        let afterShared = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [afterFolder, afterShared]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterFolder, afterShared],
            afterFolder.id: [afterNewLink],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        XCTAssertEqual(comparison.rows[0].relativePath, "a")
        XCTAssertEqual(comparison.rows[0].kind, .added)
        XCTAssertEqual(comparison.rows[0].afterAllocatedSize, 0)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 0)
        XCTAssertFalse(comparison.rows.contains { $0.relativePath == "z.bin" })
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }

    func testNewCloneDoesNotMoveSharedAllocationFromExistingFile() async throws {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let sourceIdentity = FileIdentity(device: 1, inode: 100)
        let beforeSource = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 120,
            unduplicatedAllocatedSize: 120,
            dataAllocatedSize: 100,
            fileIdentity: sourceIdentity
        )
        let afterClone = makeTestFileNode(
            id: "/root/a.bin",
            name: "a.bin",
            size: 110,
            unduplicatedAllocatedSize: 110,
            dataAllocatedSize: 100,
            fileIdentity: FileIdentity(device: 1, inode: 200),
            cloneIdentity: cloneIdentity
        )
        let afterSource = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 20,
            unduplicatedAllocatedSize: 120,
            dataAllocatedSize: 100,
            fileIdentity: sourceIdentity,
            cloneIdentity: cloneIdentity
        )

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([beforeSource]),
            after: cloneSnapshot([afterClone, afterSource])
        )

        XCTAssertEqual(comparison.rows.map(\.relativePath), ["a.bin"])
        XCTAssertEqual(comparison.rows[0].kind, .added)
        XCTAssertEqual(comparison.rows[0].afterAllocatedSize, 10)
        XCTAssertEqual(comparison.summary.allocatedDelta, 10)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, 10)
        XCTAssertEqual(comparison.summary.grossReclaimedAllocatedSize, 0)
    }

    func testNewCloneKeepsAllocationWithRenamedSource() async throws {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let sourceIdentity = FileIdentity(device: 1, inode: 100)
        let beforeSource = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 120,
            unduplicatedAllocatedSize: 120,
            dataAllocatedSize: 100,
            fileIdentity: sourceIdentity
        )
        let afterClone = makeTestFileNode(
            id: "/root/a.bin",
            name: "a.bin",
            size: 110,
            unduplicatedAllocatedSize: 110,
            dataAllocatedSize: 100,
            fileIdentity: FileIdentity(device: 1, inode: 200),
            cloneIdentity: cloneIdentity
        )
        let afterSource = makeTestFileNode(
            id: "/root/y.bin",
            name: "y.bin",
            size: 20,
            unduplicatedAllocatedSize: 120,
            dataAllocatedSize: 100,
            fileIdentity: sourceIdentity,
            cloneIdentity: cloneIdentity
        )

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([beforeSource]),
            after: cloneSnapshot([afterClone, afterSource])
        )

        let added = try XCTUnwrap(comparison.rows.first { $0.relativePath == "a.bin" })
        let moved = try XCTUnwrap(comparison.rows.first { $0.relativePath == "y.bin" })
        XCTAssertEqual(added.afterAllocatedSize, 10)
        XCTAssertEqual(moved.kind, .moved)
        XCTAssertEqual(moved.beforeAllocatedSize, 120)
        XCTAssertEqual(moved.afterAllocatedSize, 120)
        XCTAssertEqual(comparison.summary.allocatedDelta, 10)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, 10)
        XCTAssertEqual(comparison.summary.grossReclaimedAllocatedSize, 0)
    }

    func testRemovingCloneOwnerDoesNotGrowRemainingFile() async throws {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let remainingIdentity = FileIdentity(device: 1, inode: 200)
        let beforeOwner = makeTestFileNode(
            id: "/root/a.bin",
            name: "a.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: FileIdentity(device: 1, inode: 100),
            cloneIdentity: cloneIdentity
        )
        let beforeRemaining = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: remainingIdentity,
            cloneIdentity: cloneIdentity
        )
        let afterRemaining = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: remainingIdentity
        )

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([beforeOwner, beforeRemaining]),
            after: cloneSnapshot([afterRemaining])
        )

        XCTAssertEqual(comparison.rows.map(\.relativePath), ["a.bin"])
        XCTAssertEqual(comparison.rows[0].kind, .removed)
        XCTAssertEqual(comparison.rows[0].beforeAllocatedSize, 0)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }

    func testRemovingCloneOwnerReportsOnlyItsUniqueResourceForkAllocation() async throws {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let remainingIdentity = FileIdentity(device: 1, inode: 200)
        let beforeOwner = makeTestFileNode(
            id: "/root/a.bin",
            name: "a.bin",
            size: 110,
            unduplicatedAllocatedSize: 110,
            dataAllocatedSize: 100,
            fileIdentity: FileIdentity(device: 1, inode: 100),
            cloneIdentity: cloneIdentity
        )
        let beforeRemaining = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            dataAllocatedSize: 100,
            fileIdentity: remainingIdentity,
            cloneIdentity: cloneIdentity
        )
        let afterRemaining = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            dataAllocatedSize: 100,
            fileIdentity: remainingIdentity
        )

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([beforeOwner, beforeRemaining]),
            after: cloneSnapshot([afterRemaining])
        )

        XCTAssertEqual(comparison.rows.map(\.relativePath), ["a.bin"])
        XCTAssertEqual(comparison.rows[0].beforeAllocatedSize, 10)
        XCTAssertEqual(comparison.rows[0].allocatedDelta, -10)
        XCTAssertEqual(comparison.summary.allocatedDelta, -10)
        XCTAssertEqual(comparison.summary.grossReclaimedAllocatedSize, 10)
    }

    func testIncompleteCloneGroupDoesNotInventAllocationDuringNormalization() async throws {
        let sourceIdentity = FileIdentity(device: 1, inode: 100)
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let beforeOpaqueOwner = makeTestSummarizedDirectoryNode(
            id: "/root/a-cache",
            name: "a-cache",
            size: 0
        )
        let beforeSource = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 100,
            unduplicatedAllocatedSize: 100,
            fileIdentity: sourceIdentity
        )
        let afterOpaqueOwner = makeTestSummarizedDirectoryNode(
            id: "/root/a-cache",
            name: "a-cache",
            size: 100
        )
        let afterSource = makeTestFileNode(
            id: "/root/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: sourceIdentity,
            cloneIdentity: cloneIdentity
        )

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([beforeOpaqueOwner, beforeSource]),
            after: cloneSnapshot([afterOpaqueOwner, afterSource])
        )
        let allocatedDeltaByPath = Dictionary(
            uniqueKeysWithValues: comparison.rows.map { ($0.relativePath, $0.allocatedDelta) }
        )

        XCTAssertEqual(allocatedDeltaByPath, ["a-cache": 100, "z.bin": -100])
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.attributedAllocatedDelta, 0)
    }

    func testDivergedCloneMembersAreNotKeptAsFullClones() async throws {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let firstIdentity = FileIdentity(device: 1, inode: 100)
        let secondIdentity = FileIdentity(device: 1, inode: 200)
        let beforeFiles = [
            makeTestFileNode(
                id: "/root/a.bin",
                name: "a.bin",
                size: 100,
                unduplicatedAllocatedSize: 100,
                fileIdentity: firstIdentity,
                cloneIdentity: cloneIdentity
            ),
            makeTestFileNode(
                id: "/root/z.bin",
                name: "z.bin",
                size: 0,
                unduplicatedAllocatedSize: 100,
                fileIdentity: secondIdentity,
                cloneIdentity: cloneIdentity
            ),
        ]
        let afterFiles = [
            makeTestFileNode(
                id: "/root/a.bin",
                name: "a.bin",
                size: 100,
                unduplicatedAllocatedSize: 100,
                fileIdentity: firstIdentity
            ),
            makeTestFileNode(
                id: "/root/z.bin",
                name: "z.bin",
                size: 100,
                unduplicatedAllocatedSize: 100,
                fileIdentity: secondIdentity
            ),
        ]

        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot(beforeFiles),
            after: cloneSnapshot(afterFiles)
        )

        XCTAssertEqual(comparison.rows.map(\.relativePath), ["z.bin"])
        XCTAssertEqual(comparison.rows[0].allocatedDelta, 100)
        XCTAssertEqual(comparison.summary.allocatedDelta, 100)
    }

    func testMultipleHardLinkGroupsKeepSparseAncestorAdjustmentsBalanced() async throws {
        let firstIdentity = FileIdentity(device: 1, inode: 101)
        let secondIdentity = FileIdentity(device: 1, inode: 202)

        func hardLink(
            root: String,
            name: String,
            size: Int64,
            unduplicatedSize: Int64,
            identity: FileIdentity
        ) -> FileNodeRecord {
            makeTestFileNode(
                id: "\(root)/folder/\(name)",
                name: name,
                size: size,
                unduplicatedAllocatedSize: unduplicatedSize,
                fileIdentity: identity,
                linkCount: 2
            )
        }

        let beforeFiles = [
            hardLink(root: "/root", name: "a-one", size: 0, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/root", name: "z-one", size: 100, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/root", name: "a-two", size: 0, unduplicatedSize: 200, identity: secondIdentity),
            hardLink(root: "/root", name: "z-two", size: 200, unduplicatedSize: 200, identity: secondIdentity),
        ]
        let beforeFolder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: beforeFiles)
        let beforeRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [beforeFolder])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeFolder],
            beforeFolder.id: beforeFiles,
        ])

        let afterFiles = [
            hardLink(root: "/root", name: "a-one", size: 100, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/root", name: "z-one", size: 0, unduplicatedSize: 100, identity: firstIdentity),
            hardLink(root: "/root", name: "a-two", size: 200, unduplicatedSize: 200, identity: secondIdentity),
            hardLink(root: "/root", name: "z-two", size: 0, unduplicatedSize: 200, identity: secondIdentity),
        ]
        let afterFolder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: afterFiles)
        let afterRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [afterFolder])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterFolder],
            afterFolder.id: afterFiles,
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.attributedAllocatedDelta, 0)
    }

    func testUnambiguousFileIdentityMoveIsReportedAtDestination() async throws {
        let identity = FileIdentity(device: 1, inode: 900)
        let beforeFile = makeTestFileNode(
            id: "/scan/Documents/old-name.bin",
            name: "old-name.bin",
            size: 64,
            fileIdentity: identity
        )
        let beforeDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [beforeFile]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeDocuments]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeDocuments],
            beforeDocuments.id: [beforeFile],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(
            id: "/scan/Documents/new-name.bin",
            name: "new-name.bin",
            size: 64,
            fileIdentity: identity
        )
        let afterDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [afterFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterDocuments]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterDocuments],
            afterDocuments.id: [afterFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.rows.count, 1)
        let row = try XCTUnwrap(comparison.rows.first)
        XCTAssertEqual(row.kind, .moved)
        XCTAssertEqual(row.relativePath, "Documents/new-name.bin")
        XCTAssertEqual(row.movedFromRelativePath, "Documents/old-name.bin")
        XCTAssertEqual(row.allocatedDelta, 0)
        XCTAssertEqual(comparison.summary.addedCount, 0)
        XCTAssertEqual(comparison.summary.removedCount, 0)
        XCTAssertEqual(comparison.summary.movedCount, 1)

        XCTAssertEqual(comparison.topLevelChanges.count, 1)
        let location = try XCTUnwrap(comparison.topLevelChanges.first)
        XCTAssertEqual(location.relativePath, "Documents")
        XCTAssertEqual(location.movedCount, 1)
        XCTAssertEqual(location.representativeRelativePath, "Documents/new-name.bin")
        XCTAssertEqual(location.afterNode?.id, "/scan/Documents")

        let movedProjection = comparison.changeTree.significantProjection(changeKinds: [.moved])
        XCTAssertEqual(movedProjection.roots.map(\.relativePath), ["Documents"])
        let allActivityProjection = comparison.changeTree.significantProjection(
            changeKinds: Set(ScanComparisonChangeKind.allCases)
        )
        XCTAssertEqual(allActivityProjection.roots.map(\.relativePath), ["Documents"])
    }

    func testLegacyResourceIdentityMatchesBulkIdentityForMoveOnSameVolume() async throws {
        let volumeToken: UInt64 = 0xA11CE
        let fileID: UInt64 = 900
        let rootIdentity = resourceIdentity(fileID: 1, volumeToken: volumeToken)
        let beforeFile = makeTestFileNode(
            id: "/scan/old-name.bin",
            name: "old-name.bin",
            size: 64,
            fileIdentity: resourceIdentity(fileID: fileID, volumeToken: volumeToken)
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeFile],
            fileIdentity: rootIdentity
        )
        let beforeSnapshot = makeTestSnapshot(
            root: beforeRoot,
            store: FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [beforeFile]])
        )

        let afterFile = makeTestFileNode(
            id: "/scan/new-name.bin",
            name: "new-name.bin",
            size: 64,
            fileIdentity: FileIdentity(device: 99, inode: fileID)
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterFile],
            fileIdentity: rootIdentity
        )
        let afterSnapshot = makeTestSnapshot(
            root: afterRoot,
            store: FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [afterFile]])
        )

        let comparison = try await ScanComparisonService().compare(
            before: beforeSnapshot,
            after: afterSnapshot
        )

        XCTAssertEqual(comparison.rows.map(\.kind), [.moved])
        XCTAssertEqual(comparison.rows.first?.movedFromRelativePath, "old-name.bin")
        XCTAssertEqual(comparison.rows.first?.relativePath, "new-name.bin")
    }

    func testAmbiguousFileIdentityDoesNotInferMove() async throws {
        let identity = FileIdentity(device: 1, inode: 901)
        let beforeFirst = makeTestFileNode(
            id: "/scan/Documents/first.bin",
            name: "first.bin",
            size: 10,
            fileIdentity: identity
        )
        let beforeSecond = makeTestFileNode(
            id: "/scan/Documents/second.bin",
            name: "second.bin",
            size: 10,
            fileIdentity: identity
        )
        let beforeDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [beforeFirst, beforeSecond]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeDocuments]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeDocuments],
            beforeDocuments.id: [beforeFirst, beforeSecond],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterFile = makeTestFileNode(
            id: "/scan/Documents/renamed.bin",
            name: "renamed.bin",
            size: 10,
            fileIdentity: identity
        )
        let afterDocuments = makeTestDirectoryNode(
            id: "/scan/Documents",
            name: "Documents",
            children: [afterFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterDocuments]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterDocuments],
            afterDocuments.id: [afterFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertFalse(comparison.rows.contains { $0.kind == .moved })
        XCTAssertEqual(comparison.summary.addedCount, 1)
        XCTAssertEqual(comparison.summary.removedCount, 2)
        XCTAssertEqual(comparison.summary.movedCount, 0)
    }

    func testTopLevelChangesPartitionFinalRowsAndReportGrossSpaceChanges() async throws {
        let beforeLibraryFile = makeTestFileNode(
            id: "/scan/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let beforeDownloadsFile = makeTestFileNode(
            id: "/scan/Downloads/old.bin",
            name: "old.bin",
            size: 20
        )
        let beforeLibrary = makeTestDirectoryNode(
            id: "/scan/Library",
            name: "Library",
            children: [beforeLibraryFile]
        )
        let beforeDownloads = makeTestDirectoryNode(
            id: "/scan/Downloads",
            name: "Downloads",
            children: [beforeDownloadsFile]
        )
        let beforeWork = makeTestDirectoryNode(id: "/scan/Work", name: "Work", children: [])
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeLibrary, beforeDownloads, beforeWork]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeLibrary, beforeDownloads, beforeWork],
            beforeLibrary.id: [beforeLibraryFile],
            beforeDownloads.id: [beforeDownloadsFile],
            beforeWork.id: [],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterLibraryFile = makeTestFileNode(
            id: "/scan/Library/cache.bin",
            name: "cache.bin",
            size: 30
        )
        let afterWorkFile = makeTestFileNode(
            id: "/scan/Work/new.bin",
            name: "new.bin",
            size: 40
        )
        let afterLibrary = makeTestDirectoryNode(
            id: "/scan/Library",
            name: "Library",
            children: [afterLibraryFile]
        )
        let afterDownloads = makeTestDirectoryNode(id: "/scan/Downloads", name: "Downloads", children: [])
        let afterWork = makeTestDirectoryNode(
            id: "/scan/Work",
            name: "Work",
            children: [afterWorkFile]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterLibrary, afterDownloads, afterWork]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterLibrary, afterDownloads, afterWork],
            afterLibrary.id: [afterLibraryFile],
            afterDownloads.id: [],
            afterWork.id: [afterWorkFile],
        ])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertEqual(comparison.topLevelChanges.map(\.relativePath), ["Work", "Downloads", "Library"])
        XCTAssertEqual(comparison.topLevelChanges.map(\.allocatedDelta), [40, -20, 20])
        XCTAssertEqual(comparison.topLevelChanges[0].addedCount, 1)
        XCTAssertEqual(comparison.topLevelChanges[1].removedCount, 1)
        XCTAssertEqual(comparison.topLevelChanges[2].grewCount, 1)
        XCTAssertEqual(comparison.topLevelChanges.reduce(0) { $0 + $1.allocatedDelta }, 40)
        XCTAssertEqual(comparison.topLevelChanges.reduce(0) { $0 + $1.affectedCount }, 3)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, 60)
        XCTAssertEqual(comparison.summary.grossReclaimedAllocatedSize, 20)
        XCTAssertEqual(comparison.summary.attributedAllocatedDelta, 40)
        XCTAssertEqual(comparison.summary.allocatedDelta, 40)
    }

    func testWarningsSuppressUncertainAddedAndRemovedRows() async throws {
        let beforePrivateFile = makeTestFileNode(
            id: "/scan/Private/old.bin",
            name: "old.bin",
            size: 100
        )
        let beforePrivate = makeTestDirectoryNode(
            id: "/scan/Private",
            name: "Private",
            children: [beforePrivateFile]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforePrivate]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforePrivate],
            beforePrivate.id: [beforePrivateFile],
        ])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let afterEmptyRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let afterEmptyStore = FileTreeStore(root: afterEmptyRoot, childrenByID: [afterEmptyRoot.id: []])
        let afterWarning = ScanWarning(
            path: "/scan/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let afterWithWarning = makeTestSnapshot(
            root: afterEmptyRoot,
            store: afterEmptyStore,
            warnings: [afterWarning]
        )

        let removalComparison = try await ScanComparisonService().compare(
            before: beforeSnapshot,
            after: afterWithWarning
        )

        XCTAssertTrue(removalComparison.rows.isEmpty)
        XCTAssertEqual(removalComparison.summary.removedCount, 0)
        XCTAssertEqual(removalComparison.summary.grossReclaimedAllocatedSize, 0)
        XCTAssertEqual(removalComparison.summary.allocatedDelta, -100)
        XCTAssertEqual(removalComparison.summary.attributedAllocatedDelta, 0)
        XCTAssertTrue(removalComparison.coverage.issues.contains(.afterWarnings(1)))

        let beforeWarning = ScanWarning(
            path: "/scan/Private",
            message: "Permission denied",
            category: .permissionDenied
        )
        let beforeEmptyRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let beforeEmptyStore = FileTreeStore(root: beforeEmptyRoot, childrenByID: [beforeEmptyRoot.id: []])
        let beforeWithWarning = makeTestSnapshot(
            root: beforeEmptyRoot,
            store: beforeEmptyStore,
            warnings: [beforeWarning]
        )

        let additionComparison = try await ScanComparisonService().compare(
            before: beforeWithWarning,
            after: beforeSnapshot
        )

        XCTAssertTrue(additionComparison.rows.isEmpty)
        XCTAssertEqual(additionComparison.summary.addedCount, 0)
        XCTAssertEqual(additionComparison.summary.grossIncreasedAllocatedSize, 0)
        XCTAssertEqual(additionComparison.summary.allocatedDelta, 100)
        XCTAssertEqual(additionComparison.summary.attributedAllocatedDelta, 0)
        XCTAssertTrue(additionComparison.coverage.issues.contains(.beforeWarnings(1)))
    }

    func testWarningBoundaryIndexHandlesAncestorsDescendantsAndSiblingPrefixes() async throws {
        let emptyRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let emptyStore = FileTreeStore(root: emptyRoot, childrenByID: [emptyRoot.id: []])
        let descendantWarning = ScanWarning(
            path: "/scan/Private/blocked",
            message: "Permission denied",
            category: .permissionDenied
        )
        let before = makeTestSnapshot(
            root: emptyRoot,
            store: emptyStore,
            warnings: [descendantWarning]
        )

        let privateFile = makeTestFileNode(
            id: "/scan/Private/new.bin",
            name: "new.bin",
            size: 100
        )
        let privateFolder = makeTestDirectoryNode(
            id: "/scan/Private",
            name: "Private",
            children: [privateFile]
        )
        let siblingPrefix = makeTestFileNode(
            id: "/scan/Privateer.bin",
            name: "Privateer.bin",
            size: 50
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [privateFolder, siblingPrefix]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [privateFolder, siblingPrefix],
            privateFolder.id: [privateFile],
        ])

        let descendantComparison = try await ScanComparisonService().compare(
            before: before,
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        XCTAssertEqual(descendantComparison.rows.map(\.relativePath), ["Privateer.bin"])

        let beforePublic = makeTestDirectoryNode(id: "/scan/Public", name: "Public", children: [])
        let beforePublicRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforePublic]
        )
        let beforePublicStore = FileTreeStore(root: beforePublicRoot, childrenByID: [
            beforePublicRoot.id: [beforePublic],
            beforePublic.id: [],
        ])
        let ancestorWarning = ScanWarning(
            path: "/scan/Public",
            message: "Permission denied",
            category: .permissionDenied
        )
        let beforeWithAncestorWarning = makeTestSnapshot(
            root: beforePublicRoot,
            store: beforePublicStore,
            warnings: [ancestorWarning]
        )
        let publicFile = makeTestFileNode(
            id: "/scan/Public/new.bin",
            name: "new.bin",
            size: 100
        )
        let afterPublic = makeTestDirectoryNode(
            id: "/scan/Public",
            name: "Public",
            children: [publicFile]
        )
        let afterPublicRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterPublic]
        )
        let afterPublicStore = FileTreeStore(root: afterPublicRoot, childrenByID: [
            afterPublicRoot.id: [afterPublic],
            afterPublic.id: [publicFile],
        ])

        let ancestorComparison = try await ScanComparisonService().compare(
            before: beforeWithAncestorWarning,
            after: makeTestSnapshot(root: afterPublicRoot, store: afterPublicStore)
        )

        XCTAssertTrue(ancestorComparison.rows.isEmpty)
    }

    func testCoverageIsHighForCompleteEquivalentSnapshotsWithKnownOptions() async throws {
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let store = FileTreeStore(root: root, childrenByID: [root.id: []])
        let target = makeTestTarget("/scan")
        let options = ScanOptions()
        let before = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            isComplete: true,
            scanOptions: options
        )
        let after = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            isComplete: true,
            scanOptions: options
        )

        let comparison = try await ScanComparisonService().compare(before: before, after: after)

        XCTAssertEqual(comparison.coverage.confidence, .high)
        XCTAssertTrue(comparison.coverage.issues.isEmpty)
        XCTAssertTrue(comparison.coverage.targetsMatch)
        XCTAssertEqual(comparison.coverage.scanOptionsMatch, true)
    }

    func testRowQuerySortsDeltaByDisplayedSignedValue() throws {
        let grewBefore = makeTestFileNode(id: "/before/grew.bin", name: "grew.bin", size: 10)
        let grewAfter = makeTestFileNode(id: "/after/grew.bin", name: "grew.bin", size: 20)
        let shrankBefore = makeTestFileNode(id: "/before/shrank.bin", name: "shrank.bin", size: 100)
        let shrankAfter = makeTestFileNode(id: "/after/shrank.bin", name: "shrank.bin", size: 20)
        let rows = [
            ScanComparisonRow(
                relativePath: "shrank.bin",
                kind: .shrank,
                beforeNode: shrankBefore,
                afterNode: shrankAfter
            ),
            ScanComparisonRow(
                relativePath: "grew.bin",
                kind: .grew,
                beforeNode: grewBefore,
                afterNode: grewAfter
            ),
        ]
        let query = ScanComparisonRowQuery(
            searchText: "",
            sortOrder: [ScanComparisonRowComparator(field: .allocatedDelta, order: .reverse)]
        )

        let result = try query.applying(to: rows, cancellationCheck: {})

        XCTAssertEqual(result.map(\.relativePath), ["grew.bin", "shrank.bin"])
    }

    func testRowQueryUsesSecondaryDescriptorBeforeDeterministicFallback() throws {
        let alpha = makeTestFileNode(id: "/after/alpha.bin", name: "alpha.bin", size: 10)
        let zeta = makeTestFileNode(id: "/after/zeta.bin", name: "zeta.bin", size: 10)
        let rows = [
            ScanComparisonRow(
                relativePath: "alpha.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: alpha
            ),
            ScanComparisonRow(
                relativePath: "zeta.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: zeta
            ),
        ]
        let query = ScanComparisonRowQuery(
            searchText: "",
            sortOrder: [
                ScanComparisonRowComparator(field: .allocatedDelta, order: .reverse),
                ScanComparisonRowComparator(field: .relativePath, order: .reverse),
            ]
        )

        XCTAssertEqual(
            try query.applying(to: rows, cancellationCheck: {}).map(\.relativePath),
            ["zeta.bin", "alpha.bin"]
        )
    }

    func testComparisonServiceUsesDeterministicFallbackForEqualImpactRows() async throws {
        let beforeDocuments = makeTestDirectoryNode(
            id: "/before/Documents",
            name: "Documents",
            children: []
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/before",
            name: "before",
            children: [beforeDocuments]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeDocuments],
            beforeDocuments.id: [],
        ])
        let alpha = makeTestFileNode(
            id: "/after/Documents/alpha.bin",
            name: "alpha.bin",
            size: 10
        )
        let zeta = makeTestFileNode(
            id: "/after/Documents/zeta.bin",
            name: "zeta.bin",
            size: 10
        )
        let afterDocuments = makeTestDirectoryNode(
            id: "/after/Documents",
            name: "Documents",
            children: [alpha, zeta]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/after",
            name: "after",
            children: [afterDocuments]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterDocuments],
            afterDocuments.id: [alpha, zeta],
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        XCTAssertEqual(
            comparison.rows.map(\.relativePath),
            ["Documents/alpha.bin", "Documents/zeta.bin"]
        )
        XCTAssertEqual(
            comparison.topLevelChanges.first?.representativeRelativePath,
            "Documents/alpha.bin"
        )
    }

    func testRowQueryFiltersKindAndNormalizedPath() throws {
        let addedNode = makeTestFileNode(
            id: "/after/Library/Application Support/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let removedNode = makeTestFileNode(id: "/before/other.bin", name: "other.bin", size: 20)
        let rows = [
            ScanComparisonRow(
                relativePath: "Library/Application Support/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: addedNode
            ),
            ScanComparisonRow(
                relativePath: "other.bin",
                kind: .removed,
                beforeNode: removedNode,
                afterNode: nil
            ),
        ]
        let query = ScanComparisonRowQuery(
            changeKinds: [.added],
            searchText: "application support",
            sortOrder: []
        )

        let result = try query.applying(to: rows, cancellationCheck: {})

        XCTAssertEqual(result.map(\.relativePath), ["Library/Application Support/cache.bin"])
    }

    func testRowQuerySearchIndexPreservesCaseDiacriticNameAndPathMatching() throws {
        let cafe = makeTestFileNode(
            id: "/after/Library/Café/cache.bin",
            name: "résumé.bin",
            size: 10
        )
        let row = ScanComparisonRow(
            relativePath: "Library/Café/cache.bin",
            kind: .added,
            beforeNode: nil,
            afterNode: cafe
        )
        let rows = [row]
        let index = try ScanComparisonSearchIndex(rows: rows, cancellationCheck: {})

        XCTAssertEqual(
            try ScanComparisonRowQuery(searchText: "RESUME", sortOrder: [])
                .applying(to: rows, searchIndex: index, cancellationCheck: {})
                .map(\.id),
            [row.id]
        )
        XCTAssertEqual(
            try ScanComparisonRowQuery(searchText: "library/cafe", sortOrder: [])
                .applying(to: rows, searchIndex: index, cancellationCheck: {})
                .map(\.id),
            [row.id]
        )
        XCTAssertTrue(
            try ScanComparisonRowQuery(searchText: "resume\nlibrary", sortOrder: [])
                .applying(to: rows, searchIndex: index, cancellationCheck: {})
                .isEmpty
        )
    }

    func testRowQueryFiltersExactLocationPrefix() throws {
        let libraryNode = makeTestFileNode(
            id: "/after/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let librarySupportNode = makeTestFileNode(
            id: "/after/Library Support/cache.bin",
            name: "cache.bin",
            size: 20
        )
        let rows = [
            ScanComparisonRow(
                relativePath: "Library/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: libraryNode
            ),
            ScanComparisonRow(
                relativePath: "Library Support/cache.bin",
                kind: .added,
                beforeNode: nil,
                afterNode: librarySupportNode
            ),
        ]
        let query = ScanComparisonRowQuery(
            searchText: "",
            sortOrder: [],
            pathPrefix: "Library"
        )

        XCTAssertEqual(
            try query.applying(to: rows, cancellationCheck: {}).map(\.relativePath),
            ["Library/cache.bin"]
        )
    }

    func testUnchangedAndRootRowsAreExcluded() async throws {
        let unchangedBefore = makeTestFileNode(id: "/before/unchanged.bin", name: "unchanged.bin", size: 20)
        let beforeRoot = makeTestDirectoryNode(id: "/before", name: "before", children: [unchangedBefore])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [unchangedBefore]])
        let beforeSnapshot = makeTestSnapshot(root: beforeRoot, store: beforeStore)

        let unchangedAfter = makeTestFileNode(id: "/after/unchanged.bin", name: "unchanged.bin", size: 20)
        let afterRoot = makeTestDirectoryNode(id: "/after", name: "after", children: [unchangedAfter])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: [unchangedAfter]])
        let afterSnapshot = makeTestSnapshot(root: afterRoot, store: afterStore)

        let comparison = try await ScanComparisonService().compare(before: beforeSnapshot, after: afterSnapshot)

        XCTAssertTrue(comparison.rows.isEmpty)
        XCTAssertEqual(comparison.summary.changedCount, 0)
        XCTAssertEqual(comparison.summary.allocatedDelta, 0)
    }

    func testChangeTreeRollsEvidenceIntoEveryAncestorWithoutHidingChurn() async throws {
        let beforeCache = makeTestFileNode(
            id: "/scan/Users/colin/Library/cache.bin",
            name: "cache.bin",
            size: 10
        )
        let beforeOld = makeTestFileNode(
            id: "/scan/Users/colin/Downloads/old.bin",
            name: "old.bin",
            size: 60
        )
        let beforeApp = makeTestFileNode(
            id: "/scan/Applications/app.bin",
            name: "app.bin",
            size: 10
        )
        let beforeLibrary = makeTestDirectoryNode(
            id: "/scan/Users/colin/Library",
            name: "Library",
            children: [beforeCache]
        )
        let beforeDownloads = makeTestDirectoryNode(
            id: "/scan/Users/colin/Downloads",
            name: "Downloads",
            children: [beforeOld]
        )
        let beforeColin = makeTestDirectoryNode(
            id: "/scan/Users/colin",
            name: "colin",
            children: [beforeLibrary, beforeDownloads]
        )
        let beforeUsers = makeTestDirectoryNode(
            id: "/scan/Users",
            name: "Users",
            children: [beforeColin]
        )
        let beforeApplications = makeTestDirectoryNode(
            id: "/scan/Applications",
            name: "Applications",
            children: [beforeApp]
        )
        let beforeRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [beforeUsers, beforeApplications]
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeUsers, beforeApplications],
            beforeUsers.id: [beforeColin],
            beforeColin.id: [beforeLibrary, beforeDownloads],
            beforeLibrary.id: [beforeCache],
            beforeDownloads.id: [beforeOld],
            beforeApplications.id: [beforeApp],
        ])

        let afterCache = makeTestFileNode(
            id: "/scan/Users/colin/Library/cache.bin",
            name: "cache.bin",
            size: 110
        )
        let afterApp = makeTestFileNode(
            id: "/scan/Applications/app.bin",
            name: "app.bin",
            size: 50
        )
        let afterLibrary = makeTestDirectoryNode(
            id: "/scan/Users/colin/Library",
            name: "Library",
            children: [afterCache]
        )
        let afterDownloads = makeTestDirectoryNode(
            id: "/scan/Users/colin/Downloads",
            name: "Downloads",
            children: []
        )
        let afterColin = makeTestDirectoryNode(
            id: "/scan/Users/colin",
            name: "colin",
            children: [afterLibrary, afterDownloads]
        )
        let afterUsers = makeTestDirectoryNode(
            id: "/scan/Users",
            name: "Users",
            children: [afterColin]
        )
        let afterApplications = makeTestDirectoryNode(
            id: "/scan/Applications",
            name: "Applications",
            children: [afterApp]
        )
        let afterRoot = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [afterUsers, afterApplications]
        )
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [afterUsers, afterApplications],
            afterUsers.id: [afterColin],
            afterColin.id: [afterLibrary, afterDownloads],
            afterLibrary.id: [afterCache],
            afterDownloads.id: [],
            afterApplications.id: [afterApp],
        ])

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let users = try XCTUnwrap(comparison.changeTree.node(at: "Users"))
        XCTAssertEqual(users.increasedAllocatedSize, 100)
        XCTAssertEqual(users.reclaimedAllocatedSize, 60)
        XCTAssertEqual(users.allocatedDelta, 40)
        XCTAssertEqual(users.affectedCount, 2)
        XCTAssertEqual(users.childPaths, ["Users/colin"])

        let colin = try XCTUnwrap(comparison.changeTree.node(at: "Users/colin"))
        XCTAssertEqual(colin.increasedAllocatedSize, 100)
        XCTAssertEqual(colin.reclaimedAllocatedSize, 60)
        XCTAssertEqual(colin.childPaths, ["Users/colin/Library", "Users/colin/Downloads"])
        XCTAssertEqual(comparison.changeTree.rootPaths, ["Users", "Applications"])
        XCTAssertEqual(comparison.topLevelChanges.map(\.relativePath), ["Users", "Applications"])
        XCTAssertEqual(comparison.topLevelChanges.first?.increasedAllocatedSize, 100)
        XCTAssertEqual(comparison.topLevelChanges.first?.reclaimedAllocatedSize, 60)
        XCTAssertEqual(
            comparison.changeTree.rootPaths.compactMap(comparison.changeTree.node).reduce(0) {
                $0 + $1.increasedAllocatedSize
            },
            comparison.summary.grossIncreasedAllocatedSize
        )
        XCTAssertEqual(
            comparison.changeTree.rootPaths.compactMap(comparison.changeTree.node).reduce(0) {
                $0 + $1.reclaimedAllocatedSize
            },
            comparison.summary.grossReclaimedAllocatedSize
        )
    }

    func testSignificantProjectionCoversGrowthAndReclamationIndependently() async throws {
        let beforeNodes = [
            makeTestFileNode(id: "/scan/growth.bin", name: "growth.bin", size: 0),
            makeTestFileNode(id: "/scan/reclaimed.bin", name: "reclaimed.bin", size: 5),
            makeTestFileNode(id: "/scan/tail.bin", name: "tail.bin", size: 0),
        ]
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: beforeNodes)
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: beforeNodes])
        let afterNodes = [
            makeTestFileNode(id: "/scan/growth.bin", name: "growth.bin", size: 95),
            makeTestFileNode(id: "/scan/reclaimed.bin", name: "reclaimed.bin", size: 0),
            makeTestFileNode(id: "/scan/tail.bin", name: "tail.bin", size: 5),
        ]
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: afterNodes)
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [afterRoot.id: afterNodes])
        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let projection = comparison.changeTree.significantProjection(
            changeKinds: Set(ScanComparisonChangeKind.allCases),
            coverageTarget: 0.95
        )

        XCTAssertEqual(projection.namedRootCount, 2)
        XCTAssertEqual(projection.hiddenRootCount, 1)
        XCTAssertTrue(projection.roots.contains { $0.relativePath == "growth.bin" })
        XCTAssertTrue(projection.roots.contains { $0.relativePath == "reclaimed.bin" })
        XCTAssertTrue(projection.roots.contains(where: \.isRemainder))
    }

    func testSignificantProjectionHonorsExactChangeKindSelection() async throws {
        let grewBefore = makeTestFileNode(id: "/scan/grew.bin", name: "grew.bin", size: 10)
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [grewBefore])
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [beforeRoot.id: [grewBefore]])

        let grewAfter = makeTestFileNode(id: "/scan/grew.bin", name: "grew.bin", size: 20)
        let added = makeTestFileNode(id: "/scan/added.bin", name: "added.bin", size: 50)
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [grewAfter, added])
        let afterStore = FileTreeStore(root: afterRoot, childrenByID: [
            afterRoot.id: [grewAfter, added],
        ])
        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )

        let addedProjection = comparison.changeTree.significantProjection(changeKinds: [.added])
        let grewProjection = comparison.changeTree.significantProjection(changeKinds: [.grew])
        let combinedProjection = comparison.changeTree.significantProjection(changeKinds: [.added, .grew])

        XCTAssertEqual(addedProjection.roots.map(\.relativePath), ["added.bin"])
        XCTAssertEqual(addedProjection.roots.first?.increasedAllocatedSize, 50)
        XCTAssertEqual(addedProjection.roots.first?.directChangeKind, .added)
        XCTAssertEqual(grewProjection.roots.map(\.relativePath), ["grew.bin"])
        XCTAssertEqual(grewProjection.roots.first?.increasedAllocatedSize, 10)
        XCTAssertEqual(grewProjection.roots.first?.directChangeKind, .grew)
        XCTAssertEqual(Set(combinedProjection.roots.map(\.relativePath)), ["added.bin", "grew.bin"])
    }

    func testComparisonClampsAggregateStorageOverflow() async throws {
        let beforeRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [])
        let beforeStore = FileTreeStore(root: beforeRoot)
        let first = makeTestFileNode(
            id: "/scan/first.bin",
            name: "first.bin",
            size: .max
        )
        let second = makeTestFileNode(
            id: "/scan/second.bin",
            name: "second.bin",
            size: .max
        )
        let afterRoot = FileNodeRecord(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let afterStore = FileTreeStore(
            root: afterRoot,
            childrenByID: [afterRoot.id: [first, second]]
        )

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )
        let projection = comparison.changeTree.significantProjection(changeKinds: [.added])

        XCTAssertEqual(comparison.rows.count, 2)
        XCTAssertEqual(comparison.summary.grossIncreasedAllocatedSize, Int64.max)
        XCTAssertEqual(projection.totalImpact, Int64.max)
        XCTAssertEqual(projection.representedImpact, Int64.max)
    }

    func testTopLevelChangesClampLargeReclamationUnderOnePath() async throws {
        let first = makeTestFileNode(id: "/scan/folder/first.bin", name: "first.bin", size: .max)
        let second = makeTestFileNode(id: "/scan/folder/second.bin", name: "second.bin", size: .max)
        let beforeFolder = FileNodeRecord(
            id: "/scan/folder",
            url: URL(filePath: "/scan/folder", directoryHint: .isDirectory),
            name: "folder",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let beforeRoot = FileNodeRecord(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let beforeStore = FileTreeStore(root: beforeRoot, childrenByID: [
            beforeRoot.id: [beforeFolder],
            beforeFolder.id: [first, second],
        ])
        let afterFolder = makeTestDirectoryNode(id: "/scan/folder", name: "folder", children: [])
        let afterRoot = makeTestDirectoryNode(id: "/scan", name: "scan", children: [afterFolder])
        let afterStore = FileTreeStore(
            root: afterRoot,
            childrenByID: [afterRoot.id: [afterFolder]]
        )

        let comparison = try await ScanComparisonService().compare(
            before: makeTestSnapshot(root: beforeRoot, store: beforeStore),
            after: makeTestSnapshot(root: afterRoot, store: afterStore)
        )
        let location = try XCTUnwrap(comparison.topLevelChanges.first)

        XCTAssertEqual(comparison.rows.count, 2)
        XCTAssertEqual(location.relativePath, "folder")
        XCTAssertEqual(location.allocatedDelta, -Int64.max)
        XCTAssertEqual(location.absoluteAllocatedDelta, Int64.max)
        XCTAssertEqual(location.reclaimedAllocatedSize, Int64.max)
    }

    func testRowQueryCombinesSelectedChangeKinds() throws {
        let movedBefore = makeTestFileNode(id: "/before/old.bin", name: "old.bin", size: 100)
        let movedAfter = makeTestFileNode(id: "/after/new.bin", name: "new.bin", size: 150)
        let movedAndGrew = ScanComparisonRow(
            relativePath: "new.bin",
            kind: .moved,
            beforeNode: movedBefore,
            afterNode: movedAfter,
            movedFromRelativePath: "old.bin"
        )
        let removed = ScanComparisonRow(
            relativePath: "removed.bin",
            kind: .removed,
            beforeNode: makeTestFileNode(id: "/before/removed.bin", name: "removed.bin", size: 40),
            afterNode: nil
        )
        let rows = [movedAndGrew, removed]

        let movedAndRemoved = try ScanComparisonRowQuery(
            changeKinds: [.moved, .removed],
            searchText: "",
            sortOrder: []
        ).applying(to: rows, cancellationCheck: {})
        let removedOnly = try ScanComparisonRowQuery(
            changeKinds: [.removed],
            searchText: "",
            sortOrder: []
        ).applying(to: rows, cancellationCheck: {})
        let movedOnly = try ScanComparisonRowQuery(
            changeKinds: [.moved],
            searchText: "",
            sortOrder: []
        ).applying(to: rows, cancellationCheck: {})

        XCTAssertEqual(movedAndRemoved.map(\.relativePath), ["new.bin", "removed.bin"])
        XCTAssertEqual(removedOnly.map(\.relativePath), ["removed.bin"])
        XCTAssertEqual(movedOnly.map(\.relativePath), ["new.bin"])
    }

    func testSearchIndexStopsWhenCancellationIsRequested() {
        let rows = makeComparisonRows(count: 600)
        let probe = CancellationProbe(throwOnCheck: 3)

        XCTAssertThrowsError(
            try ScanComparisonSearchIndex(
                rows: rows,
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 3)
    }

    func testRowQueryStopsFilteringWhenCancellationIsRequested() {
        let rows = makeComparisonRows(count: 600)
        let probe = CancellationProbe(throwOnCheck: 3)
        let query = ScanComparisonRowQuery(searchText: "", sortOrder: [])

        XCTAssertThrowsError(
            try query.applying(
                to: rows,
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 3)
    }

    func testRowQueryStopsBetweenLargeSortRuns() {
        let rows = makeComparisonRows(count: 20_000)
        let filteringCheckCount = (rows.count + 255) / 256
        // Entry, filtering, post-filter, offset preparation, first sorted run,
        // then cancellation before the second run starts.
        let secondSortedRunCheck = 1 + filteringCheckCount + 1 + filteringCheckCount + 2
        let probe = CancellationProbe(throwOnCheck: secondSortedRunCheck)
        let query = ScanComparisonRowQuery(
            searchText: "",
            sortOrder: [
                ScanComparisonRowComparator(field: .afterAllocatedSize, order: .reverse)
            ]
        )

        XCTAssertThrowsError(
            try query.applying(
                to: rows,
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, secondSortedRunCheck)
    }

    func testSignificantProjectionCancelsDuringCoverageAndRemainderWork() async throws {
        let files = (0..<600).map {
            makeTestFileNode(id: "/root/file-\($0).bin", name: "file-\($0).bin", size: Int64($0))
        }
        let comparison = try await ScanComparisonService().compare(
            before: cloneSnapshot([]), after: cloneSnapshot(files)
        )
        var checks = 0
        let expected = comparison.changeTree.significantProjection(changeKinds: [.added])
        let measured = try comparison.changeTree.significantProjection(
            changeKinds: [.added], cancellationCheck: { checks += 1 }
        )
        XCTAssertEqual(measured, expected)
        // Cancellation after eligibility preparation and near the end of remainder aggregation.
        for limit in [6, checks - 1] {
            let probe = CancellationProbe(throwOnCheck: limit)
            XCTAssertThrowsError(try comparison.changeTree.significantProjection(
                changeKinds: [.added], cancellationCheck: probe.check
            )) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(probe.checkCount, limit)
        }
    }

    private func resourceIdentity(fileID: UInt64, volumeToken: UInt64) -> FileIdentity {
        var data = Data()
        var littleEndianFileID = fileID.littleEndian
        var littleEndianVolumeToken = volumeToken.littleEndian
        withUnsafeBytes(of: &littleEndianFileID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleEndianVolumeToken) { data.append(contentsOf: $0) }
        return FileIdentity(resourceIdentifier: data)
    }

    private func cloneSnapshot(_ files: [FileNodeRecord]) -> ScanSnapshot {
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: files)
        let store = FileTreeStore(root: root, childrenByID: [root.id: files])
        return makeTestSnapshot(root: root, store: store)
    }

    private func makeComparisonRows(count: Int) -> [ScanComparisonRow] {
        (0..<count).map { index in
            let relativePath = "file-\(index).bin"
            let node = makeTestFileNode(
                id: "/after/\(relativePath)",
                name: relativePath,
                size: Int64(index)
            )
            return ScanComparisonRow(
                relativePath: relativePath,
                kind: .added,
                beforeNode: nil,
                afterNode: node
            )
        }
    }
}
