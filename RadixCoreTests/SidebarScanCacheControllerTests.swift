import XCTest
@testable import RadixCore

final class SidebarScanCacheControllerTests: XCTestCase {
    func testCompletedScanCacheTrimsLeastRecentlyUsedSnapshotsToBudget() {
        var cache = CompletedScanCache(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 1)
        let first = makeCacheSnapshot("/cache/first")
        let second = makeCacheSnapshot("/cache/second")
        let third = makeCacheSnapshot("/cache/third")
        let options = ScanOptions()
        let firstKey = ScanCacheKey(target: first.target, options: options)
        let secondKey = ScanCacheKey(target: second.target, options: options)
        let thirdKey = ScanCacheKey(target: third.target, options: options)

        cache.store(first, for: firstKey)
        cache.store(second, for: secondKey)
        XCTAssertNotNil(cache.snapshot(for: firstKey))

        cache.store(third, for: thirdKey)

        XCTAssertNotNil(cache.snapshot(for: firstKey))
        XCTAssertNil(cache.snapshot(for: secondKey))
        XCTAssertNotNil(cache.snapshot(for: thirdKey))
    }

    func testCompletedScanCacheReplacingSnapshotKeepsNodeBudgetAccurate() {
        var cache = CompletedScanCache(minimumRetainedSnapshotCount: 1, maxTotalNodeCount: 3)
        let replaced = makeCacheSnapshot("/cache/replaced")
        let second = makeCacheSnapshot("/cache/second", childCount: 1)
        let options = ScanOptions()
        let replacedKey = ScanCacheKey(target: replaced.target, options: options)
        let secondKey = ScanCacheKey(target: second.target, options: options)

        cache.store(replaced, for: replacedKey)
        cache.store(replaced, for: replacedKey)
        cache.store(second, for: secondKey)

        XCTAssertNotNil(cache.snapshot(for: replacedKey))
        XCTAssertNotNil(cache.snapshot(for: secondKey))
    }

