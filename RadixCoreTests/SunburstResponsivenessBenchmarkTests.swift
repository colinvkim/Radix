import CoreGraphics
import Foundation
import XCTest
@testable import RadixCore

private typealias ChartBenchmarkSupport = ChartResponsivenessBenchmarkSupport

@MainActor
final class SunburstResponsivenessBenchmarkTests: XCTestCase {
    func testLargeScanSunburstResponsivenessBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["RADIX_BENCH_SUNBURST"] == "1" else {
            throw XCTSkip(
                "Set RADIX_BENCH_SUNBURST=1 to run the large-scan Sunburst benchmark."
            )
        }

        let denseFileCount = 1_000_000
        let branchCount = 120
        let renderedDepth = 10
        let sampleCount = 3
        let hitTestIterationCount = 100_000
        let overlayIterationCount = 20_000
        let keyboardIterationCount = 20_000
        let chartSize = CGSize(width: 1_200, height: 1_200)

        let initialPeakRSS = BenchmarkSupport.peakResidentBytes()
        let fixtureMeasurement = BenchmarkSupport.measure {
            Self.makeDenseFixture(fileCount: denseFileCount)
        }
        let denseFixture = fixtureMeasurement.value
        XCTAssertEqual(denseFixture.store.nodeCount, denseFileCount + 2)
        Self.report(
            phase: "fixture",
            seconds: fixtureMeasurement.seconds,
            count: denseFixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: BenchmarkSupport.peakResidentBytes()))"
        )

        let denseDiskMapStore = DiskMapTreeStore(denseFixture.store)
        var largeLayoutSamples: [ChartBenchmarkSupport.LayoutSample] = []
        largeLayoutSamples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let measurement = try BenchmarkSupport.measure {
                try SunburstLayout.segments(
                    in: denseDiskMapStore,
                    rootID: denseFixture.store.rootID,
                    depthLimit: 2,
                    cancellationCheck: {}
                )
            }
            largeLayoutSamples.append(ChartBenchmarkSupport.LayoutSample(
                seconds: measurement.seconds,
                segmentCount: measurement.value.count,
                fingerprint: Self.segmentFingerprint(measurement.value)
            ))
        }
        let expectedLargeCount = try XCTUnwrap(largeLayoutSamples.first?.segmentCount)
        let expectedLargeFingerprint = try XCTUnwrap(largeLayoutSamples.first?.fingerprint)
        XCTAssertTrue(largeLayoutSamples.allSatisfy {
            $0.segmentCount == expectedLargeCount
                && $0.fingerprint == expectedLargeFingerprint
        })
        let largeLayoutMedian = try XCTUnwrap(
            BenchmarkSupport.median(largeLayoutSamples.map(\.seconds))
        )
        Self.report(
            phase: "layout_large_scan",
            seconds: largeLayoutMedian,
            count: expectedLargeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "samples=\(largeLayoutSamples.map { BenchmarkSupport.format($0.seconds) }.joined(separator: ",")) "
                + "fingerprint=\(expectedLargeFingerprint)"
        )

        let denseLayoutMeasurement = try BenchmarkSupport.measure {
            try SunburstLayout.segments(
                in: denseDiskMapStore,
                rootID: denseFixture.denseDirectoryID,
                depthLimit: 1,
                cancellationCheck: {}
            )
        }
        let denseSegments = denseLayoutMeasurement.value
        XCTAssertEqual(denseSegments.count, 1)
        XCTAssertTrue(try XCTUnwrap(denseSegments.first).isAggregate)
        let denseFingerprint = Self.segmentFingerprint(denseSegments)
        Self.report(
            phase: "layout_dense_root",
            seconds: denseLayoutMeasurement.seconds,
            count: denseFileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(denseSegments.count) fingerprint=\(denseFingerprint)"
        )

        let interactionFixture = Self.makeInteractionFixture(
            branchCount: branchCount,
            renderedDepth: renderedDepth
        )
        let interactionDiskMapStore = DiskMapTreeStore(interactionFixture.store)
        let interactionLayoutMeasurement = try BenchmarkSupport.measure {
            try SunburstLayout.segments(
                in: interactionDiskMapStore,
                rootID: interactionFixture.store.rootID,
                depthLimit: renderedDepth,
                cancellationCheck: {}
            )
        }
        let interactionSegments = interactionLayoutMeasurement.value
        XCTAssertEqual(interactionSegments.count, branchCount * renderedDepth)
        let interactionFingerprint = Self.segmentFingerprint(interactionSegments)
        Self.report(
            phase: "layout_interaction_geometry",
            seconds: interactionLayoutMeasurement.seconds,
            count: interactionSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "fingerprint=\(interactionFingerprint)"
        )

        let publicationModel = SunburstChartModel(
            layoutService: PrecomputedSunburstLayoutService(segments: interactionSegments)
        )
        let publicationMeasurement = await ChartBenchmarkSupport.measureAsync {
            await publicationModel.loadLayout(
                treeStore: interactionDiskMapStore,
                rootID: interactionFixture.store.rootID,
                depthLimit: renderedDepth,
                layoutID: "interaction-publication"
            )
        }
        XCTAssertTrue(publicationMeasurement.value)
        XCTAssertEqual(
            Self.segmentFingerprint(publicationModel.renderedSegments),
            interactionFingerprint
        )
        Self.report(
            phase: "render_state_publication",
            seconds: publicationMeasurement.seconds,
            count: interactionSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let hitTestMeasurement = BenchmarkSupport.measure {
            ChartBenchmarkSupport.runHitTests(
                size: chartSize,
                iterationCount: hitTestIterationCount
            ) { point in
                publicationModel.segment(at: point, in: chartSize)?.id
            }
        }
        XCTAssertGreaterThan(hitTestMeasurement.value.selectionCount, 0)
        Self.report(
            phase: "hit_testing",
            seconds: hitTestMeasurement.seconds,
            count: hitTestIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "hits=\(hitTestMeasurement.value.selectionCount) "
                + "fingerprint=\(hitTestMeasurement.value.fingerprint)"
        )

        let overlayInputs = Self.makeOverlayInputs(
            rootID: interactionFixture.store.rootID,
            branchCount: min(branchCount, 64),
            renderedDepth: renderedDepth
        )
        let coldOverlayMeasurement = BenchmarkSupport.measure {
            Self.runSelectionOverlays(
                model: publicationModel,
                inputs: overlayInputs,
                iterationCount: overlayIterationCount
            )
        }
        XCTAssertEqual(
            coldOverlayMeasurement.value.selectionCount,
            overlayIterationCount * renderedDepth
        )
        Self.report(
            phase: "selection_overlay_alternating",
            seconds: coldOverlayMeasurement.seconds,
            count: overlayIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(coldOverlayMeasurement.value.selectionCount) "
                + "fingerprint=\(coldOverlayMeasurement.value.fingerprint)"
        )

        let cacheHitOverlayMeasurement = try BenchmarkSupport.measure {
            Self.runSelectionOverlays(
                model: publicationModel,
                inputs: [try XCTUnwrap(overlayInputs.first)],
                iterationCount: overlayIterationCount
            )
        }
        XCTAssertEqual(
            cacheHitOverlayMeasurement.value.selectionCount,
            overlayIterationCount * renderedDepth
        )
        Self.report(
            phase: "selection_overlay_same_selection",
            seconds: cacheHitOverlayMeasurement.seconds,
            count: overlayIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(cacheHitOverlayMeasurement.value.selectionCount) "
                + "fingerprint=\(cacheHitOverlayMeasurement.value.fingerprint)"
        )

        let keyboardMeasurement = BenchmarkSupport.measure {
            Self.runKeyboardSelection(
                model: publicationModel,
                iterationCount: keyboardIterationCount
            )
        }
        XCTAssertEqual(keyboardMeasurement.value.selectionCount, keyboardIterationCount)
        Self.report(
            phase: "keyboard_selection",
            seconds: keyboardMeasurement.seconds,
            count: keyboardIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "selections=\(keyboardMeasurement.value.selectionCount) "
                + "fingerprint=\(keyboardMeasurement.value.fingerprint)"
        )

        let cancellationMeasurement = try await ChartBenchmarkSupport.measureLayoutCancellation(
            baselineLayoutSeconds: denseLayoutMeasurement.seconds
        ) {
            _ = try SunburstLayout.segments(
                in: denseDiskMapStore,
                rootID: denseFixture.denseDirectoryID,
                depthLimit: 1,
                cancellationCheck: Task.checkCancellation
            )
        }
        XCTAssertTrue(
            cancellationMeasurement.wasCancelled
                || cancellationMeasurement.completedBeforeCancellation,
            "Large layout returned normally after cancellation was requested."
        )
        Self.report(
            phase: "cancel_layout",
            seconds: cancellationMeasurement.seconds,
            count: denseFileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(cancellationMeasurement.wasCancelled) "
                + "completed_before_cancel=\(cancellationMeasurement.completedBeforeCancellation)"
        )

        let rapidChangeMeasurement = try await Self.measureRapidRootAndDepthChanges(
            fixture: denseFixture,
            diskMapStore: denseDiskMapStore
        )
        XCTAssertEqual(rapidChangeMeasurement.appliedCount, 1)
        XCTAssertEqual(rapidChangeMeasurement.completedCount, 1)
        XCTAssertEqual(
            rapidChangeMeasurement.cancelledCount,
            rapidChangeMeasurement.requestCount - 1
        )
        XCTAssertEqual(rapidChangeMeasurement.renderedLayoutID, "root-depth-final")
        XCTAssertEqual(rapidChangeMeasurement.segmentCount, denseSegments.count)
        XCTAssertEqual(rapidChangeMeasurement.fingerprint, denseFingerprint)
        Self.report(
            phase: "rapid_root_depth_changes",
            seconds: rapidChangeMeasurement.latestRequestSeconds,
            count: rapidChangeMeasurement.requestCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "total_seconds=\(BenchmarkSupport.format(rapidChangeMeasurement.totalSeconds)) "
                + "applied=\(rapidChangeMeasurement.appliedCount) "
                + "cancelled=\(rapidChangeMeasurement.cancelledCount) "
                + "fingerprint=\(rapidChangeMeasurement.fingerprint)"
        )

        Self.report(
            phase: "suite_peak_rss",
            seconds: 0,
            count: denseFixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: BenchmarkSupport.peakResidentBytes()))"
        )
    }

    private static func measureRapidRootAndDepthChanges(
        fixture: SunburstDenseBenchmarkFixture,
        diskMapStore: DiskMapTreeStore
    ) async throws -> ChartBenchmarkSupport.RequestSequenceMeasurement {
        let requests = [
            SunburstBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 2,
                layoutID: "root-depth-1"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                layoutID: "root-depth-2"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 2,
                layoutID: "root-depth-3"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                layoutID: "root-depth-final"
            ),
        ]
        let probe = ChartBenchmarkSupport.LayoutProbe()
        let service = InstrumentedSunburstLayoutService(
            probe: probe,
            suspendedRequestCount: requests.count - 1
        )
        let model = SunburstChartModel(layoutService: service)
        return try await ChartBenchmarkSupport.measureRequestSequence(
            requests,
            probe: probe,
            chartName: "Sunburst",
            loadLayout: { request in
                await model.loadLayout(
                    treeStore: diskMapStore,
                    rootID: request.rootID,
                    depthLimit: request.depthLimit,
                    layoutID: request.layoutID
                )
            },
            renderedLayout: {
                (
                    model.layoutReadiness.renderedLayoutID,
                    model.renderedSegments.count,
                    Self.segmentFingerprint(model.renderedSegments)
                )
            }
        )
    }

    private static func runSelectionOverlays(
        model: SunburstChartModel,
        inputs: [OverlayInput],
        iterationCount: Int
    ) -> ChartBenchmarkSupport.InteractionMeasurement {
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis
        var segmentCount = 0

        for offset in 0..<iterationCount {
            let input = inputs[offset % inputs.count]
            let overlays = model.selectionOverlaySegments(
                selectedNodeID: input.selectedNodeID,
                selectedAncestorIDs: input.ancestorIDs
            )
            segmentCount += overlays.count
            for overlay in overlays {
                ChartBenchmarkSupport.hash(overlay.id, into: &fingerprint)
                switch overlay.role {
                case .ancestor:
                    ChartBenchmarkSupport.hash(0, into: &fingerprint)
                case .selected:
                    ChartBenchmarkSupport.hash(1, into: &fingerprint)
                }
            }
        }
        return ChartBenchmarkSupport.InteractionMeasurement(
            selectionCount: segmentCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func runKeyboardSelection(
        model: SunburstChartModel,
        iterationCount: Int
    ) -> ChartBenchmarkSupport.InteractionMeasurement {
        let directions: [ChartSpatialSelectionDirection] = [.right, .down, .left, .up]
        var selectedNodeID: String?
        var selectionCount = 0
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis

        for offset in 0..<iterationCount {
            let segment = model.keyboardSelection(
                from: selectedNodeID,
                moving: directions[offset % directions.count]
            )
            selectedNodeID = segment?.nodeID
            if let selectedNodeID {
                selectionCount += 1
                ChartBenchmarkSupport.hash(selectedNodeID, into: &fingerprint)
            } else {
                ChartBenchmarkSupport.hash(UInt64.max, into: &fingerprint)
            }
        }
        return ChartBenchmarkSupport.InteractionMeasurement(
            selectionCount: selectionCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func makeDenseFixture(
        fileCount: Int
    ) -> SunburstDenseBenchmarkFixture {
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let denseIndex = FileTreeNodeIndex(rawValue: 1)
        let rootID = "/sunburst-benchmark"
        let denseDirectoryID = rootID + "/dense"
        var nodes = [
            ChartBenchmarkSupport.node(
                id: rootID,
                name: "sunburst-benchmark",
                isDirectory: true,
                allocatedSize: Int64(fileCount),
                descendantFileCount: fileCount
            ),
            ChartBenchmarkSupport.node(
                id: denseDirectoryID,
                name: "dense",
                isDirectory: true,
                allocatedSize: Int64(fileCount),
                descendantFileCount: fileCount
            ),
        ]
        nodes.reserveCapacity(fileCount + 2)
        var childIndicesByIndex = Array(
            repeating: [FileTreeNodeIndex](),
            count: fileCount + 2
        )
        var denseChildren: [FileTreeNodeIndex] = []
        denseChildren.reserveCapacity(fileCount)
        var parentIndices = Array<FileTreeNodeIndex?>(
            repeating: nil,
            count: fileCount + 2
        )
        parentIndices[Int(denseIndex.rawValue)] = rootIndex

        for fileOffset in 0..<fileCount {
            let fileID = String(format: "%@/item-%07d.dat", denseDirectoryID, fileOffset)
            let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartBenchmarkSupport.node(
                id: fileID,
                name: String(format: "item-%07d.dat", fileOffset),
                isDirectory: false,
                allocatedSize: 1,
                descendantFileCount: 1
            ))
            denseChildren.append(fileIndex)
            parentIndices[Int(fileIndex.rawValue)] = denseIndex
        }
        childIndicesByIndex[Int(rootIndex.rawValue)] = [denseIndex]
        childIndicesByIndex[Int(denseIndex.rawValue)] = denseChildren

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map {
                FileTreeNodeIndex(rawValue: UInt32($0))
            },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(fileCount),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: 2,
                accessibleItemCount: fileCount + 2,
                inaccessibleItemCount: 0
            )
        )
        return SunburstDenseBenchmarkFixture(
            store: store,
            denseDirectoryID: denseDirectoryID
        )
    }

    private static func makeInteractionFixture(
        branchCount: Int,
        renderedDepth: Int
    ) -> SunburstInteractionBenchmarkFixture {
        let rootID = "/sunburst-interaction"
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let nodeCount = 1 + (branchCount * renderedDepth)
        var nodes = [ChartBenchmarkSupport.node(
            id: rootID,
            name: "sunburst-interaction",
            isDirectory: true,
            allocatedSize: Int64(branchCount),
            descendantFileCount: branchCount
        )]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(
            repeating: [FileTreeNodeIndex](),
            count: nodeCount
        )
        var parentIndices = Array<FileTreeNodeIndex?>(
            repeating: nil,
            count: nodeCount
        )
        childIndicesByIndex[Int(rootIndex.rawValue)].reserveCapacity(branchCount)

        for branchOffset in 0..<branchCount {
            var parentIndex = rootIndex
            for depth in 0..<renderedDepth {
                let id = interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: depth
                )
                let index = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                nodes.append(ChartBenchmarkSupport.node(
                    id: id,
                    name: depth == 0
                        ? String(format: "branch-%03d", branchOffset)
                        : String(format: "level-%02d", depth),
                    isDirectory: depth + 1 < renderedDepth,
                    allocatedSize: 1,
                    descendantFileCount: 1
                ))
                parentIndices[Int(index.rawValue)] = parentIndex
                childIndicesByIndex[Int(parentIndex.rawValue)].append(index)
                parentIndex = index
            }
        }

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map {
                FileTreeNodeIndex(rawValue: UInt32($0))
            },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(branchCount),
                totalLogicalSize: Int64(branchCount),
                fileCount: branchCount,
                directoryCount: 1 + (branchCount * max(renderedDepth - 1, 0)),
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        return SunburstInteractionBenchmarkFixture(store: store)
    }

    private static func makeOverlayInputs(
        rootID: String,
        branchCount: Int,
        renderedDepth: Int
    ) -> [OverlayInput] {
        (0..<branchCount).map { branchOffset in
            let ancestorIDs = Set((0..<(renderedDepth - 1)).map { depth in
                interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: depth
                )
            })
            return OverlayInput(
                selectedNodeID: interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: renderedDepth - 1
                ),
                ancestorIDs: ancestorIDs
            )
        }
    }

    private static func interactionNodeID(
        rootID: String,
        branchOffset: Int,
        depth: Int
    ) -> String {
        let branchID = String(format: "%@/branch-%03d", rootID, branchOffset)
        guard depth > 0 else { return branchID }
        return (1...depth).reduce(branchID) { path, level in
            path + String(format: "/level-%02d", level)
        }
    }

    private static func segmentFingerprint(_ segments: [SunburstSegment]) -> String {
        var hash = ChartBenchmarkSupport.fnvOffsetBasis
        for segment in segments {
            ChartBenchmarkSupport.hash(segment.id, into: &hash)
            ChartBenchmarkSupport.hash(segment.nodeID ?? "<aggregate>", into: &hash)
            ChartBenchmarkSupport.hash(segment.label, into: &hash)
            ChartBenchmarkSupport.hash(segment.startAngle.radians.bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(segment.endAngle.radians.bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.innerRadius).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.outerRadius).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.depth)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: segment.totalSize), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(segment.isAggregate ? 1 : 0), into: &hash)
            ChartBenchmarkSupport.hash(segment.colorToken.branchID, into: &hash)
            ChartBenchmarkSupport.hash(segment.colorToken.localID, into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.branchIndex)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.branchCount)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.siblingIndex)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.siblingCount)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.depth)), into: &hash)
            switch segment.colorToken.role {
            case .normal:
                ChartBenchmarkSupport.hash(0, into: &hash)
            case .aggregate:
                ChartBenchmarkSupport.hash(1, into: &hash)
            case .freeSpace:
                ChartBenchmarkSupport.hash(2, into: &hash)
            }
        }
        return String(hash, radix: 16)
    }

    private static func report(
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        BenchmarkSupport.report(
            prefix: "RADIX_SUNBURST_BENCH_RESULT",
            phase: phase,
            seconds: seconds,
            count: count,
            peakRSS: peakRSS,
            extra: extra
        )
    }
}

