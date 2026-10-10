import Foundation
import Testing

@testable import RadixCore

@MainActor
struct SidebarScanCacheControllerTests {
    @Test
    func testCompletedScanCacheTrimsLeastRecentlyUsedSnapshotsToBudget() {
        let cache = CompletedScanCache(maxTotalNodeCount: 2)
        let first = makeCacheSnapshot("/cache/first")
        let second = makeCacheSnapshot("/cache/second")
        let third = makeCacheSnapshot("/cache/third")
        let options = ScanOptions()
        let firstKey = ScanCacheKey(target: first.target, options: options)
        let secondKey = ScanCacheKey(target: second.target, options: options)
        let thirdKey = ScanCacheKey(target: third.target, options: options)

        cache.store(first, for: firstKey)
        cache.store(second, for: secondKey)
        #expect(cache.snapshot(for: firstKey) != nil)

        cache.store(third, for: thirdKey)

        #expect(cache.snapshot(for: firstKey) != nil)
        #expect(cache.snapshot(for: secondKey) == nil)
        #expect(cache.snapshot(for: thirdKey) != nil)
    }

    @Test
    func testCompletedScanCacheReplacingSnapshotKeepsNodeBudgetAccurate() {
        let cache = CompletedScanCache(maxTotalNodeCount: 3)
        let replaced = makeCacheSnapshot("/cache/replaced")
        let second = makeCacheSnapshot("/cache/second", childCount: 1)
        let options = ScanOptions()
        let replacedKey = ScanCacheKey(target: replaced.target, options: options)
        let secondKey = ScanCacheKey(target: second.target, options: options)

        cache.store(replaced, for: replacedKey)
        cache.store(replaced, for: replacedKey)
        cache.store(second, for: secondKey)

        #expect(cache.snapshot(for: replacedKey) != nil)
        #expect(cache.snapshot(for: secondKey) != nil)
    }

    @Test
    func testCompletedScanCacheChargesFullBackingTreeForScope() throws {
        let tree = makeParentAndChildSnapshot()
        let scope = try #require(tree.snapshot.scoped(to: tree.childTarget))
        let cache = CompletedScanCache(maxTotalNodeCount: 3)
        let other = makeCacheSnapshot("/cache/other")
        let options = ScanOptions()
        let scopeKey = ScanCacheKey(target: scope.target, options: options)
        let otherKey = ScanCacheKey(target: other.target, options: options)
        #expect(scope.treeStore.nodeCount == 2)
        #expect(scope.treeStore.backingNodeCapacity == 3)

        cache.store(scope, for: scopeKey)
        cache.store(other, for: otherKey)

        #expect(cache.snapshot(for: scopeKey) == nil)
        #expect(cache.snapshot(for: otherKey) != nil)
    }

    @Test
    func testCompletedScanCacheKeepsParentInsteadOfDuplicateScopes() throws {
        let tree = makeParentAndChildSnapshot()
        let scope = try #require(tree.snapshot.scoped(to: tree.childTarget))
        let cache = CompletedScanCache(maxTotalNodeCount: 4)
        let other = makeCacheSnapshot("/cache/other")
        let options = ScanOptions()
        let parentKey = ScanCacheKey(target: tree.snapshot.target, options: options)
        let scopeKey = ScanCacheKey(target: scope.target, options: options)
        let otherKey = ScanCacheKey(target: other.target, options: options)

        cache.store(tree.snapshot, for: parentKey)
        cache.store(other, for: otherKey)
        cache.store(scope, for: scopeKey)

        #expect(cache.snapshot(for: parentKey) != nil)
        #expect(cache.snapshot(for: otherKey) != nil)
        #expect(cache.snapshot(for: scopeKey) == nil)
        #expect(cache.mostRecentSnapshot(matchingOrContaining: scope.target, options: options)?.id == tree.snapshot.id)
    }

