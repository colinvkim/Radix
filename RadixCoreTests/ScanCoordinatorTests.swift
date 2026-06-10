import Combine
import XCTest
@testable import RadixCore

final class ScanCoordinatorTests: XCTestCase {
    @MainActor
    func testStartAndFinishScanState() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/root")
        let snapshot = makeCoordinatorSnapshot(target: target)

        coordinator.startScan(target, options: ScanOptions())

        XCTAssertEqual(coordinator.phase, .scanning)
        XCTAssertEqual(coordinator.selectedTarget, target)
        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.fileTreeStore)
        XCTAssertEqual(service.requests.map(\.target), [target])

        service.yield(.progress(makeCoordinatorMetrics(path: "/scan/root/a.txt", filesVisited: 1)), scanIndex: 0)
        try await waitUntil("initial progress") {
            coordinator.scanMetrics.currentPath == "/scan/root/a.txt"
        }

        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("finished scan") {
            coordinator.phase == .displaying
        }

        XCTAssertEqual(coordinator.snapshot?.target, target)
        XCTAssertEqual(coordinator.fileTreeStore?.root.id, snapshot.root.id)
        XCTAssertEqual(coordinator.scanMetrics.progressFraction, 1, accuracy: 0.0001)
        XCTAssertFalse(coordinator.canStopScan)
        XCTAssertTrue(coordinator.canRescan)
    }

    @MainActor
    func testRestoreCompletedSnapshotDisplaysWithoutScanRequest() {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/cached")
        let snapshot = makeCoordinatorSnapshot(target: target)

        coordinator.restoreCompletedSnapshot(snapshot)

        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(coordinator.phase, .displaying)
        XCTAssertEqual(coordinator.selectedTarget, target)
        XCTAssertEqual(coordinator.snapshot?.target, target)
        XCTAssertEqual(coordinator.fileTreeStore?.root.id, snapshot.root.id)
        XCTAssertEqual(coordinator.scanMetrics.progressFraction, 1, accuracy: 0.0001)
    }

    @MainActor
    func testStoppingScanCancelsAndIgnoresLateEvents() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/cancel")

        coordinator.startScan(target, options: ScanOptions())
        coordinator.stopScan()

        try await waitUntil("stream cancellation") {
            service.terminationCount > 0
        }

        service.yield(.finished(makeCoordinatorSnapshot(target: target)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.fileTreeStore)
        XCTAssertFalse(coordinator.canStopScan)
    }

    @MainActor
    func testStaleScanEventsCannotReplaceNewerScan() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let firstTarget = makeCoordinatorTarget("/scan/first")
        let secondTarget = makeCoordinatorTarget("/scan/second")
        let firstSnapshot = makeCoordinatorSnapshot(target: firstTarget)
        let secondSnapshot = makeCoordinatorSnapshot(target: secondTarget)

        coordinator.startScan(firstTarget, options: ScanOptions())
        coordinator.startScan(secondTarget, options: ScanOptions())

        XCTAssertEqual(service.requests.map(\.target), [firstTarget, secondTarget])

        service.yield(.finished(firstSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(coordinator.phase, .scanning)
        XCTAssertNil(coordinator.snapshot)

        service.yield(.finished(secondSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)

        try await waitUntil("second scan finished") {
            coordinator.phase == .displaying
        }

        XCTAssertEqual(coordinator.selectedTarget, secondTarget)
        XCTAssertEqual(coordinator.snapshot?.target, secondTarget)
    }

    @MainActor
    func testProgressEventsAreThrottledToLatestPendingMetrics() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(90))
        var publishedPaths: [String] = []
        let cancellable = coordinator.progress.$metrics
            .sink { metrics in
                guard !metrics.currentPath.isEmpty else { return }
                publishedPaths.append(metrics.currentPath)
            }

        coordinator.startScan(makeCoordinatorTarget("/scan/progress"), options: ScanOptions())

        service.yield(.progress(makeCoordinatorMetrics(path: "first", filesVisited: 1)), scanIndex: 0)
        service.yield(.progress(makeCoordinatorMetrics(path: "second", filesVisited: 2)), scanIndex: 0)
        service.yield(.progress(makeCoordinatorMetrics(path: "third", filesVisited: 3)), scanIndex: 0)

        try await waitUntil("first progress publish") {
            publishedPaths == ["first"]
        }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(publishedPaths, ["first"])

        try await waitUntil("throttled trailing progress publish", timeout: 1.5) {
            publishedPaths.count == 2
        }

        XCTAssertEqual(publishedPaths, ["first", "third"])
        coordinator.stopScan()
        cancellable.cancel()
    }

    @MainActor
    func testFinishedScanFlushesPendingThrottledProgress() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(250))
        let target = makeCoordinatorTarget("/scan/finish-flush")
        let snapshot = makeCoordinatorSnapshot(target: target)
        var publishedPaths: [String] = []
        let cancellable = coordinator.progress.$metrics
            .sink { metrics in
                guard !metrics.currentPath.isEmpty else { return }
                publishedPaths.append(metrics.currentPath)
            }

        coordinator.startScan(target, options: ScanOptions())
        service.yield(.progress(makeCoordinatorMetrics(path: "first", filesVisited: 1)), scanIndex: 0)

        try await waitUntil("first progress publish") {
            publishedPaths == ["first"]
        }

        service.yield(.progress(makeCoordinatorMetrics(path: "pending-final", filesVisited: 2)), scanIndex: 0)
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("finished scan with flushed progress") {
            coordinator.phase == .displaying
        }

        XCTAssertEqual(coordinator.scanMetrics.currentPath, "pending-final")
        XCTAssertEqual(coordinator.scanMetrics.progressFraction, 1, accuracy: 0.0001)
        XCTAssertTrue(publishedPaths.contains("pending-final"))
        cancellable.cancel()
    }

    @MainActor
    func testProgressMetricsDoNotPublishCoordinatorChanges() {
        let coordinator = ScanCoordinator()
        var coordinatorChangeCount = 0
        var progressChangeCount = 0

        let coordinatorCancellable = coordinator.objectWillChange.sink {
            coordinatorChangeCount += 1
        }
        let progressCancellable = coordinator.progress.$metrics
            .dropFirst()
            .sink { _ in
                progressChangeCount += 1
            }

        var metrics = ScanMetrics()
        metrics.currentPath = "/scan/progress-only"
        metrics.filesVisited = 42
        coordinator.scanMetrics = metrics

        XCTAssertEqual(progressChangeCount, 1)
        XCTAssertEqual(coordinatorChangeCount, 0)
        withExtendedLifetime((coordinatorCancellable, progressCancellable)) {}
    }

    @MainActor
    func testExpandingSummarizedNodeReplacesSubtreeAndMergesWarnings() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let summarizedNode = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let sibling = makeCoordinatorFileNode(id: "/root/readme.txt", name: "readme.txt", size: 50)
        let root = makeCoordinatorDirectoryNode(id: "/root", name: "root", children: [summarizedNode, sibling])
        let baseStore = FileTreeStore(root: root, childrenByID: [root.id: [summarizedNode, sibling]])
        let existingWarning = ScanWarning(path: "/root/cache", message: "original", category: .fileSystem)
        let baseSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget("/root"),
            root: root,
            store: baseStore,
            warnings: [existingWarning]
        )
        coordinator.replaceCurrentSnapshot(baseSnapshot)

        let expandedFile = makeCoordinatorFileNode(id: "/root/cache/item.txt", name: "item.txt", size: 125)
        let expandedRoot = makeCoordinatorDirectoryNode(id: summarizedNode.id, name: "cache", children: [expandedFile])
        let expandedStore = FileTreeStore(root: expandedRoot, childrenByID: [expandedRoot.id: [expandedFile]])
        let expansionWarning = ScanWarning(path: expandedFile.id, message: "expanded", category: .permissionDenied)
        let expandedSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(summarizedNode.id),
            root: expandedRoot,
            store: expandedStore,
            warnings: [expansionWarning]
        )

        var expansionResult: ScanExpansionResult?
        coordinator.expandSummarizedNode(
            summarizedNode,
            options: ScanOptions(includeHiddenFiles: true, autoSummarizeDirectories: false)
        ) { result in
            expansionResult = result
        }

        XCTAssertEqual(service.requests.last?.target, ScanTarget(url: summarizedNode.url))
        XCTAssertEqual(service.requests.last?.options.autoSummarizeDirectories, false)

        service.yield(.finished(expandedSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("summarized expansion") {
            expansionResult != nil
        }

        guard case .expanded(let replacementRootID) = expansionResult else {
            return XCTFail("Expected expansion to complete with replacement root ID.")
        }

        let updatedSnapshot = try XCTUnwrap(coordinator.snapshot)
        let updatedNode = try XCTUnwrap(updatedSnapshot.treeStore.node(id: summarizedNode.id))
        XCTAssertEqual(replacementRootID, summarizedNode.id)
        XCTAssertFalse(updatedNode.isAutoSummarized)
        XCTAssertEqual(updatedSnapshot.treeStore.children(of: summarizedNode.id).map(\.id), [expandedFile.id])
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [existingWarning.path, expansionWarning.path])
        XCTAssertEqual(coordinator.fileTreeStore?.root.id, root.id)
    }

    @MainActor
    func testAppModelScanLifecycleUsesInjectedCoordinatorState() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))
        let target = makeCoordinatorTarget("/app/scan")
        let snapshot = makeCoordinatorSnapshot(target: target)

        model.startScan(target)

        try await waitUntil("AppModel start scan") {
            model.scanState.phase == .scanning && service.requests.count == 1
        }

        XCTAssertEqual(service.requests.first?.target, target)
        XCTAssertEqual(model.scanState.selectedTarget, target)
        XCTAssertNil(model.scanState.snapshot)

        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("AppModel finish scan") {
            model.scanState.phase == .displaying
        }

        XCTAssertEqual(model.scanState.snapshot?.target, target)
        XCTAssertEqual(model.scanState.fileTreeStore?.root.id, snapshot.root.id)
        XCTAssertEqual(model.navigation.focusedNodeID, snapshot.root.id)
        XCTAssertEqual(model.recentTargets, [target])
    }

    @MainActor
    func testAppModelRestoresCachedSidebarTargetWithoutStartingScan() async throws {
        let service = ControlledScanService()
        let firstTarget = makeCoordinatorTarget("/app/sidebar/first")
        let secondTarget = makeCoordinatorTarget("/app/sidebar/second")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [firstTarget, secondTarget])
            )
        )
        let firstSnapshot = makeCoordinatorSnapshot(target: firstTarget)
        let secondSnapshot = makeCoordinatorSnapshot(target: secondTarget)

        model.selectSidebarTarget(id: firstTarget.id)
        try await waitUntil("first sidebar scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(firstSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("first sidebar scan finished") {
            model.scanState.snapshot?.target == firstTarget
        }

        model.selectSidebarTarget(id: secondTarget.id)
        try await waitUntil("second sidebar scan request") {
            service.requests.count == 2
        }
        service.yield(.finished(secondSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("second sidebar scan finished") {
            model.scanState.snapshot?.target == secondTarget
        }

        model.selectSidebarTarget(id: firstTarget.id)

        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(model.scanState.selectedTarget, firstTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, firstTarget)
        XCTAssertEqual(model.navigation.focusedNodeID, firstSnapshot.root.id)
        XCTAssertEqual(model.activeSidebarTargetID, firstTarget.id)
    }

    @MainActor
    func testAppModelRescanBypassesSidebarCache() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/sidebar/rescan")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )
        let snapshot = makeCoordinatorSnapshot(target: target)

        model.selectSidebarTarget(id: target.id)
        try await waitUntil("initial sidebar scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("initial sidebar scan finished") {
            model.scanState.phase == .displaying
        }

        model.rescan()

        try await waitUntil("rescan request") {
            service.requests.count == 2
        }
        XCTAssertEqual(service.requests.map(\.target), [target, target])
    }

    @MainActor
    func testAppModelScanOptionChangeMissesSidebarCache() async throws {
        let service = ControlledScanService()
        let firstTarget = makeCoordinatorTarget("/app/sidebar/options-first")
        let secondTarget = makeCoordinatorTarget("/app/sidebar/options-second")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [firstTarget, secondTarget])
            )
        )

        model.selectSidebarTarget(id: firstTarget.id)
        try await waitUntil("first options scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(makeCoordinatorSnapshot(target: firstTarget)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("first options scan finished") {
            model.scanState.snapshot?.target == firstTarget
        }

        model.selectSidebarTarget(id: secondTarget.id)
        try await waitUntil("second options scan request") {
            service.requests.count == 2
        }
        service.yield(.finished(makeCoordinatorSnapshot(target: secondTarget)), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("second options scan finished") {
            model.scanState.snapshot?.target == secondTarget
        }

        model.treatPackagesAsDirectories = true
        model.selectSidebarTarget(id: firstTarget.id)

        try await waitUntil("changed options cache miss request") {
            service.requests.count == 3
        }
        XCTAssertEqual(service.requests.last?.target, firstTarget)
        XCTAssertTrue(service.requests.last?.options.treatPackagesAsDirectories == true)
    }

    @MainActor
    func testAppModelTrashActionClearsSidebarSnapshotCache() async throws {
        let service = ControlledScanService()
        let firstTarget = makeCoordinatorTarget("/app/sidebar/stale-first")
        let secondTarget = makeCoordinatorTarget("/app/sidebar/stale-second")
        var actions = makeCoordinatorSidebarActions(targets: [firstTarget, secondTarget])
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let secondChild = makeCoordinatorFileNode(
            id: secondTarget.id + "/deleted.txt",
            name: "deleted.txt",
            size: 20
        )
        let secondRoot = makeCoordinatorDirectoryNode(
            id: secondTarget.id,
            name: "stale-second",
            children: [secondChild]
        )
        let secondStore = FileTreeStore(root: secondRoot, childrenByID: [
            secondRoot.id: [secondChild]
        ])

        model.selectSidebarTarget(id: firstTarget.id)
        try await waitUntil("stale first scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(makeCoordinatorSnapshot(target: firstTarget)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("stale first scan finished") {
            model.scanState.snapshot?.target == firstTarget
        }

        model.selectSidebarTarget(id: secondTarget.id)
        try await waitUntil("stale second scan request") {
            service.requests.count == 2
        }
        service.yield(.finished(makeCoordinatorSnapshot(target: secondTarget, root: secondRoot, store: secondStore)), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("stale second scan finished") {
            model.scanState.snapshot?.target == secondTarget
        }

        model.pendingTrashNode = secondChild
        model.confirmMovePendingNodeToTrash()
        try await waitUntil("post-trash rescan request") {
            service.requests.count == 3
        }

        model.selectSidebarTarget(id: firstTarget.id)

        try await waitUntil("first target scans after cache invalidation") {
            service.requests.count == 4
        }
        XCTAssertEqual(service.requests.last?.target, firstTarget)
    }

    @MainActor
    func testAppModelContainedSidebarTargetScopesOverOlderExactCache() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/cache-home")
        let downloadsTarget = makeCoordinatorTarget("/app/sidebar/cache-home/Downloads")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, downloadsTarget])
            )
        )
        let staleFile = makeCoordinatorFileNode(
            id: downloadsTarget.id + "/stale.txt",
            name: "stale.txt",
            size: 8
        )
        let staleDownloadsRoot = makeCoordinatorDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [staleFile]
        )
        let staleDownloadsStore = FileTreeStore(root: staleDownloadsRoot, childrenByID: [
            staleDownloadsRoot.id: [staleFile]
        ])
        let downloadFile = makeCoordinatorFileNode(
            id: downloadsTarget.id + "/file.txt",
            name: "file.txt",
            size: 20
        )
        let downloadsSnapshot = makeCoordinatorSnapshot(
            target: downloadsTarget,
            root: staleDownloadsRoot,
            store: staleDownloadsStore
        )
        let downloadsNode = makeCoordinatorDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let homeRoot = makeCoordinatorDirectoryNode(
            id: homeTarget.id,
            name: "cache-home",
            children: [downloadsNode]
        )
        let homeStore = FileTreeStore(root: homeRoot, childrenByID: [
            homeRoot.id: [downloadsNode],
            downloadsNode.id: [downloadFile]
        ])
        let homeSnapshot = makeCoordinatorSnapshot(target: homeTarget, root: homeRoot, store: homeStore)

        model.selectSidebarTarget(id: downloadsTarget.id)
        try await waitUntil("downloads exact scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(downloadsSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("downloads exact scan finished") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("home containing scan request") {
            service.requests.count == 2
        }
        service.yield(.finished(homeSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("home containing scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.selectSidebarTarget(id: downloadsTarget.id)

        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(model.scanState.selectedTarget, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, downloadsTarget.id)
        XCTAssertEqual(model.scanState.fileTreeStore?.children(of: downloadsTarget.id).map(\.id), [downloadFile.id])
        XCTAssertEqual(model.navigation.focusedNodeID, downloadsTarget.id)
        XCTAssertEqual(model.activeSidebarTargetID, downloadsTarget.id)
    }

    @MainActor
    func testAppModelContainedSidebarTargetScopesWithoutStartingScan() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/home")
        let downloadsTarget = makeCoordinatorTarget("/app/sidebar/home/Downloads")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, downloadsTarget])
            )
        )
        let downloadFile = makeCoordinatorFileNode(
            id: downloadsTarget.id + "/file.txt",
            name: "file.txt",
            size: 20
        )
        let downloadsNode = makeCoordinatorDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let homeRoot = makeCoordinatorDirectoryNode(
            id: homeTarget.id,
            name: "home",
            children: [downloadsNode]
        )
        let store = FileTreeStore(root: homeRoot, childrenByID: [
            homeRoot.id: [downloadsNode],
            downloadsNode.id: [downloadFile]
        ])
        let snapshot = makeCoordinatorSnapshot(target: homeTarget, root: homeRoot, store: store)

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("home sidebar scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("home sidebar scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.selectSidebarTarget(id: downloadsTarget.id)

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(model.scanState.selectedTarget, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, downloadsTarget.id)
        XCTAssertEqual(model.scanState.snapshot?.aggregateStats.totalAllocatedSize, downloadsNode.allocatedSize)
        XCTAssertEqual(model.navigation.focusedNodeID, downloadsTarget.id)
        XCTAssertEqual(model.activeSidebarTargetID, downloadsTarget.id)

        model.rescan()

        try await waitUntil("scoped target rescan request") {
            service.requests.count == 2
        }
        XCTAssertEqual(service.requests.last?.target, downloadsTarget)
    }

    @MainActor
    func testAppModelSiblingSidebarTargetsReuseCachedContainingScan() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/sibling-home")
        let downloadsTarget = makeCoordinatorTarget("/app/sidebar/sibling-home/Downloads")
        let documentsTarget = makeCoordinatorTarget("/app/sidebar/sibling-home/Documents")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, downloadsTarget, documentsTarget])
            )
        )
        let downloadFile = makeCoordinatorFileNode(
            id: downloadsTarget.id + "/download.txt",
            name: "download.txt",
            size: 20
        )
        let documentFile = makeCoordinatorFileNode(
            id: documentsTarget.id + "/document.txt",
            name: "document.txt",
            size: 30
        )
        let downloadsNode = makeCoordinatorDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let documentsNode = makeCoordinatorDirectoryNode(
            id: documentsTarget.id,
            name: "Documents",
            children: [documentFile]
        )
        let homeRoot = makeCoordinatorDirectoryNode(
            id: homeTarget.id,
            name: "sibling-home",
            children: [downloadsNode, documentsNode]
        )
        let store = FileTreeStore(root: homeRoot, childrenByID: [
            homeRoot.id: [downloadsNode, documentsNode],
            downloadsNode.id: [downloadFile],
            documentsNode.id: [documentFile],
        ])
        let snapshot = makeCoordinatorSnapshot(target: homeTarget, root: homeRoot, store: store)

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("sibling home scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("sibling home scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.selectSidebarTarget(id: downloadsTarget.id)
        XCTAssertEqual(model.scanState.snapshot?.target, downloadsTarget)

        model.selectSidebarTarget(id: documentsTarget.id)

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(model.scanState.selectedTarget, documentsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, documentsTarget)
        XCTAssertEqual(model.scanState.fileTreeStore?.children(of: documentsTarget.id).map(\.id), [documentFile.id])
        XCTAssertEqual(model.activeSidebarTargetID, documentsTarget.id)
    }

    @MainActor
    func testAppModelCleanupCancelsActiveScan() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))
        let target = makeCoordinatorTarget("/app/cleanup")

        model.startScan(target)

        try await waitUntil("AppModel start scan before cleanup") {
            model.scanState.phase == .scanning && service.requests.count == 1
        }

        model.cleanup()

        try await waitUntil("AppModel cleanup cancels active scan") {
            service.terminationCount == 1
        }

        XCTAssertEqual(model.scanState.phase, .idle)
        XCTAssertFalse(model.scanState.canStopScan)
    }

    @MainActor
    func testAppModelSuspendingBackgroundActivityKeepsActiveScanAndClosesQuickLook() async throws {
        let service = ControlledScanService()
        let recorder = CoordinatorLifecycleActionRecorder()
        var actions = AppSystemActions.inert
        actions.quickLook = AppQuickLookActions(
            isPreviewVisible: { true },
            isPreviewPanelKeyWindow: { false },
            present: { _ in },
            toggle: { _ in },
            updateVisiblePreview: { _ in },
            close: { recorder.quickLookCloseCount += 1 }
        )
        actions.installQuickLookKeyMonitor = { _ in
            AppEventMonitorToken {
                recorder.quickLookMonitorRemovalCount += 1
            }
        }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/background-suspend")

        model.startScan(target)

        try await waitUntil("AppModel start scan before background suspension") {
            model.scanState.phase == .scanning && service.requests.count == 1
        }

        model.suspendBackgroundActivity()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(service.terminationCount, 0)
        XCTAssertEqual(model.scanState.phase, .scanning)
        XCTAssertTrue(model.scanState.canStopScan)
        XCTAssertEqual(recorder.quickLookCloseCount, 1)
        XCTAssertEqual(recorder.quickLookMonitorRemovalCount, 0)
    }

    @MainActor
    func testAppModelSuspendingMainWindowActivityCancelsActiveScanAndClosesQuickLook() async throws {
        let service = ControlledScanService()
        let recorder = CoordinatorLifecycleActionRecorder()
        var actions = AppSystemActions.inert
        actions.quickLook = AppQuickLookActions(
            isPreviewVisible: { true },
            isPreviewPanelKeyWindow: { false },
            present: { _ in },
            toggle: { _ in },
            updateVisiblePreview: { _ in },
            close: { recorder.quickLookCloseCount += 1 }
        )
        actions.installQuickLookKeyMonitor = { _ in
            AppEventMonitorToken {
                recorder.quickLookMonitorRemovalCount += 1
            }
        }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/window-suspend")

        model.startScan(target)

        try await waitUntil("AppModel start scan before window suspension") {
            model.scanState.phase == .scanning && service.requests.count == 1
        }

        model.suspendMainWindowActivity()

        try await waitUntil("AppModel window suspension cancels active scan") {
            service.terminationCount == 1
        }

        XCTAssertEqual(model.scanState.phase, .idle)
        XCTAssertFalse(model.scanState.canStopScan)
        XCTAssertEqual(recorder.quickLookCloseCount, 1)
        XCTAssertEqual(recorder.quickLookMonitorRemovalCount, 0)
    }

    @MainActor
    func testAppModelStopCancelsDeferredScanStart() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))

        model.startScan(makeCoordinatorTarget("/app/deferred-stop"))
        model.stopScan()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.scanState.phase, .idle)
        XCTAssertFalse(model.scanState.canStopScan)
    }

    @MainActor
    func testAppModelCleanupCancelsDeferredScanStart() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))

        model.startScan(makeCoordinatorTarget("/app/deferred-cleanup"))
        model.cleanup()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.scanState.phase, .idle)
        XCTAssertFalse(model.scanState.canStopScan)
    }

    @MainActor
    func testAppModelSuspendingMainWindowActivityCancelsDeferredScanStart() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))

        model.startScan(makeCoordinatorTarget("/app/deferred-window-suspend"))
        model.suspendMainWindowActivity()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.scanState.phase, .idle)
        XCTAssertFalse(model.scanState.canStopScan)
    }

    @MainActor
    func testAppModelExpansionPreservesNavigationHistory() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))
        let summarizedNode = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let focusChild = makeCoordinatorDirectoryNode(id: "/root/docs", name: "docs", children: [])
        let root = makeCoordinatorDirectoryNode(id: "/root", name: "root", children: [summarizedNode, focusChild])
        let baseStore = FileTreeStore(root: root, childrenByID: [root.id: [summarizedNode, focusChild]])
        let baseSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget("/root"),
            root: root,
            store: baseStore
        )
        model.scanState.replaceCurrentSnapshot(baseSnapshot)
        model.navigation.reconcileAfterSnapshotApplied(baseSnapshot)
        model.navigation.setFocusedNodeID(root.id)
        model.focus(nodeID: focusChild.id)
        XCTAssertTrue(model.navigation.canNavigateBack)

        let expandedFile = makeCoordinatorFileNode(id: "/root/cache/item.txt", name: "item.txt", size: 125)
        let expandedRoot = makeCoordinatorDirectoryNode(id: summarizedNode.id, name: "cache", children: [expandedFile])
        let expandedStore = FileTreeStore(root: expandedRoot, childrenByID: [expandedRoot.id: [expandedFile]])
        let expandedSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(summarizedNode.id),
            root: expandedRoot,
            store: expandedStore
        )
        var didCompleteExpansion = false

        model.expandSummarizedNode(summarizedNode) {
            didCompleteExpansion = true
        }

        try await waitUntil("AppModel expansion request") {
            service.requests.count == 1
        }

        service.yield(.finished(expandedSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("AppModel expansion completion") {
            didCompleteExpansion
        }

        XCTAssertTrue(model.navigation.canNavigateBack)
        XCTAssertEqual(model.navigation.selectedNodeID, summarizedNode.id)
        XCTAssertEqual(model.scanState.fileTreeStore?.children(of: summarizedNode.id).map(\.id), [expandedFile.id])
    }
}

