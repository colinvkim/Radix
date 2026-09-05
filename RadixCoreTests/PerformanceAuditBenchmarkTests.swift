import Darwin
import Foundation
import XCTest
@testable import RadixCore

/// Opt-in measurements for the performance audit; elapsed times are never test assertions.
final class PerformanceAuditBenchmarkTests: XCTestCase {
    @MainActor
    func testComparisonPreparationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_COMPARISON"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_COMPARISON=1 to measure comparison preparation.")
        }
        let count = environment["RADIX_BENCH_COMPARISON_FILES"].flatMap(Int.init) ?? 100_000
        let before = Self.makeFlatSnapshot(fileCount: 0)
        let after = Self.makeFlatSnapshot(fileCount: count)
        let service = ScanComparisonService(profileReporter: { phase, duration in
            BenchmarkSupport.report(
                prefix: "RADIX_BENCH_AUDIT_RESULT", phase: "comparison_\(phase.rawValue)",
                seconds: BenchmarkSupport.durationSeconds(duration), count: count,
                peakRSS: BenchmarkSupport.peakResidentBytes()
            )
        })
        let comparison = try await service.compare(before: before, after: after)
        XCTAssertEqual(comparison.rows.count, count)
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)
        let queries: [(String, ScanComparisonRowQuery)] = [
            ("initial", .init(searchText: "", sortOrder: [])),
            ("path", .init(searchText: "", sortOrder: [], pathPrefix: "item-0.dat")),
            ("sort", .init(searchText: "", sortOrder: [.defaultOrder])),
            ("search_cold", .init(searchText: "item-0.dat", sortOrder: [])),
            ("search_warm", .init(searchText: "item-1.dat", sortOrder: []))
        ]
        for (phase, query) in queries {
            let start = ContinuousClock.now
            model.refresh(
                comparisonID: comparison.id, rows: comparison.rows,
                changeTree: comparison.changeTree, query: query
            )
            // Avoid spinning the main actor while its background request runs.
            while model.isRefreshing { try await Task.sleep(for: .milliseconds(1)) }
            let seconds = BenchmarkSupport.durationSeconds(start.duration(to: .now))
            var fingerprint = ChartResponsivenessBenchmarkSupport.fnvOffsetBasis
            for row in model.displayedRows {
                ChartResponsivenessBenchmarkSupport.hash(row.relativePath, into: &fingerprint)
            }
            // Sets have process-dependent iteration order; hash ordered projection nodes and totals.
            ChartResponsivenessBenchmarkSupport.hash(String(reflecting: model.projection.roots), into: &fingerprint)
            ChartResponsivenessBenchmarkSupport.hash(
                "\(model.projection.totalImpact):\(model.projection.representedImpact):\(model.projection.hiddenRootCount)",
                into: &fingerprint
            )
            Self.report(
                phase: "comparison_refresh_\(phase)", count: count, seconds: seconds,
                extra: "rows=\(model.displayedRows.count) fingerprint=\(String(fingerprint, radix: 16))"
            )
        }
        withExtendedLifetime(comparison) {}
    }

    @MainActor
    func testChartPreparationBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_CHART_PREPARATION"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_CHART_PREPARATION=1 to measure chart preparation.")
        }
        let scenario = environment["RADIX_BENCH_CHART_SCENARIO"] ?? "sunburst_flat"
        let count = environment["RADIX_BENCH_CHART_FILES"].flatMap(Int.init) ?? 1_000_000
        let snapshot = Self.makeFlatSnapshot(fileCount: count, rootID: "/chart/dense")
        let store: FileTreeStore
        let layoutRootID: String
        if scenario == "treemap_tiny" {
            let root = makeTestDirectoryNode(id: "/chart", name: "chart", children: [snapshot.root])
            store = try FileTreeStore.combining(
                root: root,
                childSubtrees: [try XCTUnwrap(FileTreeStore.SubtreeSource(store: snapshot.treeStore, rootedAt: snapshot.root.id))],
                cancellationCheck: {}
            )
            layoutRootID = root.id
        } else {
            store = snapshot.treeStore
            layoutRootID = scenario == "sunburst_focused"
                ? try XCTUnwrap(store.childrenPrefix(of: store.rootID, maxCount: 1).first).id
                : store.rootID
        }
        let tree = ChartReadProbe(store)
        let initialRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        let initialPeak = BenchmarkSupport.peakResidentBytes()
        let seconds: Double
        let descriptions: [String]
        switch scenario {
        case "sunburst_flat", "sunburst_focused":
            let measurement = try BenchmarkSupport.measure {
                try SunburstLayout.segments(
                    in: tree, rootID: layoutRootID, depthLimit: 6, cancellationCheck: {}
                )
            }
            seconds = measurement.seconds
            descriptions = measurement.value.map { String(reflecting: $0) }
        case "treemap_tiny":
            let measurement = try BenchmarkSupport.measure {
                try TreemapLayout.segments(
                    in: tree, rootID: layoutRootID, depthLimit: 6,
                    size: CGSize(width: 40, height: 40), cancellationCheck: {}
                )
            }
            seconds = measurement.seconds
            descriptions = measurement.value.map { String(reflecting: $0) }
        default:
            XCTFail("Unknown chart scenario: \(scenario)")
            return
        }
        XCTAssertEqual(descriptions.count, 1)
        var fingerprint = ChartResponsivenessBenchmarkSupport.fnvOffsetBasis
        for description in descriptions {
            ChartResponsivenessBenchmarkSupport.hash(description, into: &fingerprint)
        }
        Self.report(
            phase: "chart_preparation_\(scenario)", count: count, seconds: seconds,
            extra: "initial_rss=\(initialRSS) initial_peak_rss=\(initialPeak) timed_layout_only=1 "
                + "projected_nodes=\(tree.projectedNodeCount) root_reads=\(tree.childReadCount(for: store.rootID)) "
                + "segments=\(descriptions.count) fingerprint=\(String(fingerprint, radix: 16))"
        )
        withExtendedLifetime(snapshot) {}
        withExtendedLifetime(tree) {}
    }

    @MainActor
    func testNavigationAuditBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_AUDIT"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_AUDIT=1 to run the navigation audit benchmark.")
        }
        let counts = environment["RADIX_BENCH_AUDIT_ROWS"].flatMap(Int.init)
            .map { [max($0, 1)] } ?? [100_000, 1_000_000]
        print("RADIX_BENCH_AUDIT_LAYOUT file_node_stride=\(MemoryLayout<FileNodeRecord>.stride)")

        for count in counts {
            let fixture = BenchmarkSupport.measure { Self.makeFlatSnapshot(fileCount: count) }
            Self.report(phase: "fixture", count: count, seconds: fixture.seconds)
            let snapshot = fixture.value
            let sunburst = try BenchmarkSupport.measure {
                try SunburstLayout.segments(
                    in: snapshot.treeStore, rootID: snapshot.root.id,
                    depthLimit: 6, cancellationCheck: {}
                )
            }
            Self.report(
                phase: "sunburst_flat_global_root_layout",
                count: count,
                seconds: sunburst.seconds,
                extra: "input_nodes=\(snapshot.treeStore.nodeCount) segments=\(sunburst.value.count)"
            )
            let treemap = try BenchmarkSupport.measure {
                try TreemapLayout.segments(
                    in: snapshot.treeStore, rootID: snapshot.root.id,
                    depthLimit: 6, size: CGSize(width: 1200, height: 800), cancellationCheck: {}
                )
            }
            Self.report(
                phase: "treemap_flat_global_root_layout",
                count: count,
                seconds: treemap.seconds,
                extra: "input_nodes=\(snapshot.treeStore.nodeCount) segments=\(treemap.value.count)"
            )
            let model = WorkspaceNavigationModel()
            let beforeInstallRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
            let installation = BenchmarkSupport.measure {
                model.updateScanContext(snapshot: snapshot)
            }
            XCTAssertEqual(model.tableNodes.count, count)
            Self.report(
                phase: "install_scan_context_main_actor",
                count: count,
                seconds: installation.seconds,
                extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: beforeInstallRSS, to: BenchmarkMemorySampler.currentResidentMemoryBytes()))"
            )

            let tableRefresh = BenchmarkSupport.measure { model.refreshTableNodesForCurrentContext() }
            Self.report(phase: "refresh_unchanged_table_main_actor", count: count, seconds: tableRefresh.seconds)

            let contextRefresh = BenchmarkSupport.measure { model.updateScanContext(snapshot: snapshot) }
            Self.report(phase: "refresh_unchanged_scan_context_main_actor", count: count, seconds: contextRefresh.seconds)

            let reconciliation = BenchmarkSupport.measure { model.reconcileAfterSnapshotApplied(snapshot) }
            Self.report(phase: "reconcile_unchanged_scan_context_main_actor", count: count, seconds: reconciliation.seconds)

            for selectedCount in [0, 1] {
                model.select(nodeID: selectedCount == 0 ? nil : model.tableNodes.last?.id)
                var samples: [Double] = []
                for _ in 0..<5 {
                    let result = BenchmarkSupport.measure { model.selectedNodes }
                    XCTAssertEqual(result.value.count, selectedCount)
                    samples.append(result.seconds)
                }
                Self.report(
                    phase: "selected_nodes_main_actor",
                    count: count,
                    seconds: BenchmarkSupport.median(samples) ?? 0,
                    extra: "selected=\(selectedCount) samples=5"
                )
                let directLookup = BenchmarkSupport.measure { model.selectedNode }
                XCTAssertEqual(directLookup.value == nil ? 0 : 1, selectedCount)
                Self.report(
                    phase: "selected_node_direct_lookup_main_actor",
                    count: count,
                    seconds: directLookup.seconds,
                    extra: "selected=\(selectedCount)"
                )
                let summary = BenchmarkSupport.measure {
                    InspectorSelectionSummary(selectedNodes: model.selectedNodes, fileTreeStore: snapshot.treeStore)
                }
                XCTAssertEqual(summary.value.selectedCount, selectedCount)
                Self.report(
                    phase: "selection_summary_with_resolution_main_actor",
                    count: count,
                    seconds: summary.seconds,
                    extra: "selected=\(selectedCount)"
                )
            }
        }
    }

    func testFilesystemAuditBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RADIX_BENCH_AUDIT_PATH"] else {
            throw XCTSkip("Set RADIX_BENCH_AUDIT_PATH to scan an existing audit fixture.")
        }
        let usesFoundation = environment["RADIX_BENCH_AUDIT_FOUNDATION"] == "1"
        let engine: ScanEngine
        if usesFoundation {
            engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
                try cancellationCheck()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: options
                )
                try cancellationCheck()
                return contents
            })
        } else {
            engine = ScanEngine()
        }
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.includeHiddenFiles = true
        let target = ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
        var finished: ScanSnapshot?
        var progressEvents = 0
        let initialRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        var finalizationStartedAt: ContinuousClock.Instant?
        var finalizationRSS: UInt64 = 0
        var peakRSSAtFinalization: UInt64 = 0
        let startedAt = ContinuousClock.now
        for try await event in engine.scan(target: target, options: options) {
            switch event {
            case .progress(let metrics):
                progressEvents += 1
                if metrics.isFinalizing, finalizationStartedAt == nil {
                    finalizationStartedAt = .now
                    finalizationRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
                    peakRSSAtFinalization = BenchmarkSupport.peakResidentBytes()
                }
            case .finished(let snapshot):
                finished = snapshot
            case .warning, .executionMode:
                break
            }
        }
        let elapsed = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        let finalizationSeconds = finalizationStartedAt.map {
            BenchmarkSupport.durationSeconds($0.duration(to: .now))
        } ?? 0
        let snapshot = try XCTUnwrap(finished)
        print(
            "RADIX_BENCH_AUDIT_FILESYSTEM mode=\(usesFoundation ? "foundation" : "native") "
                + "seconds=\(BenchmarkSupport.format(elapsed)) "
                + "files=\(snapshot.aggregateStats.fileCount) folders=\(snapshot.aggregateStats.directoryCount) "
                + "nodes=\(snapshot.treeStore.nodeCount) progress_events=\(progressEvents) "
                + "warnings=\(snapshot.scanWarnings.count) peak_rss=\(BenchmarkSupport.peakResidentBytes()) "
                + "initial_rss=\(initialRSS) finalization_rss=\(finalizationRSS) "
                + "peak_rss_at_finalization=\(peakRSSAtFinalization) "
                + "finished_rss=\(BenchmarkMemorySampler.currentResidentMemoryBytes()) "
                + "finalization_seconds=\(BenchmarkSupport.format(finalizationSeconds))"
        )
    }

    @MainActor
    func testSnapshotRetentionBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_RETENTION"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_RETENTION=1 to measure snapshot ownership and release.")
        }
        let scenario = environment["RADIX_BENCH_RETENTION_SCENARIO"] ?? "single"
        let fileCount = environment["RADIX_BENCH_RETENTION_FILES"].flatMap(Int.init) ?? 1_000_000
        let path = environment["RADIX_BENCH_RETENTION_PATH"]
        let cache = CompletedScanCache(maxTotalNodeCount: 250_000)
        let navigation = WorkspaceNavigationModel()
        Self.reportRetention(phase: "initial")
        switch scenario {
        case "single":
            try await Self.retainSnapshot(fileCount: fileCount, path: path, cache: cache, scenario: scenario)
        case "repeat":
            for iteration in 0..<3 {
                try await Self.retainSnapshot(fileCount: fileCount, path: path, cache: cache, scenario: scenario, iteration: iteration)
                Self.reportRetention(phase: "released_\(iteration)")
            }
        case "cache":
            for iteration in 0..<3 {
                try await Self.retainSnapshot(fileCount: fileCount, path: path, cache: cache, scenario: scenario, iteration: iteration)
                await cache.waitForPendingReleases()
                withExtendedLifetime(cache) {
                    Self.reportRetention(phase: "cache_only_\(iteration)")
                }
            }
        case "scope":
            try await Self.retainSnapshot(fileCount: fileCount, path: path, cache: cache, scenario: scenario)
            withExtendedLifetime(cache) {
                Self.reportRetention(phase: "scope_only")
            }
        case "navigation":
            try await Self.retainSnapshot(fileCount: fileCount, path: path, cache: cache, scenario: scenario, navigation: navigation)
            Self.reportRetention(phase: "navigation_and_cache")
        default:
            XCTFail("Unknown retention scenario: \(scenario)")
        }
        let clearStartedAt = ContinuousClock.now
        cache.removeAll()
        Self.reportRetention(phase: "cache_cleared", seconds: BenchmarkSupport.durationSeconds(clearStartedAt.duration(to: .now)))
        let navigationClearStartedAt = ContinuousClock.now
        navigation.updateScanContext(snapshot: nil)
        Self.reportRetention(phase: "released", seconds: BenchmarkSupport.durationSeconds(navigationClearStartedAt.duration(to: .now)))
        await cache.waitForPendingReleases()
        try await Task.sleep(for: .milliseconds(100))
        Self.reportRetention(phase: "settled")
        let relievedBytes = malloc_zone_pressure_relief(nil, 0)
        Self.reportRetention(phase: "allocator_relief", extra: "relieved_bytes=\(relievedBytes)")
        if let pauseSeconds = environment["RADIX_BENCH_RETENTION_PAUSE_SECONDS"].flatMap(Int.init), pauseSeconds > 0 {
            // Allow a separate vmmap capture after every snapshot owner releases.
            fflush(nil)
            try await Task.sleep(for: .seconds(pauseSeconds))
        }
    }

    // The separate frame and explicit lifetimes keep ownership checkpoints
    // meaningful in optimized builds without adding a production retention hook.
    @inline(never)
    @MainActor
    private static func retainSnapshot(
        fileCount: Int,
        path: String?,
        cache: CompletedScanCache,
        scenario: String,
        iteration: Int = 0,
        navigation: WorkspaceNavigationModel? = nil
    ) async throws {
        let snapshot: ScanSnapshot
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.includeHiddenFiles = iteration.isMultiple(of: 2)
        options.treatPackagesAsDirectories = iteration > 1
        let startedAt = ContinuousClock.now
        if let path {
            snapshot = try await scanRetentionFixture(path: path, options: options)
        } else {
            snapshot = autoreleasepool {
                makeFlatSnapshot(fileCount: fileCount, rootID: "/retention/scan-\(iteration)")
            }
        }
        withExtendedLifetime(snapshot) {
            reportRetention(phase: "retained_\(iteration)", seconds: BenchmarkSupport.durationSeconds(startedAt.duration(to: .now)), extra: "nodes=\(snapshot.treeStore.nodeCount)")
        }
        if scenario == "cache" {
            let storeStartedAt = ContinuousClock.now
            cache.store(snapshot, for: ScanCacheKey(target: snapshot.target, options: options))
            reportRetention(phase: "stored_\(iteration)", seconds: BenchmarkSupport.durationSeconds(storeStartedAt.duration(to: .now)))
        } else if scenario == "scope" || scenario == "navigation" {
            let child = try XCTUnwrap(snapshot.treeStore.childrenPrefix(of: snapshot.root.id, maxCount: 1).first)
            let scope = try XCTUnwrap(snapshot.scoped(to: ScanTarget(url: child.url)))
            if let navigation {
                cache.store(snapshot, for: ScanCacheKey(target: snapshot.target, options: options))
                navigation.updateScanContext(snapshot: snapshot)
                navigation.updateScanContext(snapshot: scope)
                XCTAssertEqual(navigation.state.fileTreeStore?.nodeCount, scope.treeStore.nodeCount)
            } else {
                cache.store(scope, for: ScanCacheKey(target: scope.target, options: options))
            }
            withExtendedLifetime(snapshot) {
                reportRetention(phase: "parent_and_scope", extra: "scope_nodes=\(scope.treeStore.nodeCount)")
            }
        }
        withExtendedLifetime(snapshot) {}
    }

    @inline(never)
    private static func scanRetentionFixture(path: String, options: ScanOptions) async throws -> ScanSnapshot {
        var completed: ScanSnapshot?
        for try await event in ScanEngine().scan(
            target: ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)),
            options: options
        ) {
            if case .finished(let snapshot) = event {
                completed = snapshot
            }
        }
        let snapshot = try XCTUnwrap(completed)
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertTrue(snapshot.scanWarnings.isEmpty)
        return snapshot
    }

    private static func reportRetention(phase: String, seconds: Double = 0, extra: String = "") {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        var vmInfo = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        print(
            "RADIX_BENCH_RETENTION phase=\(phase) seconds=\(BenchmarkSupport.format(seconds)) main_thread=\(Thread.isMainThread ? 1 : 0) pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "rss=\(BenchmarkMemorySampler.currentResidentMemoryBytes()) "
                + "peak_rss=\(BenchmarkSupport.peakResidentBytes()) "
                + "footprint=\(vmInfo.phys_footprint) reusable=\(vmInfo.reusable) "
                + "malloc_in_use=\(statistics.size_in_use) malloc_reserved=\(statistics.size_allocated) "
                + "malloc_blocks=\(statistics.blocks_in_use) \(extra)"
        )
    }

    private static func makeFlatSnapshot(fileCount: Int, rootID: String = "/audit") -> ScanSnapshot {
        let allocatedSize = Int64(fileCount) * Int64(fileCount + 1) / 2
        let root = ChartResponsivenessBenchmarkSupport.node(
            id: rootID, name: "audit", isDirectory: true,
            allocatedSize: allocatedSize, descendantFileCount: fileCount
        )
        var nodes = [root]
        nodes.reserveCapacity(fileCount + 1)
        var indexByNodeID = [rootID: FileTreeNodeIndex(rawValue: 0)]
        indexByNodeID.reserveCapacity(fileCount + 1)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(fileCount)
        for offset in 0..<fileCount {
            let name = "item-\(offset).dat"
            let id = rootID + "/" + name
            let index = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartResponsivenessBenchmarkSupport.node(
                id: id, name: name, isDirectory: false,
                allocatedSize: Int64(fileCount - offset), descendantFileCount: 1
            ))
            indexByNodeID[id] = index
            childIndices.append(index)
        }
        var parentIndices = Array(repeating: UInt32(0), count: nodes.count)
        parentIndices[0] = UInt32.max
        var childSpans = Array(repeating: FileTreeChildSpan(), count: nodes.count)
        childSpans[0] = FileTreeChildSpan(start: 0, count: UInt32(fileCount))
        let store = FileTreeStore(
            verifiedRootIndex: FileTreeNodeIndex(rawValue: 0),
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: [FileTreeNodeIndex(rawValue: 0)] + childIndices,
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: allocatedSize, totalLogicalSize: allocatedSize,
                fileCount: fileCount, directoryCount: 1,
                accessibleItemCount: nodes.count, inaccessibleItemCount: 0
            )
        )
        return makeTestSnapshot(root: root, store: store)
    }

    private static func report(phase: String, count: Int, seconds: Double, extra: String = "") {
        BenchmarkSupport.report(
            prefix: "RADIX_BENCH_AUDIT_RESULT", phase: phase, seconds: seconds,
            count: count, peakRSS: BenchmarkSupport.peakResidentBytes(), extra: extra
        )
    }
}
