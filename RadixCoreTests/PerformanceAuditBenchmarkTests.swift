import Foundation
import XCTest
@testable import RadixCore

/// Opt-in measurements for the performance audit; elapsed times are never test assertions.
final class PerformanceAuditBenchmarkTests: XCTestCase {
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
        let startedAt = ContinuousClock.now
        for try await event in engine.scan(target: target, options: options) {
            switch event {
            case .progress:
                progressEvents += 1
            case .finished(let snapshot):
                finished = snapshot
            case .warning, .executionMode:
                break
            }
        }
        let elapsed = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        let snapshot = try XCTUnwrap(finished)
        print(
            "RADIX_BENCH_AUDIT_FILESYSTEM mode=\(usesFoundation ? "foundation" : "native") "
                + "seconds=\(BenchmarkSupport.format(elapsed)) "
                + "files=\(snapshot.aggregateStats.fileCount) folders=\(snapshot.aggregateStats.directoryCount) "
                + "nodes=\(snapshot.treeStore.nodeCount) progress_events=\(progressEvents) "
                + "warnings=\(snapshot.scanWarnings.count) peak_rss=\(BenchmarkSupport.peakResidentBytes())"
        )
    }

    private static func makeFlatSnapshot(fileCount: Int) -> ScanSnapshot {
        let rootID = "/audit"
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