private struct ControlledScanRequest {
    let target: ScanTarget
    let options: ScanOptions
}

private final class ControlledScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ControlledScanRequest] = []
    private var storedTerminationCount = 0

    var requests: [ControlledScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var terminationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTerminationCount
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            storedRequests.append(ControlledScanRequest(target: target, options: options))
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.storedTerminationCount += 1
                self.lock.unlock()
            }
        }
    }

    func yield(_ event: ScanProgressEvent, scanIndex: Int) {
        continuation(at: scanIndex)?.yield(event)
    }

    func finish(scanIndex: Int, throwing error: Error? = nil) {
        continuation(at: scanIndex)?.finish(throwing: error)
    }

    private func continuation(at index: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }
}

@MainActor
private func makeCoordinatorAppDependencies(
    scanService: any ScanEventStreaming,
    systemActions: AppSystemActions = .inert
) -> AppDependencies {
    AppDependencies(
        preferences: CoordinatorAppPreferencesStore(),
        recentTargets: RecentTargetStore(
            persistence: CoordinatorRecentTargetPersistence(),
            isAvailable: { _ in true }
        ),
        systemActions: systemActions,
        scanService: scanService
    )
}

@MainActor
private final class CoordinatorLifecycleActionRecorder {
    var quickLookCloseCount = 0
    var quickLookMonitorRemovalCount = 0
}

