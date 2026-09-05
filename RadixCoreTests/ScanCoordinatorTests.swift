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
    func testExecutionModeUpdatesProgressAndResetsMetricsOnFallback() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(
            scanService: service,
            progressThrottleDuration: .zero
        )
        let target = makeCoordinatorTarget("/scan/mode")

        coordinator.startScan(target, options: ScanOptions())
        service.yield(.executionMode(.incremental), scanIndex: 0)
        service.yield(
            .progress(makeCoordinatorMetrics(path: "/scan/mode/changed.txt", filesVisited: 4)),
            scanIndex: 0
        )
        try await waitUntil("incremental mode and progress") {
            coordinator.progress.executionMode == .incremental
                && coordinator.scanMetrics.filesVisited == 4
        }

        service.yield(
            .executionMode(.fullFallback(.directoryRelistFailed)),
            scanIndex: 0
        )
        try await waitUntil("full fallback mode") {
            coordinator.progress.executionMode == .fullFallback(.directoryRelistFailed)
        }

        XCTAssertEqual(coordinator.scanMetrics.filesVisited, 0)
        XCTAssertEqual(coordinator.scanMetrics.currentPath, "")
        coordinator.stopScan()
    }

    @MainActor
    func testRescanPreparationAndCompletionNoticesFollowExecutionMode() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .zero)
        let target = makeCoordinatorTarget("/scan/notices")
        let baseline = makeCoordinatorSnapshot(target: target)

        coordinator.startScan(
            target,
            options: ScanOptions(),
            baseline: baseline,
            isRescan: true
        )
        XCTAssertEqual(coordinator.progress.executionMode, .preparingIncremental)

        service.yield(.executionMode(.incrementalNoChanges), scanIndex: 0)
        service.yield(.finished(makeCoordinatorSnapshot(target: target)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("no-change completion notice") {
            coordinator.scanCompletionNotice == .noChanges
        }

        coordinator.dismissScanCompletionNotice()
        XCTAssertNil(coordinator.scanCompletionNotice)

        coordinator.startScan(
            target,
            options: ScanOptions(),
            baseline: baseline,
            isRescan: true
        )
        service.yield(.executionMode(.fullFallback(.changedScanOptions)), scanIndex: 1)
        service.yield(.finished(makeCoordinatorSnapshot(target: target)), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("fallback completion notice") {
            coordinator.scanCompletionNotice == .fullFallback(.changedScanOptions)
        }
    }

    @MainActor
    func testStartScanWithEligibleBaselineRoutesToRescan() {
        let service = RescanRecordingService()
        let coordinator = ScanCoordinator(scanService: service)
        let target = makeCoordinatorTarget("/scan/incremental")
        let baseline = makeCoordinatorSnapshot(target: target)
        let options = ScanOptions(includeHiddenFiles: true)

        coordinator.startScan(target, options: options, baseline: baseline)

        XCTAssertTrue(service.scanRequests.isEmpty)
        XCTAssertEqual(service.rescanRequests.map(\.target), [target])
        XCTAssertEqual(service.rescanRequests.map(\.baselineID), [baseline.id])
        XCTAssertEqual(service.rescanRequests.first?.options.includeHiddenFiles, true)
        coordinator.stopScan()
    }

    @MainActor
    func testStartScanBaselineUsesExplicitFullScanFallback() {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service)
        let target = makeCoordinatorTarget("/scan/fallback")
        let baseline = makeCoordinatorSnapshot(target: target)

        coordinator.startScan(target, options: ScanOptions(), baseline: baseline)

        XCTAssertEqual(service.requests.map(\.target), [target])
        coordinator.stopScan()
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
    func testPublishedProgressDoesNotRegressWithinScan() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(
            scanService: service,
            progressThrottleDuration: .zero
        )
        var leading = makeCoordinatorMetrics(path: "leading", filesVisited: 6)
        leading.progressFraction = 0.6
        var trailing = makeCoordinatorMetrics(path: "trailing", filesVisited: 4)
        trailing.progressFraction = 0.4

        coordinator.startScan(
            makeCoordinatorTarget("/scan/monotonic-progress"),
            options: ScanOptions()
        )
        service.yield(.progress(leading), scanIndex: 0)
        service.yield(.progress(trailing), scanIndex: 0)

        try await waitUntil("latest progress counters") {
            coordinator.scanMetrics.currentPath == "trailing"
        }

        XCTAssertEqual(coordinator.scanMetrics.filesVisited, 4)
        XCTAssertEqual(coordinator.scanMetrics.progressFraction, 0.6, accuracy: 0.0001)
        coordinator.stopScan()
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
    func testFolderRescanKeepsBaselineVisibleAndAtomicallyReplacesSubtree() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(
            scanService: service,
            progressThrottleDuration: .zero
        )
        let rootTarget = makeCoordinatorTarget("/scan/home")
        let folderTarget = makeCoordinatorTarget("/scan/home/Downloads")
        let checkpoint = ScanIncrementalCheckpoint(volumeUUID: "test-volume", eventID: 42)
        let baseline = makeCoordinatorHomeSnapshot(
            target: rootTarget,
            downloadsTarget: folderTarget,
            rootName: "home",
            scanOptions: ScanOptions(includeHiddenFiles: true),
            incrementalCheckpoint: checkpoint
        )
        let originalSibling = try XCTUnwrap(
            baseline.treeStore.node(id: rootTarget.id + "/notes.txt")
        )
        coordinator.restoreCompletedSnapshot(baseline)

        XCTAssertTrue(coordinator.rescanFolder(id: folderTarget.id))
        XCTAssertFalse(coordinator.rescanFolder(id: folderTarget.id))
        XCTAssertEqual(coordinator.snapshot?.id, baseline.id)
        XCTAssertEqual(coordinator.snapshot?.treeStore.contentID, baseline.treeStore.contentID)
        XCTAssertEqual(
            coordinator.folderRescanState,
            FolderRescanState(nodeName: "Downloads")
        )
        XCTAssertTrue(coordinator.isScanOperationInProgress)
        XCTAssertEqual(service.requests.map(\.target), [
            ScanTarget(url: folderTarget.url, kind: .folder)
        ])
        XCTAssertEqual(service.subtreeBehaviorTargets, [rootTarget])
        XCTAssertEqual(service.requests.first?.options.includeHiddenFiles, true)
        XCTAssertEqual(service.requests.first?.options.exclusionRootPath, rootTarget.id)

        service.yield(
            .progress(makeCoordinatorMetrics(
                path: folderTarget.id + "/new.dat",
                filesVisited: 1
            )),
            scanIndex: 0
        )
        let first = makeTestFileNode(
            id: folderTarget.id + "/new.dat",
            name: "new.dat",
            size: 50
        )
        let second = makeTestFileNode(
            id: folderTarget.id + "/other.dat",
            name: "other.dat",
            size: 30
        )
        let replacementRoot = makeTestDirectoryNode(
            id: folderTarget.id,
            name: "Downloads",
            children: [first, second]
        )
        let replacementStore = FileTreeStore(
            root: replacementRoot,
            childrenByID: [replacementRoot.id: [first, second]]
        )
        let replacementWarning = ScanWarning(
            path: first.id,
            message: "replacement warning",
            category: .fileSystem
        )
        let replacement = makeCoordinatorSnapshot(
            target: folderTarget,
            root: replacementRoot,
            store: replacementStore,
            warnings: [replacementWarning]
        )

        service.yield(.finished(replacement), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("folder rescan finished") {
            coordinator.scanCompletionNotice == .folderUpdated(name: "Downloads")
        }

        let updated = try XCTUnwrap(coordinator.snapshot)
        XCTAssertEqual(updated.id, baseline.id)
        XCTAssertEqual(updated.target, baseline.target)
        XCTAssertEqual(updated.incrementalCheckpoint, checkpoint)
        XCTAssertEqual(updated.treeStore.children(of: folderTarget.id).map(\.id), [
            first.id,
            second.id,
        ])
        XCTAssertEqual(updated.treeStore.node(id: originalSibling.id), originalSibling)
        XCTAssertEqual(updated.scanWarnings.map(\.path), [replacementWarning.path])
        XCTAssertGreaterThan(
            try XCTUnwrap(updated.finishedAt),
            try XCTUnwrap(baseline.finishedAt)
        )
        XCTAssertFalse(coordinator.isScanOperationInProgress)
        XCTAssertNil(coordinator.folderRescanState)
    }

    @MainActor
    func testFolderRescanFallsBackToFullScanForCloneMetadata() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(
            scanService: service,
            progressThrottleDuration: .zero
        )
        let rootTarget = makeCoordinatorTarget("/scan/shared")
        let folderTarget = makeCoordinatorTarget("/scan/shared/Changed")
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 42)
        let changedClone = makeTestFileNode(
            id: folderTarget.id + "/shared.dat",
            name: "shared.dat",
            size: 20,
            cloneIdentity: cloneIdentity,
            mayShareDataBlocks: true
        )
        let siblingClone = makeTestFileNode(
            id: rootTarget.id + "/shared.dat",
            name: "shared.dat",
            size: 0,
            unduplicatedAllocatedSize: 20,
            cloneIdentity: cloneIdentity,
            mayShareDataBlocks: true
        )
        let folder = makeTestDirectoryNode(
            id: folderTarget.id,
            name: "Changed",
            children: [changedClone]
        )
        let root = makeTestDirectoryNode(
            id: rootTarget.id,
            name: "shared",
            children: [folder, siblingClone]
        )
        let baselineStore = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, siblingClone],
            folder.id: [changedClone],
        ])
        let options = ScanOptions()
        let baseline = makeCoordinatorSnapshot(
            target: rootTarget,
            root: root,
            store: baselineStore,
            scanOptions: options
        )
        coordinator.restoreCompletedSnapshot(baseline)

        XCTAssertTrue(coordinator.rescanFolder(id: folder.id))

        let replacementFile = makeTestFileNode(
            id: changedClone.id,
            name: changedClone.name,
            size: 40,
            cloneIdentity: cloneIdentity,
            mayShareDataBlocks: true
        )
        let replacementRoot = makeTestDirectoryNode(
            id: folder.id,
            name: folder.name,
            children: [replacementFile]
        )
        service.yield(.finished(makeCoordinatorSnapshot(
            target: folderTarget,
            root: replacementRoot,
            store: FileTreeStore(
                root: replacementRoot,
                childrenByID: [replacementRoot.id: [replacementFile]]
            )
        )), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("shared folder rescan starts full fallback") {
            service.requests.count == 2
                && coordinator.progress.executionMode
                    == .fullFallback(.sharedAllocationTopologyChanged)
        }
        let fallbackRequest = try XCTUnwrap(service.requests.dropFirst().first)
        XCTAssertEqual(fallbackRequest.target, rootTarget)
        XCTAssertEqual(fallbackRequest.options, options)
        XCTAssertEqual(
            coordinator.folderRescanState,
            FolderRescanState(nodeName: rootTarget.displayName)
        )

        let fullSnapshot = makeCoordinatorSnapshot(
            target: rootTarget,
            scanOptions: options
        )
        service.yield(.finished(fullSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)

        try await waitUntil("shared folder full fallback finishes") {
            coordinator.scanCompletionNotice
                == .fullFallback(.sharedAllocationTopologyChanged)
        }
        XCTAssertEqual(coordinator.snapshot?.id, fullSnapshot.id)
        XCTAssertNil(coordinator.folderRescanState)
    }

    @MainActor
    func testFolderRescanRefreshesWholeVolumeCapacityAccounting() async throws {
        let service = ControlledScanService()
        let refreshedCapacity = VolumeCapacitySnapshot(
            totalCapacity: 1_000_000_000,
            availableCapacity: 300_000_000
        )
        let coordinator = ScanCoordinator(
            scanService: service,
            volumeCapacityProvider: { _ in
                VolumeCapacityRefresh(
                    capacity: refreshedCapacity,
                    reconcilesTree: true
                )
            },
            progressThrottleDuration: .zero
        )
        let volumeTarget = ScanTarget(
            url: URL(filePath: "/test-volume", directoryHint: .isDirectory),
            kind: .volume
        )
        let oldFile = makeTestFileNode(
            id: volumeTarget.id + "/Folder/old.dat",
            name: "old.dat",
            size: 20
        )
        let folder = makeTestDirectoryNode(
            id: volumeTarget.id + "/Folder",
            name: "Folder",
            children: [oldFile]
        )
        let root = makeTestDirectoryNode(
            id: volumeTarget.id,
            name: "Test Volume",
            children: [folder]
        )
        let baselineStore = FileTreeStore(root: root, childrenByID: [
            root.id: [folder],
            folder.id: [oldFile],
        ])
        let baseline = ScanSnapshot(
            target: volumeTarget,
            treeStore: baselineStore,
            startedAt: .now,
            finishedAt: .now,
            scanWarnings: [],
            isComplete: true,
            scanOptions: ScanOptions(),
            volumeCapacity: VolumeCapacitySnapshot(
                totalCapacity: 1_000_000_000,
                availableCapacity: 400_000_000
            ),
            incrementalCheckpoint: ScanIncrementalCheckpoint(
                volumeUUID: "test-volume",
                eventID: 10
            )
        )
        coordinator.restoreCompletedSnapshot(baseline)

        XCTAssertTrue(coordinator.rescanFolder(id: folder.id))
        let replacementFile = makeTestFileNode(
            id: folder.id + "/new.dat",
            name: "new.dat",
            size: 40
        )
        let replacementRoot = makeTestDirectoryNode(
            id: folder.id,
            name: folder.name,
            children: [replacementFile]
        )
        let replacementStore = FileTreeStore(
            root: replacementRoot,
            childrenByID: [replacementRoot.id: [replacementFile]]
        )
        service.yield(
            .finished(makeCoordinatorSnapshot(
                target: ScanTarget(url: folder.url, kind: .folder),
                root: replacementRoot,
                store: replacementStore
            )),
            scanIndex: 0
        )
        service.finish(scanIndex: 0)

        try await waitUntil("volume folder rescan finished") {
            coordinator.folderRescanState == nil
        }

        let updated = try XCTUnwrap(coordinator.snapshot)
        XCTAssertEqual(updated.volumeCapacity, refreshedCapacity)
        XCTAssertEqual(updated.root.allocatedSize, refreshedCapacity.usedCapacity)
        XCTAssertEqual(updated.treeStore.node(id: replacementFile.id)?.allocatedSize, 40)
        XCTAssertEqual(
            updated.incrementalCheckpoint,
            baseline.incrementalCheckpoint
        )
    }

    @MainActor
    func testStoppingFolderRescanKeepsExistingSnapshot() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service)
        let rootTarget = makeCoordinatorTarget("/scan/cancel-folder")
        let folderTarget = makeCoordinatorTarget("/scan/cancel-folder/Folder")
        let baseline = makeCoordinatorHomeSnapshot(
            target: rootTarget,
            downloadsTarget: folderTarget,
            rootName: "root",
            scanOptions: ScanOptions()
        )
        coordinator.restoreCompletedSnapshot(baseline)

        XCTAssertTrue(coordinator.rescanFolder(id: folderTarget.id))
        coordinator.stopScan()

        try await waitUntil("folder stream cancellation") {
            service.terminationCount > 0
        }
        XCTAssertEqual(coordinator.snapshot?.treeStore.contentID, baseline.treeStore.contentID)
        XCTAssertFalse(coordinator.isScanOperationInProgress)
        XCTAssertNil(coordinator.folderRescanState)
        XCTAssertNil(coordinator.scanCompletionNotice)
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
        let sibling = makeTestFileNode(id: "/root/readme.txt", name: "readme.txt", size: 50)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarizedNode, sibling])
        let baseStore = FileTreeStore(root: root, childrenByID: [root.id: [summarizedNode, sibling]])
        let existingWarning = ScanWarning(path: "/root/cache", message: "original", category: .fileSystem)
        let baseSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget("/root"),
            root: root,
            store: baseStore,
            warnings: [existingWarning]
        )
        coordinator.replaceCurrentSnapshot(baseSnapshot)

        let expandedFile = makeTestFileNode(id: "/root/cache/item.txt", name: "item.txt", size: 125)
        let expandedRoot = makeTestDirectoryNode(id: summarizedNode.id, name: "cache", children: [expandedFile])
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
        XCTAssertEqual(coordinator.expandingNodeID, summarizedNode.id)

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
        XCTAssertEqual(updatedSnapshot.scanWarnings.map(\.path), [expansionWarning.path])
        XCTAssertEqual(coordinator.fileTreeStore?.root.id, root.id)
        XCTAssertEqual(
            coordinator.completedScanSnapshot?.treeStore.children(of: summarizedNode.id).map(\.id),
            [expandedFile.id]
        )
        XCTAssertNil(coordinator.expandingNodeID)
    }

    @MainActor
    func testRemovingLargeSubtreeFromCurrentSnapshotUsesTransformService() async throws {
        let service = ControlledScanService()
        let transformService = RecordingSnapshotTransformService()
        let coordinator = ScanCoordinator(
            scanService: service,
            snapshotTransformService: transformService,
            progressThrottleDuration: .milliseconds(40)
        )
        let target = makeCoordinatorTarget("/root")
        let removedFiles = (0..<600).map { index in
            makeTestFileNode(
                id: "/root/cache/file-\(index).dat",
                name: "file-\(index).dat",
                size: 1
            )
        }
        let removedDirectory = makeTestDirectoryNode(id: "/root/cache", name: "cache", children: removedFiles)
        let sibling = makeTestFileNode(id: "/root/readme.txt", name: "readme.txt", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [removedDirectory, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [removedDirectory, sibling],
            removedDirectory.id: removedFiles,
        ])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        coordinator.replaceCurrentSnapshot(snapshot)

        let didRemove = await coordinator.removeNodesFromCurrentSnapshot(ids: [removedDirectory.id])
        let recordedRemovingNodeIDs = await transformService.recordedRemovingNodeIDs()

        XCTAssertTrue(didRemove)
        XCTAssertEqual(recordedRemovingNodeIDs, [removedDirectory.id])
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: removedDirectory.id))
        XCTAssertEqual(coordinator.snapshot?.aggregateStats.fileCount, 1)
        XCTAssertEqual(coordinator.fileTreeStore?.children(of: root.id).map(\.id), [sibling.id])
    }

    @MainActor
    func testRemovingMultipleNodesUsesOneSnapshotTransformation() async throws {
        let transformService = RecordingSnapshotTransformService()
        let coordinator = ScanCoordinator(snapshotTransformService: transformService)
        let first = makeTestFileNode(id: "/root/first.dat", name: "first.dat", size: 10)
        let second = makeTestFileNode(id: "/root/second.dat", name: "second.dat", size: 20)
        let retained = makeTestFileNode(id: "/root/retained.dat", name: "retained.dat", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [first, second, retained])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second, retained]])
        coordinator.replaceCurrentSnapshot(makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(root.id),
            root: root,
            store: store
        ))

        let didRemove = await coordinator.removeNodesFromCurrentSnapshot(ids: [first.id, second.id])
        let batches = await transformService.recordedRemovingNodeIDBatches()

        XCTAssertTrue(didRemove)
        XCTAssertEqual(batches, [[first.id, second.id]])
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: first.id))
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: second.id))
        XCTAssertNotNil(coordinator.snapshot?.treeStore.node(id: retained.id))
    }

    @MainActor
    func testConcurrentSameContextRemovalsRetryAndPreserveBothMutations() async throws {
        let first = makeTestFileNode(id: "/root/first.dat", name: "first.dat", size: 10)
        let second = makeTestFileNode(id: "/root/second.dat", name: "second.dat", size: 20)
        let retained = makeTestFileNode(id: "/root/retained.dat", name: "retained.dat", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [first, second, retained])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second, retained]])
        let transformService = PausingSnapshotTransformService(pausedRemovalID: first.id)
        let coordinator = ScanCoordinator(snapshotTransformService: transformService)
        coordinator.replaceCurrentSnapshot(makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(root.id),
            root: root,
            store: store
        ))

        let firstRemoval = Task { @MainActor in
            await coordinator.removeNodesFromCurrentSnapshot(ids: [first.id])
        }
        await transformService.waitUntilPaused()
        let didRemoveSecond = await coordinator.removeNodesFromCurrentSnapshot(ids: [second.id])
        await transformService.resume()
        let didRemoveFirst = await firstRemoval.value
        let batches = await transformService.recordedRemovalBatches()

        XCTAssertTrue(didRemoveFirst)
        XCTAssertTrue(didRemoveSecond)
        XCTAssertEqual(batches, [[first.id], [second.id], [first.id]])
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: first.id))
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: second.id))
        XCTAssertNotNil(coordinator.snapshot?.treeStore.node(id: retained.id))
    }

    @MainActor
    func testPausedRemovalCannotOverwriteSameIDExternalSnapshotReplacement() async throws {
        let removed = makeTestFileNode(id: "/root/removed.dat", name: "removed.dat", size: 10)
        let retained = makeTestFileNode(id: "/root/retained.dat", name: "retained.dat", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [removed, retained])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [removed, retained]])
        let originalSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(root.id),
            root: root,
            store: store
        )
        let transformService = PausingSnapshotTransformService(pausedRemovalID: removed.id)
        let coordinator = ScanCoordinator(snapshotTransformService: transformService)
        coordinator.replaceCurrentSnapshot(originalSnapshot)

        let removal = Task { @MainActor in
            await coordinator.removeNodesFromCurrentSnapshot(ids: [removed.id])
        }
        await transformService.waitUntilPaused()

        let externallyAdded = makeTestFileNode(id: "/root/external.dat", name: "external.dat", size: 30)
        let replacementRoot = makeTestDirectoryNode(
            id: root.id,
            name: root.name,
            children: [removed, retained, externallyAdded]
        )
        let replacementStore = FileTreeStore(root: replacementRoot, childrenByID: [
            replacementRoot.id: [removed, retained, externallyAdded],
        ])
        coordinator.replaceCurrentSnapshot(copyCoordinatorSnapshot(
            originalSnapshot,
            treeStore: replacementStore
        ))

        await transformService.resume()
        let didRemove = await removal.value

        XCTAssertFalse(didRemove)
        XCTAssertEqual(coordinator.snapshot?.id, originalSnapshot.id)
        XCTAssertEqual(coordinator.snapshot?.treeStore.contentID, replacementStore.contentID)
        XCTAssertNotNil(coordinator.snapshot?.treeStore.node(id: removed.id))
        XCTAssertNotNil(coordinator.snapshot?.treeStore.node(id: externallyAdded.id))
    }

    @MainActor
    func testExpansionRetriesAfterUnrelatedRemovalInSameContext() async throws {
        let scanService = ControlledScanService()
        let summarized = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let removed = makeTestFileNode(id: "/root/removed.dat", name: "removed.dat", size: 20)
        let retained = makeTestFileNode(id: "/root/retained.dat", name: "retained.dat", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarized, removed, retained])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarized, removed, retained]])
        let transformService = PausingSnapshotTransformService(pausedReplacementID: summarized.id)
        let coordinator = ScanCoordinator(
            scanService: scanService,
            snapshotTransformService: transformService
        )
        coordinator.replaceCurrentSnapshot(makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(root.id),
            root: root,
            store: store
        ))

        let expandedFile = makeTestFileNode(id: summarized.id + "/expanded.dat", name: "expanded.dat", size: 125)
        let expandedRoot = makeTestDirectoryNode(id: summarized.id, name: summarized.name, children: [expandedFile])
        let expandedStore = FileTreeStore(root: expandedRoot, childrenByID: [expandedRoot.id: [expandedFile]])
        let expandedSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(summarized.id),
            root: expandedRoot,
            store: expandedStore
        )
        var expansionResult: ScanExpansionResult?
        coordinator.expandSummarizedNode(summarized, options: ScanOptions()) { result in
            expansionResult = result
        }
        scanService.yield(.finished(expandedSnapshot), scanIndex: 0)
        scanService.finish(scanIndex: 0)
        await transformService.waitUntilPaused()

        let didRemove = await coordinator.removeNodesFromCurrentSnapshot(ids: [removed.id])
        await transformService.resume()
        try await waitUntil("expansion retry") {
            expansionResult != nil
        }
        let replacementIDs = await transformService.recordedReplacementIDs()

        XCTAssertTrue(didRemove)
        guard case .expanded(let replacementRootID) = expansionResult else {
            return XCTFail("Expected expansion to survive the unrelated removal.")
        }
        XCTAssertEqual(replacementRootID, summarized.id)
        XCTAssertEqual(replacementIDs, [summarized.id, summarized.id])
        XCTAssertNil(coordinator.snapshot?.treeStore.node(id: removed.id))
        XCTAssertNotNil(coordinator.snapshot?.treeStore.node(id: retained.id))
        XCTAssertEqual(
            coordinator.snapshot?.treeStore.children(of: summarized.id).map(\.id),
            [expandedFile.id]
        )
    }

    @MainActor
    func testReplacingCurrentSnapshotCancelsActiveExpansion() {
        let scanService = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: scanService)
        let summarized = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarized])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarized]])
        let snapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(root.id),
            root: root,
            store: store
        )
        coordinator.replaceCurrentSnapshot(snapshot)
        var expansionResult: ScanExpansionResult?
        coordinator.expandSummarizedNode(summarized, options: ScanOptions()) { result in
            expansionResult = result
        }

        coordinator.replaceCurrentSnapshot(snapshot)

        guard case .cancelled = expansionResult else {
            return XCTFail("Expected external snapshot replacement to cancel expansion.")
        }
        XCTAssertNil(coordinator.expandingNodeID)
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
    func testAppModelScanCompletionPublishesNavigationOnce() async throws {
        let service = ControlledScanService()
        let model = AppModel(dependencies: makeCoordinatorAppDependencies(scanService: service))
        let target = makeCoordinatorTarget("/app/scan/publish")
        let snapshot = makeCoordinatorSnapshot(target: target)

        model.startScan(target)
        try await waitUntil("AppModel scan request") {
            service.requests.count == 1
        }

        var publishedStates: [WorkspaceNavigationState] = []
        var cancellables = Set<AnyCancellable>()
        model.navigation.$state
            .dropFirst()
            .sink { state in
                guard state.snapshotID == snapshot.id else { return }
                publishedStates.append(state)
            }
            .store(in: &cancellables)

        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("AppModel scan completion") {
            model.scanState.phase == .displaying
        }

        XCTAssertEqual(publishedStates.count, 1)
        XCTAssertEqual(publishedStates.first?.focusedNodeID, snapshot.root.id)
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
        XCTAssertEqual(model.sidebar.activeTargetID, firstTarget.id)
    }

    @MainActor
    func testAppModelKeepsSmallCachedSidebarTargetsBeyondTwoScans() async throws {
        let service = ControlledScanService()
        let firstTarget = makeCoordinatorTarget("/app/sidebar/small-first")
        let secondTarget = makeCoordinatorTarget("/app/sidebar/small-second")
        let thirdTarget = makeCoordinatorTarget("/app/sidebar/small-third")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [firstTarget, secondTarget, thirdTarget])
            )
        )
        let targets = [firstTarget, secondTarget, thirdTarget]
        let snapshots = targets.map { makeCoordinatorSnapshot(target: $0) }

        for (index, target) in targets.enumerated() {
            model.selectSidebarTarget(id: target.id)
            try await waitUntil("small sidebar scan request \(index)") {
                service.requests.count == index + 1
            }
            service.yield(.finished(snapshots[index]), scanIndex: index)
            service.finish(scanIndex: index)
            try await waitUntil("small sidebar scan finished \(index)") {
                model.scanState.snapshot?.target == target
            }
        }

        model.selectSidebarTarget(id: firstTarget.id)
        try await waitUntil("first small scan restored or rescanned") {
            model.scanState.snapshot?.target == firstTarget || service.requests.count > targets.count
        }

        XCTAssertEqual(service.requests.count, targets.count)
        XCTAssertEqual(model.scanState.selectedTarget, firstTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, firstTarget)
        XCTAssertEqual(model.navigation.focusedNodeID, snapshots[0].root.id)
        XCTAssertEqual(model.sidebar.activeTargetID, firstTarget.id)
    }

    @MainActor
    func testAppModelRestoresOversizedCachedParentAfterScopingSidebarTarget() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/oversized-home")
        let downloadsTarget = makeCoordinatorTarget("/app/sidebar/oversized-home/Downloads")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, downloadsTarget])
            ),
            completedScanCacheMaxTotalNodeCount: 3
        )
        let homeSnapshot = makeCoordinatorHomeSnapshot(
            target: homeTarget,
            downloadsTarget: downloadsTarget,
            rootName: "oversized-home"
        )
        XCTAssertGreaterThan(homeSnapshot.treeStore.nodeCount, 3)

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("oversized home scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(homeSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("oversized home scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.selectSidebarTarget(id: downloadsTarget.id)
        try await waitUntil("downloads scoped from oversized home") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("oversized home restored from cache") {
            model.scanState.snapshot?.target == homeTarget
        }

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(model.scanState.selectedTarget, homeTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, homeTarget.id)
        XCTAssertEqual(model.navigation.focusedNodeID, homeTarget.id)
    }

    @MainActor
    func testAppModelRescansEvictedOversizedScanAfterAnotherScan() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/oversized-recent-home")
        let downloadsTarget = makeCoordinatorTarget("/app/sidebar/oversized-recent-home/Downloads")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, downloadsTarget])
            ),
            completedScanCacheMaxTotalNodeCount: 3
        )
        let homeSnapshot = makeCoordinatorHomeSnapshot(
            target: homeTarget,
            downloadsTarget: downloadsTarget,
            rootName: "oversized-recent-home"
        )
        let downloadsSnapshot = makeCoordinatorSnapshot(target: downloadsTarget)
        XCTAssertGreaterThan(homeSnapshot.treeStore.nodeCount, 3)

        model.startScan(homeTarget)
        try await waitUntil("oversized recent home scan request") {
            service.requests.count == 1
        }
        service.yield(.finished(homeSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("oversized recent home scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.startScan(downloadsTarget)
        try await waitUntil("downloads exact scan request") {
            service.requests.count == 2
        }
        service.yield(.finished(downloadsSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("downloads exact scan finished") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("evicted home rescan requested") {
            service.requests.count == 3
        }
        service.yield(.finished(homeSnapshot), scanIndex: 2)
        service.finish(scanIndex: 2)
        try await waitUntil("evicted home rescan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        XCTAssertEqual(service.requests.count, 3)
        XCTAssertEqual(model.scanState.selectedTarget, homeTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, homeTarget.id)
        XCTAssertEqual(model.navigation.focusedNodeID, homeTarget.id)
    }

    @MainActor
    func testAppModelRescanBypassesSidebarCacheAndUsesEligibleBaseline() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/sidebar/rescan")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )

        model.selectSidebarTarget(id: target.id)
        try await waitUntil("initial sidebar scan request") {
            service.requests.count == 1
        }
        let scanOptions = try XCTUnwrap(service.requests.first?.options)
        let snapshot = makeCoordinatorSnapshot(
            target: target,
            scanOptions: scanOptions,
            incrementalCheckpoint: ScanIncrementalCheckpoint(
                volumeUUID: "test-volume",
                eventID: 10
            )
        )
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("initial sidebar scan finished") {
            model.scanState.phase == .displaying
        }

        model.rescan()

        try await waitUntil("rescan request") {
            service.rescanRequests.count == 1
        }
        XCTAssertEqual(service.requests.map(\.target), [target, target])
        XCTAssertEqual(service.rescanRequests.map(\.target), [target])
        XCTAssertEqual(service.rescanRequests.map(\.baselineID), [snapshot.id])
        XCTAssertEqual(service.rescanRequests.map(\.options), [scanOptions])
    }

    @MainActor
    func testAppModelRescanUsesFocusedFolderAndPreservesNavigation() async throws {
        let service = ControlledScanService()
        let rootTarget = makeCoordinatorTarget("/app/focused-rescan")
        let folderTarget = makeCoordinatorTarget("/app/focused-rescan/Downloads")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [rootTarget])
            )
        )

        model.startScan(rootTarget)
        try await waitUntil("focused baseline request") {
            service.requests.count == 1
        }
        let scanOptions = try XCTUnwrap(service.requests.first?.options)
        let baseline = makeCoordinatorHomeSnapshot(
            target: rootTarget,
            downloadsTarget: folderTarget,
            rootName: "root",
            scanOptions: scanOptions,
            incrementalCheckpoint: ScanIncrementalCheckpoint(
                volumeUUID: "test-volume",
                eventID: 10
            )
        )
        service.yield(.finished(baseline), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("focused baseline finished") {
            model.scanState.phase == .displaying
        }

        model.focus(nodeID: folderTarget.id)
        XCTAssertEqual(model.navigation.focusedNodeID, folderTarget.id)
        XCTAssertTrue(model.canRescanCurrentFolder)
        model.rescan()

        try await waitUntil("focused folder request") {
            service.requests.count == 2
        }
        XCTAssertEqual(service.requests[1].target, ScanTarget(
            url: folderTarget.url,
            kind: .folder
        ))
        XCTAssertTrue(service.rescanRequests.isEmpty)
        XCTAssertEqual(model.scanState.snapshot?.id, baseline.id)

        let refreshedFile = makeTestFileNode(
            id: folderTarget.id + "/refreshed.dat",
            name: "refreshed.dat",
            size: 90
        )
        let refreshedRoot = makeTestDirectoryNode(
            id: folderTarget.id,
            name: "Downloads",
            children: [refreshedFile]
        )
        let refreshedStore = FileTreeStore(
            root: refreshedRoot,
            childrenByID: [refreshedRoot.id: [refreshedFile]]
        )
        service.yield(
            .finished(makeCoordinatorSnapshot(
                target: folderTarget,
                root: refreshedRoot,
                store: refreshedStore
            )),
            scanIndex: 1
        )
        service.finish(scanIndex: 1)

        try await waitUntil("focused folder applied") {
            model.scanState.scanCompletionNotice == .folderUpdated(name: "Downloads")
        }
        XCTAssertEqual(model.navigation.focusedNodeID, folderTarget.id)
        XCTAssertEqual(
            model.scanState.snapshot?.treeStore.children(of: folderTarget.id).map(\.id),
            [refreshedFile.id]
        )
    }

    @MainActor
    func testAppModelRescanPreservesIntentWhenScanOptionsChanged() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/sidebar/rescan-options")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )

        model.startScan(target)
        try await waitUntil("initial options scan") {
            service.requests.count == 1
        }
        let initialOptions = try XCTUnwrap(service.requests.first?.options)
        let snapshot = makeCoordinatorSnapshot(
            target: target,
            scanOptions: initialOptions,
            incrementalCheckpoint: ScanIncrementalCheckpoint(
                volumeUUID: "test-volume",
                eventID: 10
            )
        )
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("initial options scan finished") {
            model.scanState.phase == .displaying
        }

        model.treatPackagesAsDirectories.toggle()
        model.rescan()

        try await waitUntil("changed-options rescan request") {
            service.rescanRequests.count == 1
        }
        XCTAssertEqual(service.rescanRequests.first?.baselineID, snapshot.id)
        XCTAssertNotEqual(service.rescanRequests.first?.options, initialOptions)
        XCTAssertEqual(model.scanState.progress.executionMode, .preparingIncremental)
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
    func testAppModelPathScopedExclusionsDoNotReuseContainingSnapshot() async throws {
        let service = ControlledScanService()
        let homeTarget = makeCoordinatorTarget("/app/sidebar/exclusion-home")
        let libraryTarget = makeCoordinatorTarget("/app/sidebar/exclusion-home/Library")
        let preferences = TestAppPreferencesStore(
            preferences: AppPreferences(
                scan: exclusionScanPreferences(patterns: ["Library/Caches/**"]),
                didCompleteOnboarding: true
            )
        )
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                preferences: preferences,
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [homeTarget, libraryTarget])
            )
        )
        let libraryNode = makeTestDirectoryNode(
            id: libraryTarget.id,
            name: "Library",
            children: []
        )
        let homeRoot = makeTestDirectoryNode(
            id: homeTarget.id,
            name: "exclusion-home",
            children: [libraryNode]
        )
        let homeStore = FileTreeStore(root: homeRoot, childrenByID: [
            homeRoot.id: [libraryNode]
        ])
        let homeSnapshot = makeCoordinatorSnapshot(target: homeTarget, root: homeRoot, store: homeStore)

        model.selectSidebarTarget(id: homeTarget.id)
        try await waitUntil("home exclusion scan request") {
            service.requests.count == 1
        }
        XCTAssertEqual(service.requests[0].options.exclusionRootPath, homeTarget.id)

        service.yield(.finished(homeSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("home exclusion scan finished") {
            model.scanState.snapshot?.target == homeTarget
        }

        model.selectSidebarTarget(id: libraryTarget.id)

        try await waitUntil("library exclusion scan request") {
            service.requests.count == 2
        }
        XCTAssertEqual(service.requests[1].target, libraryTarget)
        XCTAssertEqual(service.requests[1].options.exclusionRootPath, libraryTarget.id)
    }

    @MainActor
    func testAppModelChildTrashRemovesNodeWithoutAutomaticRescan() async throws {
        let service = ControlledScanService()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in .matches }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/trash-local")
        let folderID = target.id + "/Folder"
        let child = makeTestFileNode(id: folderID + "/deleted.txt", name: "deleted.txt", size: 20)
        let sibling = makeTestFileNode(id: folderID + "/kept.txt", name: "kept.txt", size: 10)
        let populatedFolder = makeTestDirectoryNode(id: folderID, name: "Folder", children: [child, sibling])
        let root = makeTestDirectoryNode(id: target.id, name: "trash-local", children: [populatedFolder])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [populatedFolder],
            populatedFolder.id: [child, sibling]
        ])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        model.scanState.restoreCompletedSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)
        model.focus(nodeID: populatedFolder.id)
        model.select(nodeID: child.id)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [child])
        model.confirmMovePendingSelectionToTrash()

        try await waitUntil("trashed child removed from current snapshot") {
            model.scanState.snapshot?.treeStore.node(id: child.id) == nil
        }
        XCTAssertNil(model.navigation.selectedNodeID)
        XCTAssertEqual(model.navigation.focusedNodeID, populatedFolder.id)
        XCTAssertEqual(model.navigation.tableNodes.map(\.id), [sibling.id])
        XCTAssertTrue(service.requests.isEmpty)
        // This one representative delay covers the removed one-second post-trash scheduler.
        try await Task.sleep(for: .milliseconds(1_150))
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.navigation.focusedNodeID, populatedFolder.id)
        model.cleanup()
    }

    @MainActor
    func testAppModelMultipleChildTrashesDoNotStartRescan() async throws {
        let service = ControlledScanService()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in .matches }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/trash-burst")
        let first = makeTestFileNode(id: target.id + "/first.txt", name: "first.txt", size: 20)
        let second = makeTestFileNode(id: target.id + "/second.txt", name: "second.txt", size: 10)
        let root = makeTestDirectoryNode(id: target.id, name: "trash-burst", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        model.scanState.restoreCompletedSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [first])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("first trashed child removed") {
            model.scanState.snapshot?.treeStore.node(id: first.id) == nil
        }

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [second])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("second trashed child removed") {
            model.scanState.snapshot?.treeStore.node(id: second.id) == nil
        }
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.scanState.selectedTarget, target)
        XCTAssertEqual(model.scanState.phase, .displaying)
        model.cleanup()
    }

    @MainActor
    func testAppModelBulkChildTrashRemovesNodesWithoutRescan() async throws {
        let service = ControlledScanService()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in .matches }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/trash-bulk")
        let first = makeTestFileNode(id: target.id + "/first.txt", name: "first.txt", size: 20)
        let second = makeTestFileNode(id: target.id + "/second.txt", name: "second.txt", size: 10)
        let root = makeTestDirectoryNode(id: target.id, name: "trash-bulk", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        model.scanState.restoreCompletedSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.requestMoveNodesToTrash([first, second])
        model.confirmMovePendingSelectionToTrash()

        try await waitUntil("bulk trashed children removed") {
            model.scanState.snapshot?.treeStore.node(id: first.id) == nil &&
                model.scanState.snapshot?.treeStore.node(id: second.id) == nil
        }
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(model.scanState.selectedTarget, target)
        XCTAssertEqual(model.scanState.phase, .displaying)
        model.cleanup()
    }

    @MainActor
    func testAppModelActiveRootTrashClearsScanWithoutRescan() async throws {
        let service = ControlledScanService()
        var actions = AppSystemActions.inert
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in .matches }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let target = makeCoordinatorTarget("/app/trash-root")
        let child = makeTestFileNode(id: target.id + "/child.txt", name: "child.txt", size: 20)
        let root = makeTestDirectoryNode(id: target.id, name: "trash-root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        model.scanState.restoreCompletedSnapshot(snapshot)
        model.navigation.reconcileAfterSnapshotApplied(snapshot)

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [root])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("trashed active root clears snapshot") {
            model.scanState.snapshot == nil
        }

        XCTAssertNil(model.scanState.snapshot)
        XCTAssertNil(model.scanState.selectedTarget)
        XCTAssertNil(model.navigation.focusedNodeID)
        XCTAssertTrue(service.requests.isEmpty)
        model.cleanup()
    }

    @MainActor
    func testAppModelTrashActionClearsSidebarSnapshotCache() async throws {
        let service = ControlledScanService()
        let firstTarget = makeCoordinatorTarget("/app/sidebar/stale-first")
        let secondTarget = makeCoordinatorTarget("/app/sidebar/stale-second")
        var actions = makeCoordinatorSidebarActions(targets: [firstTarget, secondTarget])
        actions.fileExists = { _ in true }
        actions.moveToTrash = { _ in .matches }
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: actions
            )
        )
        let secondChild = makeTestFileNode(
            id: secondTarget.id + "/deleted.txt",
            name: "deleted.txt",
            size: 20
        )
        let secondRoot = makeTestDirectoryNode(
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

        model.pendingTrashSelection = AppModel.PendingTrashSelection(nodes: [secondChild])
        model.confirmMovePendingSelectionToTrash()
        try await waitUntil("trashed child removed from second snapshot") {
            model.scanState.snapshot?.treeStore.node(id: secondChild.id) == nil
        }
        XCTAssertEqual(service.requests.count, 2)

        model.selectSidebarTarget(id: firstTarget.id)

        try await waitUntil("first target scans after cache invalidation") {
            service.requests.count == 3
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
        let staleFile = makeTestFileNode(
            id: downloadsTarget.id + "/stale.txt",
            name: "stale.txt",
            size: 8
        )
        let staleDownloadsRoot = makeTestDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [staleFile]
        )
        let staleDownloadsStore = FileTreeStore(root: staleDownloadsRoot, childrenByID: [
            staleDownloadsRoot.id: [staleFile]
        ])
        let downloadFile = makeTestFileNode(
            id: downloadsTarget.id + "/file.txt",
            name: "file.txt",
            size: 20
        )
        let downloadsSnapshot = makeCoordinatorSnapshot(
            target: downloadsTarget,
            root: staleDownloadsRoot,
            store: staleDownloadsStore
        )
        let downloadsNode = makeTestDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let homeRoot = makeTestDirectoryNode(
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

        try await waitUntil("downloads target scoped from home") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(model.scanState.selectedTarget, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, downloadsTarget.id)
        XCTAssertEqual(model.scanState.fileTreeStore?.children(of: downloadsTarget.id).map(\.id), [downloadFile.id])
        XCTAssertEqual(model.navigation.focusedNodeID, downloadsTarget.id)
        XCTAssertEqual(model.sidebar.activeTargetID, downloadsTarget.id)
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
        let downloadFile = makeTestFileNode(
            id: downloadsTarget.id + "/file.txt",
            name: "file.txt",
            size: 20
        )
        let downloadsNode = makeTestDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let homeRoot = makeTestDirectoryNode(
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

        try await waitUntil("downloads target scoped from active snapshot") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(model.scanState.selectedTarget, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, downloadsTarget)
        XCTAssertEqual(model.scanState.snapshot?.root.id, downloadsTarget.id)
        XCTAssertEqual(model.scanState.snapshot?.aggregateStats.totalAllocatedSize, downloadsNode.allocatedSize)
        XCTAssertEqual(model.navigation.focusedNodeID, downloadsTarget.id)
        XCTAssertEqual(model.sidebar.activeTargetID, downloadsTarget.id)

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
        let downloadFile = makeTestFileNode(
            id: downloadsTarget.id + "/download.txt",
            name: "download.txt",
            size: 20
        )
        let documentFile = makeTestFileNode(
            id: documentsTarget.id + "/document.txt",
            name: "document.txt",
            size: 30
        )
        let downloadsNode = makeTestDirectoryNode(
            id: downloadsTarget.id,
            name: "Downloads",
            children: [downloadFile]
        )
        let documentsNode = makeTestDirectoryNode(
            id: documentsTarget.id,
            name: "Documents",
            children: [documentFile]
        )
        let homeRoot = makeTestDirectoryNode(
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
        try await waitUntil("downloads sibling target scoped") {
            model.scanState.snapshot?.target == downloadsTarget
        }

        model.selectSidebarTarget(id: documentsTarget.id)

        try await waitUntil("documents sibling target scoped") {
            model.scanState.snapshot?.target == documentsTarget
        }

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(model.scanState.selectedTarget, documentsTarget)
        XCTAssertEqual(model.scanState.snapshot?.target, documentsTarget)
        XCTAssertEqual(model.scanState.fileTreeStore?.children(of: documentsTarget.id).map(\.id), [documentFile.id])
        XCTAssertEqual(model.sidebar.activeTargetID, documentsTarget.id)
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
    func testAppModelDeferredSidebarSelectionStartsAfterViewUpdate() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/deferred-sidebar")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )

        model.selectSidebarTargetAfterViewUpdate(id: target.id)

        XCTAssertNil(model.sidebar.activeTargetID)
        XCTAssertTrue(service.requests.isEmpty)

        try await waitUntil("deferred sidebar selection starts scan") {
            model.sidebar.activeTargetID == target.id && service.requests.count == 1
        }
    }

    @MainActor
    func testAppModelStopCancelsDeferredSidebarSelection() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/deferred-sidebar-cancel")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )

        model.selectSidebarTargetAfterViewUpdate(id: target.id)
        model.stopScan()

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(model.sidebar.activeTargetID)
        XCTAssertTrue(service.requests.isEmpty)
    }

    @MainActor
    func testAppModelStopClearsEmptySidebarSelectionSoSameTargetCanRestart() async throws {
        let service = ControlledScanService()
        let target = makeCoordinatorTarget("/app/sidebar-cancel-restart")
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                scanService: service,
                systemActions: makeCoordinatorSidebarActions(targets: [target])
            )
        )

        model.selectSidebarTarget(id: target.id)

        try await waitUntil("initial sidebar scan starts") {
            model.sidebar.activeTargetID == target.id && service.requests.count == 1
        }

        model.stopScan()

        try await waitUntil("active sidebar target cleared after cancel") {
            model.sidebar.activeTargetID == nil && service.terminationCount == 1
        }

        model.selectSidebarTarget(id: target.id)

        try await waitUntil("same sidebar target restarts after cancel") {
            model.sidebar.activeTargetID == target.id && service.requests.count == 2
        }
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
        let focusChild = makeTestDirectoryNode(id: "/root/docs", name: "docs", children: [])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarizedNode, focusChild])
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

        let expandedFile = makeTestFileNode(id: "/root/cache/item.txt", name: "item.txt", size: 125)
        let expandedRoot = makeTestDirectoryNode(id: summarizedNode.id, name: "cache", children: [expandedFile])
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

    @MainActor
    func testAppModelExpansionPreservesPathScopedExclusionRoot() async throws {
        let service = ControlledScanService()
        let rootTarget = makeCoordinatorTarget("/root")
        let preferences = TestAppPreferencesStore(
            preferences: AppPreferences(
                scan: exclusionScanPreferences(patterns: ["cache/tmp/**"]),
                didCompleteOnboarding: true
            )
        )
        let model = AppModel(
            dependencies: makeCoordinatorAppDependencies(
                preferences: preferences,
                scanService: service
            )
        )
        let summarizedNode = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarizedNode])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarizedNode]])
        let snapshot = makeCoordinatorSnapshot(target: rootTarget, root: root, store: store)

        model.startScan(rootTarget)
        try await waitUntil("path-scoped root scan request") {
            service.requests.count == 1
        }
        XCTAssertEqual(service.requests[0].options.exclusionRootPath, rootTarget.id)

        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("path-scoped root scan finished") {
            model.scanState.snapshot?.target == rootTarget
        }

        model.expandSummarizedNode(summarizedNode) {}

        try await waitUntil("path-scoped expansion request") {
            service.requests.count == 2
        }
        XCTAssertEqual(service.requests[1].target, ScanTarget(url: summarizedNode.url))
        XCTAssertEqual(service.requests[1].options.exclusionRootPath, rootTarget.id)
        XCTAssertFalse(service.requests[1].options.autoSummarizeDirectories)
    }
}