    @Test
    func testCompletedScanCacheReplacesScopeWithParentWithoutDoubleCharging() async throws {
        let tree = makeParentAndChildSnapshot()
        let scope = try #require(tree.snapshot.scoped(to: tree.childTarget))
        let cache = CompletedScanCache(maxTotalNodeCount: 4)
        let other = makeCacheSnapshot("/cache/other")
        let options = ScanOptions()
        let parentKey = ScanCacheKey(target: tree.snapshot.target, options: options)
        let scopeKey = ScanCacheKey(target: scope.target, options: options)
        let otherKey = ScanCacheKey(target: other.target, options: options)

        cache.store(scope, for: scopeKey)
        cache.store(tree.snapshot, for: parentKey)
        await cache.waitForPendingReleases()
        cache.store(other, for: otherKey)

        #expect(cache.snapshot(for: scopeKey) == nil)
        #expect(cache.snapshot(for: parentKey) != nil)
        #expect(cache.snapshot(for: otherKey) != nil)
    }

    @Test
    func testCompletedScanCacheRecountsReplacementWithDifferentBackingTree() async {
        let cache = CompletedScanCache(maxTotalNodeCount: 3)
        let large = makeCacheSnapshot("/cache/replaced", childCount: 4)
        let small = makeCacheSnapshot("/cache/replaced")
        let other = makeCacheSnapshot("/cache/other", childCount: 1)
        let options = ScanOptions()
        let replacedKey = ScanCacheKey(target: large.target, options: options)
        let otherKey = ScanCacheKey(target: other.target, options: options)

        cache.store(large, for: replacedKey)
        cache.store(small, for: replacedKey)
        await cache.waitForPendingReleases()
        cache.store(other, for: otherKey)

        #expect(cache.snapshot(for: replacedKey)?.id == small.id)
        #expect(cache.snapshot(for: otherKey) != nil)
    }

    @Test
    func testCompletedScanCacheStopsAdmissionWhileDiscardedOwnershipIsPending() async throws {
        let first = makeCacheSnapshot("/cache/first")
        let tree = makeParentAndChildSnapshot()
        let second = tree.snapshot
        let scope = try #require(second.scoped(to: tree.childTarget))
        let queue = DispatchQueue(label: "cache-release-test")
        queue.suspend()
        let cache = CompletedScanCache(maxTotalNodeCount: 1, releaseQueue: queue)
        let options = ScanOptions()
        let firstKey = ScanCacheKey(target: first.target, options: options)
        let secondKey = ScanCacheKey(target: second.target, options: options)

        cache.store(first, for: firstKey)
        cache.store(second, for: secondKey)
        #expect(cache.snapshot(for: firstKey) == nil)
        #expect(cache.snapshot(for: secondKey) != nil)
        await Task.yield()
        cache.store(scope, for: ScanCacheKey(target: scope.target, options: options))
        #expect(cache.snapshot(for: secondKey) != nil)
        // Cleanup cannot run, but the actor remains available. New scans cannot
        // add to retained ownership, including replacement and clear cycles.
        for _ in 0..<10 {
            cache.store(first, for: firstKey)
            #expect(cache.snapshot(for: firstKey) == nil)
            cache.store(second, for: secondKey)
            #expect(cache.snapshot(for: secondKey) == nil)
            cache.removeAll()
        }
        #expect(cache.snapshot(for: firstKey) == nil)
        #expect(cache.snapshot(for: secondKey) == nil)
        queue.resume()
        await cache.waitForPendingReleases()

        cache.store(first, for: firstKey)
        #expect(cache.snapshot(for: firstKey) != nil)
    }