private final class CoordinatorAppPreferencesStore: AppPreferencesPersisting {
    var preferences: AppPreferences

    init(preferences: AppPreferences = .defaults) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppPreferences {
        preferences
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        self.preferences.scan = preferences
    }

    func markOnboardingComplete() {
        preferences.didCompleteOnboarding = true
    }

    func markOnboardingIncomplete() {
        preferences.didCompleteOnboarding = false
    }
}

private final class CoordinatorRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget] = []

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
    }

    func clearRecentTargets() {
        targets = []
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("Timed out waiting for \(description).")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

private func makeCoordinatorTarget(_ path: String) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
}

@MainActor
private func makeCoordinatorSidebarActions(targets: [ScanTarget]) -> AppSystemActions {
    var actions = AppSystemActions.inert
    actions.defaultTargets = { targets }
    actions.preferredSmartTargetIDs = { targets.map(\.id) }
    return actions
}

private func makeCoordinatorMetrics(path: String, filesVisited: Int) -> ScanMetrics {
    var metrics = ScanMetrics()
    metrics.currentPath = path
    metrics.filesVisited = filesVisited
    metrics.discoveredItems = max(filesVisited, 1)
    metrics.completedItems = filesVisited
    metrics.bytesDiscovered = Int64(filesVisited)
    metrics.progressFraction = min(Double(filesVisited) / 10, 0.95)
    return metrics
}

private func makeCoordinatorSnapshot(target: ScanTarget) -> ScanSnapshot {
    let file = makeCoordinatorFileNode(id: target.url.appendingPathComponent("file.txt").path, name: "file.txt", size: 20)
    let root = makeCoordinatorDirectoryNode(id: target.id, name: target.displayName, children: [file])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    return makeCoordinatorSnapshot(target: target, root: root, store: store)
}

private func makeCoordinatorSnapshot(
    target: ScanTarget,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = []
) -> ScanSnapshot {
    ScanSnapshot(
        target: target,
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
}

private func makeCoordinatorFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeCoordinatorDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord]
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        isPackage: false,
        isAccessible: true
    )
}

private func makeCoordinatorSummarizedDirectoryNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 12,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: true
    )
}