private struct ControlledScanRequest {
    let target: ScanTarget
    let options: ScanOptions
}

private struct ControlledRescanRequest {
    let target: ScanTarget
    let options: ScanOptions
    let baselineID: UUID
}

private final class RescanRecordingService: ScanEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedScanRequests: [ControlledScanRequest] = []
    private var storedRescanRequests: [ControlledRescanRequest] = []

    var scanRequests: [ControlledScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedScanRequests
    }

    var rescanRequests: [ControlledRescanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRescanRequests
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        storedScanRequests.append(ControlledScanRequest(target: target, options: options))
        lock.unlock()
        return finishedStream()
    }

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        storedRescanRequests.append(
            ControlledRescanRequest(
                target: target,
                options: options,
                baselineID: baseline.id
            )
        )
        lock.unlock()
        return finishedStream()
    }

    private func finishedStream() -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor RecordingSnapshotTransformService: ScanSnapshotTransforming {
    private let service = ScanSnapshotTransformService()
    private var removingNodeIDBatches: [[String]] = []

    func recordedRemovingNodeIDs() -> [String] {
        removingNodeIDBatches.flatMap { $0 }
    }

    func recordedRemovingNodeIDBatches() -> [[String]] {
        removingNodeIDBatches
    }

    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        try await service.replacingNode(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings
        )
    }

    func replacingSubtrees(
        in snapshot: ScanSnapshot,
        replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        try await service.replacingSubtrees(
            in: snapshot,
            replacements: replacements,
            additionalWarnings: additionalWarnings
        )
    }

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot? {
        return try await service.replacingNodeForSubtreeRescan(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            volumeCapacity: volumeCapacity,
            reconcilesVolumeCapacity: reconcilesVolumeCapacity
        )
    }

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot? {
        removingNodeIDBatches.append(targetIDs)
        return try await service.removingNodes(in: snapshot, ids: targetIDs)
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try await service.scopedSnapshot(snapshot, to: target)
    }
}