    @Test
    func testCompletedScanCacheFindsRecentMatchingOrContainingSnapshotWithMatchingOptions() {
        let cache = CompletedScanCache(maxTotalNodeCount: 100)
        let child = makeTestDirectoryNode(id: "/cache/root/child", name: "child", children: [])
        let root = makeTestDirectoryNode(id: "/cache/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let options = ScanOptions(includeHiddenFiles: true)

        cache.store(snapshot, for: ScanCacheKey(target: snapshot.target, options: options))

        #expect(
            cache.mostRecentSnapshot(matchingOrContaining: ScanTarget(url: child.url), options: options)?.id
                == snapshot.id)
        #expect(cache.mostRecentSnapshot(matchingOrContaining: snapshot.target, options: options)?.id == snapshot.id)
        #expect(
            cache.mostRecentSnapshot(
                matchingOrContaining: ScanTarget(url: child.url),
                options: ScanOptions()
            ) == nil)
    }

    @Test
    func testControllerRestoresExactCachedSidebarTarget() {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
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

        #expect(!(shouldStartScan))
        #expect(recorder.cancelDeferredScanStartCount == 1)
        #expect(recorder.restoredSnapshots.map(\.id) == [snapshot.id])
        #expect(recorder.restoredTargets == [snapshot.target])
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerRetainsParentAfterScanMissesAdmissionDuringCleanup() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 1)
        let recorder = SidebarScanCacheRecorder()
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions()
        // These synchronous completions keep the release task pending until
        // this actor yields. The third scan therefore misses cache admission.
        for snapshot in [makeCacheSnapshot("/cache/first"), makeCacheSnapshot("/cache/second"), tree.snapshot] {
            controller.prepareForScanStart(target: snapshot.target, options: options)
            controller.handleCompletedScanSnapshot(snapshot)
        }
        let condition1 =
            (!(controller.applyCachedOrContainedSidebarTarget(
                tree.snapshot.target,
                options: options,
                currentSnapshot: tree.snapshot,
                isTargetActive: { _ in true },
                cancelDeferredScanStart: {},
                restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
                startScan: { recorder.startedTargets.append($0) }
            )))
        #expect(condition1)
        #expect(recorder.restoredSnapshots.isEmpty)
        let shouldScanChild = controller.applyCachedOrContainedSidebarTarget(
            tree.childTarget,
            options: options,
            currentSnapshot: tree.snapshot,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in
                controller.handleCompletedScanSnapshot(snapshot)
                recorder.restoredSnapshots.append(snapshot)
            },
            startScan: { recorder.startedTargets.append($0) }
        )
        #expect(!(shouldScanChild))
        try await waitUntil("child scope after cache admission resumes") {
            !recorder.restoredSnapshots.isEmpty
        }
        let childSnapshot = try #require(recorder.restoredSnapshots.first)
        let shouldScanParent = controller.applyCachedOrContainedSidebarTarget(
            tree.snapshot.target,
            options: options,
            currentSnapshot: childSnapshot,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
            startScan: { recorder.startedTargets.append($0) }
        )
        #expect(!(shouldScanParent))
        #expect(recorder.restoredSnapshots.last?.id == tree.snapshot.id)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerReplacesDisplayedCachedSnapshotAfterRefresh() throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let cachedSnapshot = makeCacheSnapshot("/cache/refreshed", childCount: 1)
        let refreshedFile = makeTestFileNode(
            id: cachedSnapshot.target.id + "/refreshed.txt",
            name: "refreshed.txt"
        )
        let refreshedRoot = makeTestDirectoryNode(
            id: cachedSnapshot.root.id,
            name: cachedSnapshot.root.name,
            children: [refreshedFile]
        )
        let refreshedStore = FileTreeStore(
            root: refreshedRoot,
            childrenByID: [refreshedRoot.id: [refreshedFile]]
        )
        let refreshedSnapshot = ScanSnapshot(
            id: cachedSnapshot.id,
            target: cachedSnapshot.target,
            treeStore: refreshedStore,
            startedAt: cachedSnapshot.startedAt,
            finishedAt: .now,
            scanWarnings: [],
            isComplete: true,
            scanOptions: cachedSnapshot.scanOptions
        )
        let options = ScanOptions()

        controller.prepareForScanStart(target: cachedSnapshot.target, options: options)
        controller.handleCompletedScanSnapshot(cachedSnapshot)
        controller.handleCompletedScanSnapshot(refreshedSnapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            cachedSnapshot.target,
            options: options,
            currentSnapshot: nil,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, target in
                recorder.restoredSnapshots.append(snapshot)
                recorder.restoredTargets.append(target)
            },
            startScan: { target in
                recorder.startedTargets.append(target)
            }
        )

        #expect(!(shouldStartScan))
        let restoredSnapshot = try #require(recorder.restoredSnapshots.first)
        #expect(restoredSnapshot.id == cachedSnapshot.id)
        #expect(restoredSnapshot.treeStore.children(of: refreshedRoot.id).map(\.id) == [refreshedFile.id])
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerKeepsCurrentCachedParentWhenChildScopeIsPending() async {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions(includeHiddenFiles: true)

        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)

        func apply(_ target: ScanTarget) -> Bool {
            controller.applyCachedOrContainedSidebarTarget(
                target,
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
        }

        recorder.activeTargetID = tree.childTarget.id
        #expect(!(apply(tree.childTarget)))

        recorder.activeTargetID = tree.snapshot.target.id
        #expect(!(apply(tree.snapshot.target)))

        await Task.yield()
        await Task.yield()

        #expect(recorder.cancelDeferredScanStartCount == 2)
        #expect(recorder.restoredSnapshots.isEmpty)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerPrefersNewerContainingSnapshotAfterTargetDetour() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let recorder = SidebarScanCacheRecorder()
        let tree = makeParentAndChildSnapshot()
        let staleFile = makeTestFileNode(
            id: tree.childTarget.id + "/stale.txt",
            name: "stale.txt"
        )
        let staleRoot = makeTestDirectoryNode(
            id: tree.childTarget.id,
            name: tree.childTarget.displayName,
            children: [staleFile]
        )
        let staleStore = FileTreeStore(
            root: staleRoot,
            childrenByID: [staleRoot.id: [staleFile]]
        )
        let staleSnapshot = makeTestSnapshot(
            target: tree.childTarget,
            root: staleRoot,
            store: staleStore
        )
        let unrelatedSnapshot = makeCacheSnapshot("/cache/unrelated")
        let options = ScanOptions(includeHiddenFiles: true)
        recorder.activeTargetID = tree.childTarget.id

        controller.prepareForScanStart(target: tree.childTarget, options: options)
        controller.handleCompletedScanSnapshot(staleSnapshot)
        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)

        let shouldStartScan = controller.applyCachedOrContainedSidebarTarget(
            tree.childTarget,
            options: options,
            currentSnapshot: unrelatedSnapshot,
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

        #expect(!(shouldStartScan))
        try await waitUntil("newer containing snapshot restore") {
            !recorder.restoredSnapshots.isEmpty
        }

        let restoredSnapshot = try #require(recorder.restoredSnapshots.first)
        #expect(
            restoredSnapshot.treeStore.children(of: tree.childTarget.id).map(\.id)
                == tree.snapshot.treeStore.children(of: tree.childTarget.id).map(\.id))
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerScopesCurrentSidebarSnapshotWhenDisplayedOptionsMatch() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
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

        #expect(!(shouldStartScan))
        try await waitUntil("scoped snapshot restore") {
            !recorder.restoredSnapshots.isEmpty
        }

        #expect(recorder.cancelDeferredScanStartCount == 1)
        #expect(recorder.restoredTargets == [tree.childTarget])
        #expect(recorder.restoredSnapshots.first?.target == tree.childTarget)
        #expect(recorder.restoredSnapshots.first?.root.id == tree.childTarget.id)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerDoesNotScopeCurrentSnapshotWhenDisplayedOptionsDiffer() {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
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

        #expect(shouldStartScan)
        #expect(recorder.cancelDeferredScanStartCount == 0)
        #expect(recorder.restoredSnapshots.isEmpty)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testControllerScopedRestoreRebalancesHardLinksInsideTarget() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [owner, scoped],
                owner.id: [ownerFile],
                scoped.id: [scopedFile],
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

        #expect(!(shouldStartScan))
        try await waitUntil("scoped hard-link restore") {
            !recorder.restoredSnapshots.isEmpty
        }

        let restoredSnapshot = try #require(recorder.restoredSnapshots.first)
        #expect(restoredSnapshot.root.id == scoped.id)
        #expect(restoredSnapshot.root.allocatedSize == 100)
        #expect(restoredSnapshot.treeStore.nodeCount == 2)
        #expect(restoredSnapshot.treeStore.nodeIndex(id: scoped.id)?.rawValue != 0)
        #expect(restoredSnapshot.treeStore.node(id: scopedFile.id)?.allocatedSize == 100)
        #expect(recorder.startedTargets.isEmpty)
    }
    @Test
    func testTransferRefreshUsesRetainedParentAndUpdatesCachedNavigation() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions(exclusionPatterns: ["child/ignored"], exclusionRootPath: nil)
        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)
        let scope = try await restoreCacheScope(tree.childTarget, from: tree.snapshot, options: options, controller: controller)

        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: scope)
        let request = try #require(controller.fileTransferReconciliationRequest(for: scope))
        #expect(request.snapshot.id == tree.snapshot.id)
        #expect(request.options == options)
        #expect(request.forcedDirectoryPaths == [tree.childTarget.url.path])
        let refreshed = try #require(tree.snapshot.removingNode(id: "/cache/root/child/file.txt"))
        #expect(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed))
        #expect(controller.fileTransferReconciliationRequest(for: scope) == nil)

        let recorder = SidebarScanCacheRecorder()
        let requiresScan = controller.applyCachedOrContainedSidebarTarget(
            tree.snapshot.target,
            options: options,
            currentSnapshot: scope,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
            startScan: { target in recorder.startedTargets.append(target) }
        )
        #expect(!requiresScan)
        let restored = try #require(recorder.restoredSnapshots.first)
        #expect(restored.treeStore.node(id: "/cache/root/child/file.txt") == nil)
        #expect(restored.treeStore.contentID == refreshed.treeStore.contentID)
        #expect(recorder.startedTargets.isEmpty)
        #expect(controller.fileTransferReconciliationRequest(for: restored) != nil)
        #expect(controller.markForValidationOnActivation(currentSnapshot: restored))
        #expect(controller.fileTransferReconciliationRequest(for: restored) != nil)
    }

    @Test
    func testTransferDuringExpansionKeepsOriginalParentBaseline() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions()
        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)
        let scope = try await restoreCacheScope(tree.childTarget, from: tree.snapshot, options: options, controller: controller)
        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: scope)
        let expanded = try #require(scope.removingNode(id: "/cache/root/child/file.txt"))
        #expect(expanded.treeStore.backingStorageID != scope.treeStore.backingStorageID)
        controller.handleCompletedScanSnapshot(expanded)

        let request = try #require(controller.fileTransferReconciliationRequest(for: expanded))
        #expect(request.snapshot.id == tree.snapshot.id)
        let refreshed = try #require(tree.snapshot.removingNode(id: "/cache/root/child/file.txt"))
        #expect(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed))
        #expect(controller.fileTransferReconciliationRequest(for: expanded) == nil)
        // A child with independent expansion buffers must not outlive its
        // reconciled parent as a second stale cached view.
        let restored = try await restoreCacheScope(tree.childTarget, from: nil, options: options, controller: controller)
        #expect(restored.treeStore.backingStorageID == refreshed.treeStore.backingStorageID)
    }

    @Test
    func testNewTransferGenerationRejectsAnOlderRefresh() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let tree = makeParentAndChildSnapshot()
        controller.prepareForScanStart(target: tree.snapshot.target, options: ScanOptions())
        controller.handleCompletedScanSnapshot(tree.snapshot)
        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: tree.snapshot)
        let first = try #require(controller.fileTransferReconciliationRequest(for: tree.snapshot))
        controller.markExternalFileTransfer(sourceDirectoryPaths: ["/cache/root"], currentSnapshot: tree.snapshot)
        let second = try #require(controller.fileTransferReconciliationRequest(for: tree.snapshot))

        #expect(second.generation > first.generation)
        #expect(!(await controller.completeFileTransferReconciliation(first, refreshedSnapshot: tree.snapshot)))
        #expect(controller.fileTransferReconciliationRequest(for: tree.snapshot)?.generation == second.generation)
        #expect(Set(second.forcedDirectoryPaths) == ["/cache/root", tree.childTarget.url.path])
    }

    @Test
    func testReplacedBaselineRejectsRefreshEvenWhenSnapshotIDIsUnchanged() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let tree = makeParentAndChildSnapshot()
        controller.prepareForScanStart(target: tree.snapshot.target, options: ScanOptions())
        controller.handleCompletedScanSnapshot(tree.snapshot)
        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: tree.snapshot)
        let request = try #require(controller.fileTransferReconciliationRequest(for: tree.snapshot))
        let changed = try #require(tree.snapshot.removingNode(id: "/cache/root/child/file.txt"))
        #expect(changed.id == tree.snapshot.id)
        controller.handleCompletedScanSnapshot(changed)

        #expect(!(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: tree.snapshot)))
        #expect(controller.fileTransferReconciliationRequest(for: changed)?.snapshot.treeStore.contentID == changed.treeStore.contentID)
    }

    @Test
    func testTransferLeavesIndependentCachesRequiringValidation() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let firstTree = makeParentAndChildSnapshot()
        let first = makeTestSnapshot(root: firstTree.snapshot.root, store: firstTree.snapshot.treeStore, scanOptions: ScanOptions())
        let secondTree = makeCacheSnapshot("/cache/independent")
        let second = makeTestSnapshot(root: secondTree.root, store: secondTree.treeStore, scanOptions: ScanOptions())
        for snapshot in [first, second] {
            controller.prepareForScanStart(target: snapshot.target, options: ScanOptions())
            controller.handleCompletedScanSnapshot(snapshot)
        }
        // The drag ended after navigation to the unrelated scan.
        controller.markExternalFileTransfer(sourceDirectoryPaths: ["/cache/root/child"], currentSnapshot: first)
        let firstRequest = try #require(controller.fileTransferReconciliationRequest(for: first))
        let independentRequest = try #require(controller.fileTransferReconciliationRequest(for: second))
        #expect(independentRequest.forcedDirectoryPaths.isEmpty)
        #expect(await controller.completeFileTransferReconciliation(firstRequest, refreshedSnapshot: first))
        #expect(controller.fileTransferReconciliationRequest(for: second)?.generation == independentRequest.generation)
    }

    @Test
    func testDragOriginKeepsItsOptionsAfterDisplayedOptionsChange() throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let originTree = makeCacheSnapshot("/cache/root")
        let originOptions = ScanOptions(includeHiddenFiles: true)
        let origin = makeTestSnapshot(root: originTree.root, store: originTree.treeStore, scanOptions: originOptions)
        let displayedTree = makeCacheSnapshot("/cache/root", childCount: 1)
        let displayedOptions = ScanOptions(includeHiddenFiles: false)
        let displayed = makeTestSnapshot(root: displayedTree.root, store: displayedTree.treeStore, scanOptions: displayedOptions)
        for snapshot in [origin, displayed] {
            controller.prepareForScanStart(target: snapshot.target, options: try #require(snapshot.scanOptions))
            controller.handleCompletedScanSnapshot(snapshot)
        }
        controller.markExternalFileTransfer(sourceDirectoryPaths: ["/cache/root"], currentSnapshot: origin)

        let request = try #require(controller.fileTransferReconciliationRequest(for: origin))
        #expect(request.snapshot.treeStore.contentID == origin.treeStore.contentID)
        #expect(request.options == originOptions)
        #expect(controller.fileTransferReconciliationRequest(for: displayed)?.options == displayedOptions)
    }

    @Test
    func testTransferCommitWaitsForPendingCacheReleaseBeforeAdmission() async throws {
        let queue = DispatchQueue(label: "transfer-cache-release-test")
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100, releaseQueue: queue)
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions()
        let parent = makeTestSnapshot(root: tree.snapshot.root, store: tree.snapshot.treeStore, scanOptions: options)
        let other = makeCacheSnapshot("/cache/other")
        for snapshot in [parent, other] {
            controller.prepareForScanStart(target: snapshot.target, options: options)
            controller.handleCompletedScanSnapshot(snapshot)
        }
        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: parent)
        let request = try #require(controller.fileTransferReconciliationRequest(for: parent))
        let refreshed = try #require(parent.removingNode(id: "/cache/root/child/file.txt"))
        queue.suspend()
        controller.prepareForScanStart(target: other.target, options: options)
        controller.handleCompletedScanSnapshot(makeCacheSnapshot("/cache/other", childCount: 1))
        let recorder = SidebarScanCacheRecorder()
        let commit = Task { @MainActor in
            recorder.transferCommitResult = await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed)
        }
        await Task.yield()
        #expect(recorder.transferCommitResult == nil)
        #expect(controller.fileTransferReconciliationRequest(for: parent) != nil)
        commit.cancel()
        queue.resume()
        await commit.value
        #expect(recorder.transferCommitResult == false)
        #expect(controller.fileTransferReconciliationRequest(for: parent) != nil)
        #expect(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed))
        let requiresScan = controller.applyCachedOrContainedSidebarTarget(
            parent.target,
            options: options,
            currentSnapshot: nil,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
            startScan: { target in recorder.startedTargets.append(target) }
        )
        #expect(!requiresScan)
        #expect(recorder.restoredSnapshots.first?.treeStore.contentID == refreshed.treeStore.contentID)
    }

    @Test
    func testSuspendedScopeRestoreUsesReconciledParent() async throws {
        let transform = PausingCacheScopeTransform()
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100, snapshotTransformService: transform)
        let tree = makeParentAndChildSnapshot()
        let options = ScanOptions()
        controller.prepareForScanStart(target: tree.snapshot.target, options: options)
        controller.handleCompletedScanSnapshot(tree.snapshot)
        let recorder = SidebarScanCacheRecorder()
        let requiresScan = controller.applyCachedOrContainedSidebarTarget(
            tree.childTarget,
            options: options,
            currentSnapshot: tree.snapshot,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
            startScan: { target in recorder.startedTargets.append(target) }
        )
        #expect(!requiresScan)
        try await waitUntil("cache scope transform paused") { await transform.isPaused }
        controller.markExternalFileTransfer(sourceDirectoryPaths: [tree.childTarget.url.path], currentSnapshot: tree.snapshot)
        let request = try #require(controller.fileTransferReconciliationRequest(for: tree.snapshot))
        let refreshed = try #require(tree.snapshot.removingNode(id: "/cache/root/child/file.txt"))
        #expect(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed))
        await transform.resume()
        try await waitUntil("scope restore after parent reconciliation") { !recorder.restoredSnapshots.isEmpty }
        let restored = try #require(recorder.restoredSnapshots.first)
        #expect(restored.treeStore.node(id: "/cache/root/child/file.txt") == nil)
        #expect(restored.treeStore.backingStorageID == refreshed.treeStore.backingStorageID)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testPendingGrandchildScopeUsesCanonicalParentAfterChildCacheIsRemoved() async throws {
        let firstFile = makeTestFileNode(id: "/cache/root/child/grandchild/first.txt", name: "first.txt")
        let movedFile = makeTestFileNode(id: "/cache/root/child/grandchild/moved.txt", name: "moved.txt")
        let grandchild = makeTestDirectoryNode(id: "/cache/root/child/grandchild", name: "grandchild", children: [firstFile, movedFile])
        let child = makeTestDirectoryNode(id: "/cache/root/child", name: "child", children: [grandchild])
        let root = makeTestDirectoryNode(id: "/cache/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child], child.id: [grandchild], grandchild.id: [firstFile, movedFile]])
        let options = ScanOptions()
        let parent = makeTestSnapshot(root: root, store: store, scanOptions: options)
        let grandchildTarget = ScanTarget(url: grandchild.url)
        let transform = PausingCacheScopeTransform(pausedTargetID: grandchildTarget.id)
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100, snapshotTransformService: transform)
        controller.prepareForScanStart(target: parent.target, options: options)
        controller.handleCompletedScanSnapshot(parent)
        let scopedChild = try await restoreCacheScope(ScanTarget(url: child.url), from: parent, options: options, controller: controller)
        let expandedChild = try #require(scopedChild.removingNode(id: firstFile.id))
        controller.handleCompletedScanSnapshot(expandedChild)
        let recorder = SidebarScanCacheRecorder()
        let requiresScan = controller.applyCachedOrContainedSidebarTarget(
            grandchildTarget,
            options: options,
            currentSnapshot: expandedChild,
            isTargetActive: { _ in true },
            cancelDeferredScanStart: {},
            restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
            startScan: { target in recorder.startedTargets.append(target) }
        )
        #expect(!requiresScan)
        try await waitUntil("nested cache scope transform paused") { await transform.isPaused }
        controller.markExternalFileTransfer(sourceDirectoryPaths: [grandchild.id], currentSnapshot: expandedChild)
        let request = try #require(controller.fileTransferReconciliationRequest(for: expandedChild))
        #expect(request.snapshot.target == parent.target)
        let refreshed = try #require(parent.removingNode(id: movedFile.id))
        #expect(await controller.completeFileTransferReconciliation(request, refreshedSnapshot: refreshed))
        await transform.resume()
        try await waitUntil("nested scope restore after canonical parent refresh") { !recorder.restoredSnapshots.isEmpty }
        let restored = try #require(recorder.restoredSnapshots.first)
        #expect(restored.treeStore.node(id: movedFile.id) == nil)
        #expect(restored.treeStore.node(id: firstFile.id) != nil)
        #expect(restored.treeStore.backingStorageID == refreshed.treeStore.backingStorageID)
        #expect(recorder.startedTargets.isEmpty)
    }

    @Test
    func testOrdinaryScopedNavigationDoesNotScheduleTransferValidation() async throws {
        let controller = SidebarScanCacheController(maxTotalNodeCount: 100)
        let tree = makeParentAndChildSnapshot()
        controller.prepareForScanStart(target: tree.snapshot.target, options: ScanOptions())
        controller.handleCompletedScanSnapshot(tree.snapshot)
        let scope = try await restoreCacheScope(tree.childTarget, from: tree.snapshot, options: ScanOptions(), controller: controller)

        #expect(controller.fileTransferReconciliationRequest(for: scope) == nil)
        #expect(!controller.markForValidationOnActivation(currentSnapshot: scope))
    }
}