private actor InstrumentedSunburstLayoutService: SunburstLayouting {
    let probe: ChartBenchmarkSupport.LayoutProbe
    let suspendedRequestCount: Int

    init(
        probe: ChartBenchmarkSupport.LayoutProbe,
        suspendedRequestCount: Int
    ) {
        self.probe = probe
        self.suspendedRequestCount = suspendedRequestCount
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        let requestNumber = await probe.recordStarted()
        do {
            if requestNumber <= suspendedRequestCount {
                try await Task.sleep(for: .seconds(5))
                throw ChartBenchmarkSupport.TimeoutError(
                    message: "Expected Sunburst request \(requestNumber) to be superseded."
                )
            }
            let segments = try SunburstLayout.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                cancellationCheck: Task.checkCancellation
            )
            await probe.recordCompleted()
            return segments
        } catch is CancellationError {
            await probe.recordCancelled()
            throw CancellationError()
        }
    }
}

private struct PrecomputedSunburstLayoutService: SunburstLayouting {
    let segments: [SunburstSegment]

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        segments
    }
}

private struct SunburstDenseBenchmarkFixture: Sendable {
    let store: FileTreeStore
    let denseDirectoryID: String
}

private struct SunburstInteractionBenchmarkFixture: Sendable {
    let store: FileTreeStore
}

private struct SunburstBenchmarkRequest {
    let rootID: String
    let depthLimit: Int
    let layoutID: String
}

private struct OverlayInput {
    let selectedNodeID: String
    let ancestorIDs: Set<String>
}