private actor PausingSnapshotTransformService: ScanSnapshotTransforming {
    private let service = ScanSnapshotTransformService()
    private let pausedRemovalID: String?
    private let pausedReplacementID: String?
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var removalBatches: [[String]] = []
    private var replacementIDs: [String] = []

    init(pausedRemovalID: String? = nil, pausedReplacementID: String? = nil) {
        self.pausedRemovalID = pausedRemovalID
        self.pausedReplacementID = pausedReplacementID
    }

    func waitUntilPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func recordedRemovalBatches() -> [[String]] {
        removalBatches
    }

    func recordedReplacementIDs() -> [String] {
        replacementIDs
    }

    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        replacementIDs.append(targetID)
        await pauseIfNeeded(pausedReplacementID == targetID)
        return try await service.replacingNode(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings
        )
    }

    func replacingSubtrees(
        in snapshot: ScanSnapshot,
        replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        try await service.replacingSubtrees(
            in: snapshot,
            replacements: replacements,
            additionalWarnings: additionalWarnings
        )
    }

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot? {
        replacementIDs.append(targetID)
        await pauseIfNeeded(pausedReplacementID == targetID)
        return try await service.replacingNodeForSubtreeRescan(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            volumeCapacity: volumeCapacity,
            reconcilesVolumeCapacity: reconcilesVolumeCapacity
        )
    }

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot? {
        removalBatches.append(targetIDs)
        await pauseIfNeeded(pausedRemovalID.map(targetIDs.contains) == true)
        return try await service.removingNodes(in: snapshot, ids: targetIDs)
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try await service.scopedSnapshot(snapshot, to: target)
    }

    private func pauseIfNeeded(_ shouldPause: Bool) async {
        guard shouldPause, !didPause else { return }
        didPause = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }
}

