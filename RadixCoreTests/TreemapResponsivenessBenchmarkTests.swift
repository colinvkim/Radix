import CoreGraphics
import Foundation
import XCTest
@testable import RadixCore

private typealias ChartBenchmarkSupport = ChartResponsivenessBenchmarkSupport

@MainActor
final class TreemapResponsivenessBenchmarkTests: XCTestCase {
    func testLargeScanTreemapResponsivenessBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_TREEMAP"] == "1" else {
            throw XCTSkip(
                "Set RADIX_BENCH_TREEMAP=1 to run the large-scan Treemap benchmark."
            )
        }

        let directoryCount = 200
        let filesPerDirectory = 5_000
        let denseFileCount = 8_000
        let flatFileCount = 50_000
        let sampleCount = 3
        let hitTestIterationCount = 100_000
        let keyboardIterationCount = 1_000

        let largeLayoutSize = CGSize(width: 1_600, height: 1_000)
        let alternateLayoutSize = CGSize(width: 1_024, height: 1_320)
        let initialPeakRSS = BenchmarkSupport.peakResidentBytes()
        let fixtureMeasurement = BenchmarkSupport.measure {
            Self.makeFixture(
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory,
                denseFileCount: denseFileCount
            )
        }
        let fixture = fixtureMeasurement.value
        let fixturePeakRSS = BenchmarkSupport.peakResidentBytes()

        XCTAssertEqual(
            fixture.store.nodeCount,
            1 + directoryCount + (directoryCount * filesPerDirectory) + 1 + denseFileCount
        )
        Self.report(
            phase: "fixture",
            seconds: fixtureMeasurement.seconds,
            count: fixture.store.nodeCount,
            peakRSS: fixturePeakRSS,
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: fixturePeakRSS))"
        )

        let diskMapStore = DiskMapTreeStore(fixture.store)
        var largeLayoutSamples: [ChartBenchmarkSupport.LayoutSample] = []
        largeLayoutSamples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let measurement = try BenchmarkSupport.measure {
                try TreemapLayout.segments(
                    in: diskMapStore,
                    rootID: fixture.store.rootID,
                    depthLimit: 3,
                    size: largeLayoutSize,
                    cancellationCheck: {}
                )
            }
            largeLayoutSamples.append(ChartBenchmarkSupport.LayoutSample(
                seconds: measurement.seconds,
                segmentCount: measurement.value.count,
                fingerprint: Self.segmentFingerprint(measurement.value)
            ))
        }
        let expectedLargeSegmentCount = try XCTUnwrap(largeLayoutSamples.first?.segmentCount)
        let expectedLargeFingerprint = try XCTUnwrap(largeLayoutSamples.first?.fingerprint)
        XCTAssertTrue(largeLayoutSamples.allSatisfy {
            $0.segmentCount == expectedLargeSegmentCount
                && $0.fingerprint == expectedLargeFingerprint
        })
        let largeLayoutMedian = try XCTUnwrap(
            BenchmarkSupport.median(largeLayoutSamples.map(\.seconds))
        )
        Self.report(
            phase: "layout_large_scan",
            seconds: largeLayoutMedian,
            count: expectedLargeSegmentCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "samples=\(largeLayoutSamples.map { BenchmarkSupport.format($0.seconds) }.joined(separator: ",")) "
                + "fingerprint=\(expectedLargeFingerprint)"
        )

        let denseLayoutMeasurement = try BenchmarkSupport.measure {
            try TreemapLayout.segments(
                in: diskMapStore,
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                size: largeLayoutSize,
                cancellationCheck: {}
            )
        }
        let denseSegments = denseLayoutMeasurement.value
        XCTAssertEqual(denseSegments.count, denseFileCount)
        let denseFingerprint = Self.segmentFingerprint(denseSegments)
        Self.report(
            phase: "layout_dense_folder",
            seconds: denseLayoutMeasurement.seconds,
            count: denseSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "fingerprint=\(denseFingerprint)"
        )

        let flatLayoutSamples = try Self.measureFlatHighFanoutLayout(
            fileCount: flatFileCount,
            size: largeLayoutSize,
            sampleCount: sampleCount
        )
        let expectedFlatSegmentCount = try XCTUnwrap(flatLayoutSamples.first?.segmentCount)
        let expectedFlatFingerprint = try XCTUnwrap(flatLayoutSamples.first?.fingerprint)
        XCTAssertTrue(flatLayoutSamples.allSatisfy {
            $0.segmentCount == expectedFlatSegmentCount
                && $0.fingerprint == expectedFlatFingerprint
        })
        Self.report(
            phase: "layout_flat_high_fanout",
            seconds: try XCTUnwrap(
                BenchmarkSupport.median(flatLayoutSamples.map(\.seconds))
            ),
            count: flatFileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(expectedFlatSegmentCount) "
                + "samples=\(flatLayoutSamples.map { BenchmarkSupport.format($0.seconds) }.joined(separator: ",")) "
                + "fingerprint=\(expectedFlatFingerprint)"
        )

        let publicationModel = TreemapChartModel(
            layoutService: PrecomputedTreemapLayoutService(segments: denseSegments)
        )
        let publicationMeasurement = await ChartBenchmarkSupport.measureAsync {
            await publicationModel.loadLayout(
                treeStore: diskMapStore,
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                size: largeLayoutSize,
                layoutID: "dense-publication"
            )
        }
        XCTAssertTrue(publicationMeasurement.value)
        XCTAssertEqual(publicationModel.renderedSegments.count, denseFileCount)
        Self.report(
            phase: "render_state_publication",
            seconds: publicationMeasurement.seconds,
            count: denseSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let hitTestMeasurement = BenchmarkSupport.measure {
            ChartBenchmarkSupport.runHitTests(
                size: largeLayoutSize,
                iterationCount: hitTestIterationCount
            ) { point in
                publicationModel.segment(at: point, in: largeLayoutSize)?.id
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

        let wideKeyboardMeasurement = BenchmarkSupport.measure {
            Self.runKeyboardSelection(
                model: publicationModel,
                size: largeLayoutSize,
                iterationCount: keyboardIterationCount
            )
        }
        XCTAssertGreaterThan(wideKeyboardMeasurement.value.selectionCount, 0)
        Self.report(
            phase: "keyboard_selection_wide",
            seconds: wideKeyboardMeasurement.seconds,
            count: keyboardIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "selections=\(wideKeyboardMeasurement.value.selectionCount) "
                + "fingerprint=\(wideKeyboardMeasurement.value.fingerprint)"
        )

        let tallKeyboardMeasurement = BenchmarkSupport.measure {
            Self.runKeyboardSelection(
                model: publicationModel,
                size: alternateLayoutSize,
                iterationCount: keyboardIterationCount
            )
        }
        XCTAssertGreaterThan(tallKeyboardMeasurement.value.selectionCount, 0)
        Self.report(
            phase: "keyboard_selection_tall",
            seconds: tallKeyboardMeasurement.seconds,
            count: keyboardIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "selections=\(tallKeyboardMeasurement.value.selectionCount) "
                + "fingerprint=\(tallKeyboardMeasurement.value.fingerprint)"
        )

        let cancellationMeasurement = try await ChartBenchmarkSupport.measureLayoutCancellation(
            baselineLayoutSeconds: largeLayoutMedian
        ) {
            _ = try TreemapLayout.segments(
                in: diskMapStore,
                rootID: fixture.store.rootID,
                depthLimit: 3,
                size: largeLayoutSize,
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
            count: fixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(cancellationMeasurement.wasCancelled) "
                + "completed_before_cancel=\(cancellationMeasurement.completedBeforeCancellation)"
        )

        let resizeMeasurement = try await Self.measureRapidResize(
            fixture: fixture,
            diskMapStore: diskMapStore,
            baseSize: largeLayoutSize
        )
        XCTAssertEqual(resizeMeasurement.appliedCount, 1)
        XCTAssertEqual(resizeMeasurement.completedCount, 1)
        XCTAssertEqual(resizeMeasurement.cancelledCount, resizeMeasurement.requestCount - 1)
        Self.report(
            phase: "rapid_resize",
            seconds: resizeMeasurement.latestRequestSeconds,
            count: resizeMeasurement.requestCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "total_seconds=\(BenchmarkSupport.format(resizeMeasurement.totalSeconds)) "
                + "applied=\(resizeMeasurement.appliedCount) "
                + "cancelled=\(resizeMeasurement.cancelledCount) "
                + "fingerprint=\(resizeMeasurement.fingerprint)"
        )

        let navigationMeasurement = try await Self.measureRapidNavigation(
            fixture: fixture,
            diskMapStore: diskMapStore,
            size: largeLayoutSize
        )
        XCTAssertEqual(navigationMeasurement.appliedCount, 1)
        XCTAssertEqual(navigationMeasurement.completedCount, 1)
        XCTAssertEqual(
            navigationMeasurement.cancelledCount,
            navigationMeasurement.requestCount - 1
        )
        XCTAssertEqual(navigationMeasurement.renderedLayoutID, "navigation-final")
        XCTAssertEqual(navigationMeasurement.segmentCount, denseFileCount)
        XCTAssertEqual(navigationMeasurement.fingerprint, denseFingerprint)
        Self.report(
            phase: "rapid_navigation",
            seconds: navigationMeasurement.latestRequestSeconds,
            count: navigationMeasurement.requestCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "total_seconds=\(BenchmarkSupport.format(navigationMeasurement.totalSeconds)) "
                + "applied=\(navigationMeasurement.appliedCount) "
                + "cancelled=\(navigationMeasurement.cancelledCount) "
                + "fingerprint=\(navigationMeasurement.fingerprint)"
        )

        Self.report(
            phase: "suite_peak_rss",
            seconds: 0,
            count: fixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: BenchmarkSupport.peakResidentBytes()))"
        )
    }

    private static func measureRapidResize(
        fixture: TreemapBenchmarkFixture,
        diskMapStore: DiskMapTreeStore,
        baseSize: CGSize
    ) async throws -> ChartBenchmarkSupport.RequestSequenceMeasurement {
        let sizes = (0..<6).map { offset in
            CGSize(
                width: baseSize.width + CGFloat(offset * 24),
                height: baseSize.height + CGFloat((offset % 3) * 24)
            )
        }
        let requests = sizes.map { size in
            TreemapBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 3,
                size: size,
                layoutID: "resize-layout"
            )
        }
        return try await measureRequestSequence(
            requests,
            diskMapStore: diskMapStore
        )
    }

    private static func measureRapidNavigation(
        fixture: TreemapBenchmarkFixture,
        diskMapStore: DiskMapTreeStore,
        size: CGSize
    ) async throws -> ChartBenchmarkSupport.RequestSequenceMeasurement {
        let requests = [
            TreemapBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 3,
                size: size,
                layoutID: "navigation-root-1"
            ),
            TreemapBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                size: size,
                layoutID: "navigation-dense-1"
            ),
            TreemapBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 3,
                size: size,
                layoutID: "navigation-root-2"
            ),
            TreemapBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                size: size,
                layoutID: "navigation-final"
            ),
        ]
        return try await measureRequestSequence(
            requests,
            diskMapStore: diskMapStore
        )
    }

    private static func measureRequestSequence(
        _ requests: [TreemapBenchmarkRequest],
        diskMapStore: DiskMapTreeStore
    ) async throws -> ChartBenchmarkSupport.RequestSequenceMeasurement {
        let probe = ChartBenchmarkSupport.LayoutProbe()
        let service = InstrumentedTreemapLayoutService(probe: probe)
        let model = TreemapChartModel(layoutService: service)
        return try await ChartBenchmarkSupport.measureRequestSequence(
            requests,
            probe: probe,
            chartName: "Treemap",
            loadLayout: { request in
                await model.loadLayout(
                    treeStore: diskMapStore,
                    rootID: request.rootID,
                    depthLimit: request.depthLimit,
                    size: request.size,
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

    private static func runKeyboardSelection(
        model: TreemapChartModel,
        size: CGSize,
        iterationCount: Int
    ) -> ChartBenchmarkSupport.InteractionMeasurement {
        let directions: [ChartSpatialSelectionDirection] = [.right, .down, .left, .up]
        var selectedNodeID: String?
        var selectionCount = 0
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis

        for offset in 0..<iterationCount {
            let nextNodeID = model.spatialSelectionNodeID(
                from: selectedNodeID,
                moving: directions[offset % directions.count],
                in: size
            )
            selectedNodeID = nextNodeID
            if let nextNodeID {
                selectionCount += 1
                ChartBenchmarkSupport.hash(nextNodeID, into: &fingerprint)
            } else {
                ChartBenchmarkSupport.hash(UInt64.max, into: &fingerprint)
            }
        }
        return ChartBenchmarkSupport.InteractionMeasurement(
            selectionCount: selectionCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func makeFixture(
        directoryCount: Int,
        filesPerDirectory: Int,
        denseFileCount: Int
    ) -> TreemapBenchmarkFixture {
        let regularFileCount = directoryCount * filesPerDirectory
        let nodeCount = 1 + directoryCount + regularFileCount + 1 + denseFileCount
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let rootID = "/treemap-benchmark"
        let denseDirectoryID = rootID + "/dense"
        var nodes = [ChartBenchmarkSupport.node(
            id: rootID,
            name: "treemap-benchmark",
            isDirectory: true,
            allocatedSize: Int64(regularFileCount + denseFileCount),
            descendantFileCount: regularFileCount + denseFileCount
        )]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: nodeCount)
        var parentIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: nodeCount)
        var rootChildren: [FileTreeNodeIndex] = []
        rootChildren.reserveCapacity(directoryCount + 1)

        for directoryOffset in 0..<directoryCount {
            let directoryID = String(
                format: "%@/directory-%04d",
                rootID,
                directoryOffset
            )
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartBenchmarkSupport.node(
                id: directoryID,
                name: String(format: "directory-%04d", directoryOffset),
                isDirectory: true,
                allocatedSize: Int64(filesPerDirectory),
                descendantFileCount: filesPerDirectory
            ))
            parentIndices[Int(directoryIndex.rawValue)] = rootIndex
            rootChildren.append(directoryIndex)

            var directoryChildren: [FileTreeNodeIndex] = []
            directoryChildren.reserveCapacity(filesPerDirectory)
            for fileOffset in 0..<filesPerDirectory {
                let fileID = String(
                    format: "%@/item-%05d.dat",
                    directoryID,
                    fileOffset
                )
                let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                nodes.append(ChartBenchmarkSupport.node(
                    id: fileID,
                    name: String(format: "item-%05d.dat", fileOffset),
                    isDirectory: false,
                    allocatedSize: 1,
                    descendantFileCount: 1
                ))
                parentIndices[Int(fileIndex.rawValue)] = directoryIndex
                directoryChildren.append(fileIndex)
            }
            childIndicesByIndex[Int(directoryIndex.rawValue)] = directoryChildren
        }

        let denseDirectoryIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
        nodes.append(ChartBenchmarkSupport.node(
            id: denseDirectoryID,
            name: "dense",
            isDirectory: true,
            allocatedSize: Int64(denseFileCount),
            descendantFileCount: denseFileCount
        ))
        parentIndices[Int(denseDirectoryIndex.rawValue)] = rootIndex
        var denseChildren: [FileTreeNodeIndex] = []
        denseChildren.reserveCapacity(denseFileCount)
        for fileOffset in 0..<denseFileCount {
            let fileID = String(format: "%@/tile-%05d.dat", denseDirectoryID, fileOffset)
            let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartBenchmarkSupport.node(
                id: fileID,
                name: String(format: "tile-%05d.dat", fileOffset),
                isDirectory: false,
                allocatedSize: 1,
                descendantFileCount: 1
            ))
            parentIndices[Int(fileIndex.rawValue)] = denseDirectoryIndex
            denseChildren.append(fileIndex)
        }
        childIndicesByIndex[Int(denseDirectoryIndex.rawValue)] = denseChildren
        childIndicesByIndex[0] = [denseDirectoryIndex] + rootChildren

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(regularFileCount + denseFileCount),
                totalLogicalSize: Int64(regularFileCount + denseFileCount),
                fileCount: regularFileCount + denseFileCount,
                directoryCount: directoryCount + 2,
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        return TreemapBenchmarkFixture(
            store: store,
            denseDirectoryID: denseDirectoryID
        )
    }

    private static func measureFlatHighFanoutLayout(
        fileCount: Int,
        size: CGSize,
        sampleCount: Int
    ) throws -> [ChartBenchmarkSupport.LayoutSample] {
        let rootID = "/treemap-flat-benchmark"
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        var nodes = [ChartBenchmarkSupport.node(
            id: rootID,
            name: "treemap-flat-benchmark",
            isDirectory: true,
            allocatedSize: Int64(fileCount),
            descendantFileCount: fileCount
        )]
        nodes.reserveCapacity(fileCount + 1)
        var rootChildren: [FileTreeNodeIndex] = []
        rootChildren.reserveCapacity(fileCount)
        var parentIndices = Array<FileTreeNodeIndex?>(
            repeating: nil,
            count: fileCount + 1
        )

        for fileOffset in 0..<fileCount {
            let fileID = String(format: "%@/item-%05d.dat", rootID, fileOffset)
            let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartBenchmarkSupport.node(
                id: fileID,
                name: String(format: "item-%05d.dat", fileOffset),
                isDirectory: false,
                allocatedSize: 1,
                descendantFileCount: 1
            ))
            rootChildren.append(fileIndex)
            parentIndices[Int(fileIndex.rawValue)] = rootIndex
        }

        var childIndicesByIndex = Array(
            repeating: [FileTreeNodeIndex](),
            count: fileCount + 1
        )
        childIndicesByIndex[0] = rootChildren
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
                directoryCount: 1,
                accessibleItemCount: fileCount + 1,
                inaccessibleItemCount: 0
            )
        )
        let diskMapStore = DiskMapTreeStore(store)
        var samples: [ChartBenchmarkSupport.LayoutSample] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let measurement = try BenchmarkSupport.measure {
                try TreemapLayout.segments(
                    in: diskMapStore,
                    rootID: rootID,
                    depthLimit: 1,
                    size: size,
                    cancellationCheck: {}
                )
            }
            let segments = measurement.value
            XCTAssertEqual(segments.count, 1)
            let aggregate = try XCTUnwrap(segments.first)
            XCTAssertTrue(aggregate.isAggregate)
            XCTAssertNil(aggregate.nodeID)
            XCTAssertEqual(aggregate.groupedItemCount, fileCount)
            XCTAssertEqual(aggregate.totalSize, Int64(fileCount))
            samples.append(ChartBenchmarkSupport.LayoutSample(
                seconds: measurement.seconds,
                segmentCount: segments.count,
                fingerprint: Self.segmentFingerprint(segments)
            ))
        }
        return samples
    }

    private static func segmentFingerprint(_ segments: [TreemapSegment]) -> String {
        var hash = ChartBenchmarkSupport.fnvOffsetBasis
        for segment in segments {
            ChartBenchmarkSupport.hash(segment.id, into: &hash)
            ChartBenchmarkSupport.hash(segment.nodeID ?? "<aggregate>", into: &hash)
            ChartBenchmarkSupport.hash(segment.containerNodeID, into: &hash)
            ChartBenchmarkSupport.hash(segment.label, into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.depth)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: segment.totalSize), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(segment.isAggregate ? 1 : 0), into: &hash)
            ChartBenchmarkSupport.hash(
                UInt64(bitPattern: Int64(segment.groupedItemCount ?? -1)),
                into: &hash
            )
            ChartBenchmarkSupport.hash(UInt64(segment.isDirectory ? 1 : 0), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(segment.showsContainerHeader ? 1 : 0), into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.rect.minX).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.rect.minY).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.rect.width).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.rect.height).bitPattern, into: &hash)
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
            prefix: "RADIX_TREEMAP_BENCH_RESULT",
            phase: phase,
            seconds: seconds,
            count: count,
            peakRSS: peakRSS,
            extra: extra
        )
    }
}

private actor InstrumentedTreemapLayoutService: TreemapLayouting {
    let probe: ChartBenchmarkSupport.LayoutProbe

    init(probe: ChartBenchmarkSupport.LayoutProbe) {
        self.probe = probe
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        await probe.recordStarted()
        do {
            let segments = try TreemapLayout.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                size: size,
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

private struct PrecomputedTreemapLayoutService: TreemapLayouting {
    let segments: [TreemapSegment]

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> [TreemapSegment] {
        segments
    }
}

private struct TreemapBenchmarkFixture: Sendable {
    let store: FileTreeStore
    let denseDirectoryID: String
}

private struct TreemapBenchmarkRequest {
    let rootID: String
    let depthLimit: Int
    let size: CGSize
    let layoutID: String
}