    func testCompletedScanCacheFindsRecentContainingSnapshotWithMatchingOptions() {
        var cache = CompletedScanCache(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 100)
        let child = makeTestDirectoryNode(id: "/cache/root/child", name: "child", children: [])
        let root = makeTestDirectoryNode(id: "/cache/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let options = ScanOptions(includeHiddenFiles: true)

        cache.store(snapshot, for: ScanCacheKey(target: snapshot.target, options: options))

        XCTAssertEqual(cache.snapshot(containing: ScanTarget(url: child.url), options: options)?.id, snapshot.id)
        XCTAssertNil(cache.snapshot(containing: snapshot.target, options: options))
        XCTAssertNil(cache.snapshot(containing: ScanTarget(url: child.url), options: ScanOptions()))
    }

    @MainActor
    func testControllerRestoresExactCachedSidebarTarget() {
        let controller = SidebarScanCacheController(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let snapshot = makeCacheSnapshot("/cache/exact")
        let options = ScanOptions(includeHiddenFiles: true)

        controller.prepareForScanStart(target: snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(snapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            snapshot.target,
            options: options,
            currentSnapshot: nil,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {
                recorder.cancelDeferredScanStartCount += 1
            },
            restoreSnapshot: { snapshot, target in
                recorder.restoredSnapshots.append(snapshot)
                recorder.restoredTargets.append(target)
            },
            startScan: { target in
                recorder.startedTargets.append(target)
            }
        )

        XCTAssertFalse(shouldStartScan)
        XCTAssertEqual(recorder.cancelDeferredScanStartCount, 1)
        XCTAssertEqual(recorder.restoredSnapshots.map(\.id), [snapshot.id])
        XCTAssertEqual(recorder.restoredTargets, [snapshot.target])
        XCTAssertTrue(recorder.startedTargets.isEmpty)
    }

    @MainActor
    func testControllerScopesCurrentSidebarSnapshotWhenDisplayedOptionsMatch() async throws {
        let controller = SidebarScanCacheController(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions(includeHiddenFiles: true)
        recorder.activeTargetID = tree.childTarget.id

        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            tree.childTarget,
            options: options,
            currentSnapshot: tree.snapshot,
            isTargetActive: { target in
                recorder.activeTargetID == target.id
            },
            cancelDeferredScanStart: {
                recorder.cancelDeferredScanStartCount += 1
            },
            restoreSnapshot: { snapshot, target in
                recorder.restoredSnapshots.append(snapshot)
                recorder.restoredTargets.append(target)
            },
            startScan: { target in
                recorder.startedTargets.append(target)
            }
        )

        XCTAssertFalse(shouldStartScan)
        try await waitForSidebarCacheCondition("scoped snapshot restore") {
            !recorder.restoredSnapshots.isEmpty
        }

        XCTAssertEqual(recorder.cancelDeferredScanStartCount, 1)
        XCTAssertEqual(recorder.restoredTargets, [tree.childTarget])
        XCTAssertEqual(recorder.restoredSnapshots.first?.target, tree.childTarget)
        XCTAssertEqual(recorder.restoredSnapshots.first?.root.id, tree.childTarget.id)
        XCTAssertTrue(recorder.startedTargets.isEmpty)
    }

    @MainActor
    func testControllerDoesNotScopeCurrentSnapshotWhenDisplayedOptionsDiffer() {
        let controller = SidebarScanCacheController(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let tree = makeParentAndChildSnapshot()
        recorder.activeTargetID = tree.childTarget.id

        controller.prepareForScanStart(
            target: tree.snapshot.target,
            options: ScanOptions(includeHiddenFiles: true)
        )
        controller.handleCompletedScanSnapshot(tree.snapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            tree.childTarget,
            options: ScanOptions(includeHiddenFiles: false),
            currentSnapshot: tree.snapshot,
            isTargetActive: { target in
                recorder.activeTargetID == target.id
            },
            cancelDeferredScanStart: {
                recorder.cancelDeferredScanStartCount += 1
            },
            restoreSnapshot: { snapshot, target in
                recorder.restoredSnapshots.append(snapshot)
                recorder.restoredTargets.append(target)
            },
            startScan: { target in
                recorder.startedTargets.append(target)
            }
        )

        XCTAssertTrue(shouldStartScan)
        XCTAssertEqual(recorder.cancelDeferredScanStartCount, 0)
        XCTAssertTrue(recorder.restoredSnapshots.isEmpty)
        XCTAssertTrue(recorder.startedTargets.isEmpty)
    }

    @MainActor
    func testControllerScopedRestoreRebalancesHardLinksInsideTarget() async throws {
        let controller = SidebarScanCacheController(minimumRetainedSnapshotCount: 2, maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let identity = FileIdentity(device: 1, inode: 90)
        let ownerFile = makeTestFileNode(
            id: "/cache/root/Owner/a.bin",
            name: "a.bin",
            size: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let scopedFile = makeTestFileNode(
            id: "/cache/root/Scoped/z.bin",
            name: "z.bin",
            size: 0,
            unduplicatedAllocatedSize: 100,
            fileIdentity: identity,
            linkCount: 2
        )
        let owner = makeTestDirectoryNode(id: "/cache/root/Owner", name: "Owner", children: [ownerFile])
        let scoped = makeTestDirectoryNode(id: "/cache/root/Scoped", name: "Scoped", children: [scopedFile])
        let root = makeTestDirectoryNode(id: "/cache/root", name: "root", children: [owner, scoped])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [owner, scoped],
            owner.id: [ownerFile],
            scoped.id: [scopedFile]
        ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let options = ScanOptions()
        let scopedTarget = ScanTarget(url: scoped.url)
        recorder.activeTargetID = scopedTarget.id

        controller.prepareForScanStart(target: snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(snapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            scopedTarget,
            options: options,
            currentSnapshot: snapshot,
            isTargetActive: { target in
                recorder.activeTargetID == target.id
            },
            cancelDeferredScanStart: {
                recorder.cancelDeferredScanStartCount += 1
            },
            restoreSnapshot: { snapshot, target in
                recorder.restoredSnapshots.append(snapshot)
                recorder.restoredTargets.append(target)
            },
            startScan: { target in
                recorder.startedTargets.append(target)
            }
        )

        XCTAssertFalse(shouldStartScan)
        try await waitForSidebarCacheCondition("scoped hard-link restore") {
            !recorder.restoredSnapshots.isEmpty
        }

        let restoredSnapshot = try XCTUnwrap(recorder.restoredSnapshots.first)
        XCTAssertEqual(restoredSnapshot.root.id, scoped.id)
        XCTAssertEqual(restoredSnapshot.root.allocatedSize, 100)
        XCTAssertEqual(restoredSnapshot.treeStore.node(id: scopedFile.id)?.allocatedSize, 100)
        XCTAssertTrue(recorder.startedTargets.isEmpty)
    }
}

@MainActor
private final class SidebarScanCacheRecorder {
    var activeTargetID: String?
    var cancelDeferredScanStartCount = 0
    var restoredSnapshots: [ScanSnapshot] = []
    var restoredTargets: [ScanTarget] = []
    var startedTargets: [ScanTarget] = []
}

private func makeCacheSnapshot(_ path: String, childCount: Int = 0) -> ScanSnapshot {
    let children = (0..<childCount).map { index in
        makeTestFileNode(id: "\(path)/file-\(index).txt", name: "file-\(index).txt")
    }
    let root = makeTestDirectoryNode(id: path, name: URL(filePath: path).lastPathComponent, children: children)
    let store = childCount > 0
        ? FileTreeStore(root: root, childrenByID: [root.id: children])
        : FileTreeStore(root: root)
    return makeTestSnapshot(root: root, store: store)
}

private func makeParentAndChildSnapshot() -> (snapshot: ScanSnapshot, childTarget: ScanTarget) {
    let file = makeTestFileNode(id: "/cache/root/child/file.txt", name: "file.txt")
    let child = makeTestDirectoryNode(id: "/cache/root/child", name: "child", children: [file])
    let root = makeTestDirectoryNode(id: "/cache/root", name: "root", children: [child])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [child], child.id: [file]])
    let snapshot = makeTestSnapshot(root: root, store: store)
    return (snapshot, ScanTarget(url: child.url))
}

@MainActor
private func waitForSidebarCacheCondition(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description).")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}