private final class ControlledScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ControlledScanRequest] = []
    private var storedRescanRequests: [ControlledRescanRequest] = []
    private var storedSubtreeBehaviorTargets: [ScanTarget] = []
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

    var rescanRequests: [ControlledRescanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRescanRequests
    }

    var subtreeBehaviorTargets: [ScanTarget] {
        lock.lock()
        defer { lock.unlock() }
        return storedSubtreeBehaviorTargets
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

    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        storedRescanRequests.append(
            ControlledRescanRequest(
                target: target,
                options: options,
                baselineID: baseline.id
            )
        )
        lock.unlock()
        return scan(target: target, options: options)
    }

    func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        storedSubtreeBehaviorTargets.append(scanTarget)
        lock.unlock()
        return scan(target: target, options: options)
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
    preferences: TestAppPreferencesStore = TestAppPreferencesStore(),
    scanService: any ScanEventStreaming,
    systemActions: AppSystemActions = .inert
) -> AppDependencies {
    AppDependencies(
        preferences: preferences,
        recentTargets: RecentTargetStore(
            persistence: TestRecentTargetPersistence(),
            isAvailable: { _ in true }
        ),
        systemActions: systemActions,
        scanService: scanService
    )
}

private func exclusionScanPreferences(patterns: [String]) -> AppScanPreferences {
    var preferences = AppScanPreferences.defaults
    preferences.useScanExclusions = true
    preferences.exclusionPatterns = patterns
    return preferences
}