@MainActor
private func restoreCacheScope(
    _ target: ScanTarget,
    from snapshot: ScanSnapshot?,
    options: ScanOptions,
    controller: SidebarScanCacheController
) async throws -> ScanSnapshot {
    let recorder = SidebarScanCacheRecorder()
    let requiresScan = controller.applyCachedOrContainedSidebarTarget(
        target,
        options: options,
        currentSnapshot: snapshot,
        isTargetActive: { _ in true },
        cancelDeferredScanStart: {},
        restoreSnapshot: { snapshot, _ in recorder.restoredSnapshots.append(snapshot) },
        startScan: { target in recorder.startedTargets.append(target) }
    )
    #expect(!requiresScan)
    try await waitUntil("cached scope restore") { !recorder.restoredSnapshots.isEmpty }
    return try #require(recorder.restoredSnapshots.first)
}

@MainActor
private final class SidebarScanCacheRecorder {
    var activeTargetID: String?
    var cancelDeferredScanStartCount = 0
    var restoredSnapshots: [ScanSnapshot] = []
    var restoredTargets: [ScanTarget] = []
    var startedTargets: [ScanTarget] = []
    var transferCommitResult: Bool?
}

private func makeCacheSnapshot(_ path: String, childCount: Int = 0) -> ScanSnapshot {
    let children = (0..<childCount).map { index in
        makeTestFileNode(id: "\(path)/file-\(index).txt", name: "file-\(index).txt")
    }
    let root = makeTestDirectoryNode(id: path, name: URL(filePath: path).lastPathComponent, children: children)
    let store =
        childCount > 0
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

private actor PausingCacheScopeTransform: ScanSnapshotTransforming {
    private let service = ScanSnapshotTransformService()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isPaused = false
    private let pausedTargetID: String?

    init(pausedTargetID: String? = nil) {
        self.pausedTargetID = pausedTargetID
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func scopedSnapshot(_ snapshot: ScanSnapshot, to target: ScanTarget) async throws -> ScanSnapshot? {
        if !isPaused, pausedTargetID == nil || pausedTargetID == target.id {
            isPaused = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await service.scopedSnapshot(snapshot, to: target)
    }

    func replacingNode(in snapshot: ScanSnapshot, id targetID: String, with replacement: FileTreeStore, additionalWarnings: [ScanWarning]) async throws -> ScanSnapshot? {
        try await service.replacingNode(in: snapshot, id: targetID, with: replacement, additionalWarnings: additionalWarnings)
    }

    func replacingSubtrees(in snapshot: ScanSnapshot, replacements: [String: FileTreeStore], additionalWarnings: [ScanWarning]) async throws -> ScanSnapshot? {
        try await service.replacingSubtrees(in: snapshot, replacements: replacements, additionalWarnings: additionalWarnings)
    }

    func replacingNodeForSubtreeRescan(in snapshot: ScanSnapshot, id targetID: String, with replacement: FileTreeStore, additionalWarnings: [ScanWarning], volumeCapacity: VolumeCapacitySnapshot?, reconcilesVolumeCapacity: Bool) async throws -> ScanSnapshot? {
        try await service.replacingNodeForSubtreeRescan(in: snapshot, id: targetID, with: replacement, additionalWarnings: additionalWarnings, volumeCapacity: volumeCapacity, reconcilesVolumeCapacity: reconcilesVolumeCapacity)
    }

    func removingNodes(in snapshot: ScanSnapshot, ids targetIDs: [String]) async throws -> ScanSnapshot? {
        try await service.removingNodes(in: snapshot, ids: targetIDs)
    }
}