@MainActor
private final class CoordinatorLifecycleActionRecorder {
    var quickLookCloseCount = 0
    var quickLookMonitorRemovalCount = 0
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

private func makeCoordinatorSnapshot(
    target: ScanTarget,
    scanOptions: ScanOptions? = nil,
    incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
) -> ScanSnapshot {
    let file = makeTestFileNode(id: target.url.appendingPathComponent("file.txt").path, name: "file.txt", size: 20)
    let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    return makeCoordinatorSnapshot(
        target: target,
        root: root,
        store: store,
        scanOptions: scanOptions,
        incrementalCheckpoint: incrementalCheckpoint
    )
}

private func makeCoordinatorHomeSnapshot(
    target homeTarget: ScanTarget,
    downloadsTarget: ScanTarget,
    rootName: String,
    scanOptions: ScanOptions? = nil,
    incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
) -> ScanSnapshot {
    let downloadFile = makeTestFileNode(
        id: downloadsTarget.id + "/download.txt",
        name: "download.txt",
        size: 20
    )
    let siblingFile = makeTestFileNode(
        id: homeTarget.id + "/notes.txt",
        name: "notes.txt",
        size: 10
    )
    let downloadsNode = makeTestDirectoryNode(
        id: downloadsTarget.id,
        name: "Downloads",
        children: [downloadFile]
    )
    let homeRoot = makeTestDirectoryNode(
        id: homeTarget.id,
        name: rootName,
        children: [downloadsNode, siblingFile]
    )
    let homeStore = FileTreeStore(root: homeRoot, childrenByID: [
        homeRoot.id: [downloadsNode, siblingFile],
        downloadsNode.id: [downloadFile],
    ])
    return makeCoordinatorSnapshot(
        target: homeTarget,
        root: homeRoot,
        store: homeStore,
        scanOptions: scanOptions,
        incrementalCheckpoint: incrementalCheckpoint
    )
}

private func makeCoordinatorSnapshot(
    target: ScanTarget,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    scanOptions: ScanOptions? = nil,
    incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
) -> ScanSnapshot {
    makeTestSnapshot(
        target: target,
        root: root,
        store: store,
        warnings: warnings,
        scanOptions: scanOptions,
        incrementalCheckpoint: incrementalCheckpoint
    )
}

private func copyCoordinatorSnapshot(
    _ snapshot: ScanSnapshot,
    treeStore: FileTreeStore
) -> ScanSnapshot {
    ScanSnapshot(
        id: snapshot.id,
        target: snapshot.target,
        treeStore: treeStore,
        startedAt: snapshot.startedAt,
        finishedAt: snapshot.finishedAt,
        scanWarnings: snapshot.scanWarnings,
        isComplete: snapshot.isComplete,
        scanOptions: snapshot.scanOptions,
        volumeCapacity: snapshot.volumeCapacity,
        source: snapshot.source,
        incrementalCheckpoint: snapshot.incrementalCheckpoint
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
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: true
    )
}
