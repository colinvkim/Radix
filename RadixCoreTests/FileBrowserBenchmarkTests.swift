import Combine
import Foundation
import Testing

@testable import RadixCore

struct FileBrowserBenchmarkTests {
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_METADATA_SEARCH"] == "1",
            "Set RADIX_BENCH_METADATA_SEARCH=1 to benchmark cold metadata searches."))
    func testColdMetadataSearchBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = Self.makeWideFixture(directoryCount: 1_000, filesPerDirectory: 1_000)
        let noMatches = environment["RADIX_BENCH_METADATA_MATCHES"] == "none"
        let scenario = noMatches ? "no-matches" : "all-files"
        let metadataQuery = FileBrowserQuery(
            itemKind: .file,
            allocatedSize: noMatches
                ? FileBrowserAllocatedSizeFilter(relation: .greaterThan, bytes: .max)
                : nil
        )
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        let service = await FileSearchService()
        let snapshotID = UUID()
        let expectedCount = noMatches ? 0 : fixture.fileCount
        let phases: [(name: String, query: FileBrowserQuery, order: [FileNodeTableComparator], count: Int)] = [
            ("metadata_cold", metadataQuery, sortOrder, expectedCount),
            ("metadata_repeat", metadataQuery, sortOrder, expectedCount),
            ("text_after_metadata", FileBrowserQuery(text: "__radix_no_match__"), [], 0),
            ("text_warm", FileBrowserQuery(text: "needle"), [], fixture.expectedTextQueryCount),
            ("metadata_after_text", metadataQuery, sortOrder, expectedCount),
        ]
        for phase in phases {
            let measurement = try await Self.measureAsyncWithMemory {
                try await service.search(
                    snapshotID: snapshotID,
                    treeStore: fixture.store,
                    query: phase.query,
                    sortOrder: phase.order
                )
            }
            #expect(measurement.value.count == phase.count)
            if !phase.order.isEmpty, measurement.value.count > 1 {
                Self.assertSorted(measurement.value, using: phase.order, fileTreeStore: fixture.store)
            }
            Self.report(
                phase: phase.name,
                seconds: measurement.seconds,
                count: measurement.value.count,
                peakRSS: BenchmarkSupport.peakResidentBytes(),
                extra: Self.phaseMemoryReportExtra(
                    shape: fixture.shape,
                    startRSS: measurement.startRSS,
                    endRSS: measurement.endRSS,
                    phasePeakRSS: measurement.peakRSS,
                    extra: "scenario=\(scenario) fingerprint=\(Self.fingerprint(measurement.value))"
                )
            )
        }

        let cancellation = try await Self.measureColdSearchCancellation(
            store: fixture.store,
            query: metadataQuery
        )
        #expect(
            cancellation.wasCancelled || cancellation.completedBeforeCancellation,
            "Metadata search returned normally after cancellation was requested.")
        Self.report(
            phase: "cancel_cold_metadata",
            seconds: cancellation.seconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "scenario=\(scenario) cancelled=\(cancellation.wasCancelled) "
                + "completed_before_cancel=\(cancellation.completedBeforeCancellation)"
        )
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_FILE_BROWSER"] == "1",
            "Set RADIX_BENCH_FILE_BROWSER=1 to run the million-node File Browser benchmark."))
    func testMillionNodeFileBrowserBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureShape = FileBrowserBenchmarkFixtureShape(
            environmentValue: environment["RADIX_BENCH_FILE_BROWSER_SHAPE"]
        )
        let directoryCount =
            environment["RADIX_BENCH_FILE_BROWSER_DIRECTORIES"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? fixtureShape.defaultDirectoryCount
        let filesPerDirectory =
            environment["RADIX_BENCH_FILE_BROWSER_FILES_PER_DIRECTORY"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 1_000
        let warmIterationCount =
            environment["RADIX_BENCH_FILE_BROWSER_WARM_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3

        let initialPeakRSS = BenchmarkSupport.peakResidentBytes()
        let fixtureMeasurement = BenchmarkSupport.measure {
            Self.makeFixture(
                shape: fixtureShape,
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory
            )
        }
        let fixture = fixtureMeasurement.value
        let fixturePeakRSS = BenchmarkSupport.peakResidentBytes()
        let fixtureCurrentRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()

        #expect(fixture.store.nodeCount == fixture.fileCount + fixture.directoryCount + 1)
        Self.report(
            phase: "fixture",
            seconds: fixtureMeasurement.seconds,
            count: fixture.store.nodeCount,
            peakRSS: fixturePeakRSS,
            extra: Self.memoryReportExtra(
                shape: fixture.shape,
                currentRSS: fixtureCurrentRSS,
                extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: fixturePeakRSS))"
            )
        )

        let snapshotID = UUID()
        let searchService = await FileSearchService()
        let noMatchQuery = FileBrowserQuery(text: "__radix_no_match__")
        let coldMeasurement = try await Self.measureAsyncWithMemory {
            try await searchService.search(
                snapshotID: snapshotID,
                treeStore: fixture.store,
                query: noMatchQuery,
                sortOrder: []
            )
        }
        #expect(coldMeasurement.value.isEmpty)
        let coldIndexedPeakRSS = BenchmarkSupport.peakResidentBytes()
        let coldIndexedCurrentRSS = coldMeasurement.endRSS

        let warmNoMatchSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: noMatchQuery,
            sortOrder: []
        )
        let warmNoMatchMedian = Self.median(warmNoMatchSamples.map(\.seconds))
        let estimatedIndexSeconds = max(coldMeasurement.seconds - warmNoMatchMedian, 0)
        let coldIndexRSSDelta = BenchmarkSupport.byteDelta(
            from: coldMeasurement.startRSS,
            to: coldMeasurement.endRSS
        )
        Self.report(
            phase: "cold_index",
            seconds: estimatedIndexSeconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: coldIndexedPeakRSS,
            extra: Self.phaseMemoryReportExtra(
                shape: fixture.shape,
                startRSS: coldMeasurement.startRSS,
                endRSS: coldMeasurement.endRSS,
                phasePeakRSS: coldMeasurement.peakRSS,
                extra: "cold_total=\(BenchmarkSupport.format(coldMeasurement.seconds)) "
                    + "warm_scan_median=\(BenchmarkSupport.format(warmNoMatchMedian)) "
                    + "post_index_rss_delta=\(coldIndexRSSDelta)"
            )
        )

        let textSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: FileBrowserQuery(text: "needle"),
            sortOrder: []
        )
        #expect(
            textSamples.allSatisfy {
                $0.resultCount == fixture.expectedTextQueryCount
            })
        Self.reportSamples(
            phase: "warm_text",
            samples: textSamples,
            count: fixture.expectedTextQueryCount
        )

        let firstPathMeasurement = try await Self.measureAsyncWithMemory {
            try await searchService.search(
                snapshotID: snapshotID,
                treeStore: fixture.store,
                query: fixture.pathQuery,
                sortOrder: []
            )
        }
        #expect(firstPathMeasurement.value.count == fixture.expectedPathQueryCount)
        let firstPathPeakRSS = BenchmarkSupport.peakResidentBytes()
        let firstPathRSSDeltaFromIndex = BenchmarkSupport.byteDelta(
            from: coldIndexedCurrentRSS,
            to: firstPathMeasurement.endRSS
        )
        Self.report(
            phase: "path_first",
            seconds: firstPathMeasurement.seconds,
            count: fixture.expectedPathQueryCount,
            peakRSS: firstPathPeakRSS,
            extra: Self.phaseMemoryReportExtra(
                shape: fixture.shape,
                startRSS: firstPathMeasurement.startRSS,
                endRSS: firstPathMeasurement.endRSS,
                phasePeakRSS: firstPathMeasurement.peakRSS,
                extra: "post_query_rss_delta_from_index=\(firstPathRSSDeltaFromIndex)"
            )
        )

        let warmPathSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: fixture.pathQuery,
            sortOrder: []
        )
        #expect(
            warmPathSamples.allSatisfy {
                $0.resultCount == fixture.expectedPathQueryCount
            })
        let warmPathMemoryMeasurement = try await Self.measureAsyncWithMemory {
            try await searchService.search(
                snapshotID: snapshotID,
                treeStore: fixture.store,
                query: fixture.pathQuery,
                sortOrder: []
            )
        }
        #expect(warmPathMemoryMeasurement.value.count == fixture.expectedPathQueryCount)
        let warmPathRSSDeltaFromIndex = BenchmarkSupport.byteDelta(
            from: coldIndexedCurrentRSS,
            to: warmPathMemoryMeasurement.endRSS
        )
        Self.reportSamples(
            phase: "path_warm",
            samples: warmPathSamples,
            count: fixture.expectedPathQueryCount,
            extra: Self.phaseMemoryReportExtra(
                shape: fixture.shape,
                startRSS: warmPathMemoryMeasurement.startRSS,
                endRSS: warmPathMemoryMeasurement.endRSS,
                phasePeakRSS: warmPathMemoryMeasurement.peakRSS,
                extra: "post_query_rss_delta_from_index=\(warmPathRSSDeltaFromIndex)"
            )
        )

        let filterQuery = FileBrowserQuery(itemKind: .file)
        let filterSamples = try await Self.measureSearchSamples(
            count: warmIterationCount,
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: filterQuery,
            sortOrder: []
        )
        #expect(filterSamples.allSatisfy { $0.resultCount == fixture.fileCount })
        let largeResults = try await searchService.search(
            snapshotID: snapshotID,
            treeStore: fixture.store,
            query: filterQuery,
            sortOrder: []
        )
        Self.reportSamples(
            phase: "filter_large",
            samples: filterSamples,
            count: largeResults.count
        )

        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        let sortingMeasurement = await Self.measureAsyncWithMemory {
            FileBrowserResults.sorted(
                largeResults,
                sortOrder: sortOrder,
                fileTreeStore: fixture.store
            )
        }
        let sortedResults = sortingMeasurement.value
        let sortingPeakRSS = BenchmarkSupport.peakResidentBytes()
        #expect(sortedResults.count == fixture.fileCount)
        Self.assertSorted(
            sortedResults,
            using: sortOrder,
            fileTreeStore: fixture.store
        )
        let sortFingerprint = Self.fingerprint(sortedResults)
        Self.report(
            phase: "sorting",
            seconds: sortingMeasurement.seconds,
            count: sortedResults.count,
            peakRSS: sortingPeakRSS,
            extra: Self.phaseMemoryReportExtra(
                shape: fixture.shape,
                startRSS: sortingMeasurement.startRSS,
                endRSS: sortingMeasurement.endRSS,
                phasePeakRSS: sortingMeasurement.peakRSS,
                extra: "fingerprint=\(sortFingerprint)"
            )
        )

        let projectionMeasurement = BenchmarkSupport.measure {
            FileBrowserDisplayProjection(nodes: sortedResults)
        }
        let displayProjection = projectionMeasurement.value
        Self.report(
            phase: "display_projection",
            seconds: projectionMeasurement.seconds,
            count: displayProjection.nodes.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let publicationMeasurement = await Self.measurePublication(displayProjection)
        Self.report(
            phase: "main_actor_publication",
            seconds: publicationMeasurement,
            count: displayProjection.nodes.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let replacementMeasurement = await Self.measurePublication(
            displayProjection,
            replacingExistingState: true
        )
        Self.report(
            phase: "main_actor_replacement",
            seconds: replacementMeasurement,
            count: displayProjection.nodes.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let coldCancellation = try await Self.measureColdSearchCancellation(
            store: fixture.store,
            query: noMatchQuery
        )
        #expect(
            coldCancellation.wasCancelled || coldCancellation.completedBeforeCancellation,
            "Cold search returned normally after cancellation was requested.")
        Self.report(
            phase: "cancel_cold_search",
            seconds: coldCancellation.seconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(coldCancellation.wasCancelled) "
                + "completed_before_cancel=\(coldCancellation.completedBeforeCancellation)"
        )

        let warmSearchCancellation = try await Self.measureSearchCancellation(
            service: searchService,
            snapshotID: snapshotID,
            store: fixture.store,
            query: noMatchQuery
        )
        #expect(
            warmSearchCancellation.wasCancelled || warmSearchCancellation.completedBeforeCancellation,
            "Warm search returned normally after cancellation was requested.")
        Self.report(
            phase: "cancel_warm_search",
            seconds: warmSearchCancellation.seconds,
            count: fixture.store.nodeCount - 1,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(warmSearchCancellation.wasCancelled) "
                + "completed_before_cancel=\(warmSearchCancellation.completedBeforeCancellation)"
        )

        let sortCancellation = try await Self.measureSortCancellation(
            nodes: largeResults,
            sortOrder: sortOrder,
            store: fixture.store,
            baselineSortSeconds: sortingMeasurement.seconds
        )
        #expect(
            sortCancellation.wasCancelled || sortCancellation.completedBeforeCancellation,
            "Sort returned normally after cancellation was requested.")
        Self.report(
            phase: "cancel_sort",
            seconds: sortCancellation.seconds,
            count: largeResults.count,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(sortCancellation.wasCancelled) "
                + "completed_before_cancel=\(sortCancellation.completedBeforeCancellation)"
        )

        let endToEndSeconds = try await Self.measureEndToEnd(
            fixture: fixture,
            service: searchService,
            query: filterQuery
        )
        Self.report(
            phase: "end_to_end",
            seconds: endToEndSeconds,
            count: fixture.fileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let suitePeakRSS = BenchmarkSupport.peakResidentBytes()
        let suiteCurrentRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        Self.report(
            phase: "suite_peak_rss",
            seconds: 0,
            count: fixture.store.nodeCount,
            peakRSS: suitePeakRSS,
            extra: Self.memoryReportExtra(
                shape: fixture.shape,
                currentRSS: suiteCurrentRSS,
                extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: suitePeakRSS))"
            )
        )
    }

    private static func measureSearchSamples(
        count: Int,
        service: FileSearchService,
        snapshotID: UUID,
        store: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [SearchSample] {
        var samples: [SearchSample] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let measurement = try await measureAsync {
                try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: query,
                    sortOrder: sortOrder
                )
            }
            samples.append(
                SearchSample(
                    seconds: measurement.seconds,
                    resultCount: measurement.value.count
                ))
        }
        return samples
    }

    @MainActor
    private static func measurePublication(
        _ projection: FileBrowserDisplayProjection,
        replacingExistingState: Bool = false
    ) -> Double {
        let publisher = FileBrowserPublicationProbe()
        if replacingExistingState {
            publisher.seed(with: projection.nodes)
        }
        var publicationCount = 0
        let cancellable = publisher.objectWillChange.sink {
            publicationCount += 1
        }

        let startedAt = ContinuousClock.now
        publisher.publish(projection)
        let seconds = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))

        #expect(publicationCount == 1)
        #expect(publisher.nodeCount == projection.nodes.count)
        #expect(publisher.node(id: projection.nodes[0].id)?.id == projection.nodes[0].id)
        #expect(
            publisher.node(id: projection.nodes[projection.nodes.count - 1].id)?.id
                == projection.nodes[projection.nodes.count - 1].id)
        withExtendedLifetime(cancellable) {}
        return seconds
    }

    @MainActor
    private static func measureEndToEnd(
        fixture: Fixture,
        service: FileSearchService,
        query: FileBrowserQuery
    ) async throws -> Double {
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: fixture.store.root.url),
            treeStore: fixture.store,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1),
            scanWarnings: [],
            isComplete: true
        )
        let model = FileBrowserModel(
            searchService: service,
            searchDebounceDuration: .zero,
            currentContentsAsyncThreshold: .max
        )
        model.updateContent(
            nodes: fixture.store.children(of: fixture.store.root.id),
            contentID: "\(snapshot.id.uuidString)|\(snapshot.root.id)",
            snapshot: snapshot,
            fileTreeStore: fixture.store
        )
        model.setSearchScope(.entireScan)

        let startedAt = ContinuousClock.now
        let deadline = startedAt.advanced(by: .seconds(60))
        defer { model.cleanup() }

        model.setActiveQuery(query)
        while !model.isSearchingEntireScan, ContinuousClock.now < deadline {
            await Task.yield()
        }
        guard model.isSearchingEntireScan else {
            throw FileBrowserBenchmarkTimeoutError(
                message: "Timed out waiting for the end-to-end entire-scan search to start."
            )
        }

        while model.isSearchingEntireScan, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !model.isSearchingEntireScan else {
            throw FileBrowserBenchmarkTimeoutError(
                message: "Timed out waiting for the end-to-end entire-scan search to finish."
            )
        }
        let seconds = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))

        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.count == fixture.fileCount)
        return seconds
    }

    private static func measureColdSearchCancellation(
        store: FileTreeStore,
        query: FileBrowserQuery
    ) async throws -> CancellationMeasurement {
        let service = await FileSearchService()
        return try await measureSearchCancellation(
            service: service,
            snapshotID: UUID(),
            store: store,
            query: query
        )
    }

    private static func measureSearchCancellation(
        service: FileSearchService,
        snapshotID: UUID,
        store: FileTreeStore,
        query: FileBrowserQuery
    ) async throws -> CancellationMeasurement {
        let task = Task {
            _ = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: query,
                sortOrder: []
            )
            return ContinuousClock.now
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(2))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    private static func measureSortCancellation(
        nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        store: FileTreeStore,
        baselineSortSeconds: Double
    ) async throws -> CancellationMeasurement {
        let task = Task.detached {
            _ = try FileBrowserResults.sorted(
                nodes,
                sortOrder: sortOrder,
                fileTreeStore: store,
                cancellationCheck: {
                    try Task.checkCancellation()
                }
            )
            return ContinuousClock.now
        }
        let delaySeconds = min(max(baselineSortSeconds * 0.5, 0.01), 1.5)
        try await Task.sleep(for: .seconds(delaySeconds))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    private static func makeFixture(
        shape: FileBrowserBenchmarkFixtureShape,
        directoryCount: Int,
        filesPerDirectory: Int
    ) -> Fixture {
        switch shape {
        case .wide:
            makeWideFixture(
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory
            )
        case .directoryHeavy:
            makeDirectoryHeavyFixture(directoryCount: directoryCount)
        }
    }

    private static func makeWideFixture(
        directoryCount: Int,
        filesPerDirectory: Int
    ) -> Fixture {
        let fileCount = directoryCount * filesPerDirectory
        let nodeCount = fileCount + directoryCount + 1
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let rootID = "/benchmark"
        var nodes = [
            FileNodeRecord(
                id: rootID,
                url: URL(filePath: rootID, directoryHint: .isDirectory),
                name: "benchmark",
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: Int64(fileCount),
                logicalSize: Int64(fileCount),
                descendantFileCount: fileCount,
                lastModified: nil,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            )
        ]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: nodeCount)
        var parentIndices = [FileTreeNodeIndex?](repeating: nil, count: nodeCount)
        var rootChildren: [FileTreeNodeIndex] = []
        rootChildren.reserveCapacity(directoryCount)

        for directoryOffset in 0..<directoryCount {
            let directoryID = String(format: "%@/directory-%04d", rootID, directoryOffset)
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(
                FileNodeRecord(
                    id: directoryID,
                    url: URL(filePath: directoryID, directoryHint: .isDirectory),
                    name: URL(filePath: directoryID).lastPathComponent,
                    isDirectory: true,
                    isSymbolicLink: false,
                    allocatedSize: Int64(filesPerDirectory),
                    logicalSize: Int64(filesPerDirectory),
                    descendantFileCount: filesPerDirectory,
                    lastModified: nil,
                    isPackage: false,
                    isAccessible: true,
                    isSelfAccessible: true,
                    isSynthetic: false,
                    isAutoSummarized: false
                ))
            parentIndices[Int(directoryIndex.rawValue)] = rootIndex
            rootChildren.append(directoryIndex)

            var directoryChildren: [FileTreeNodeIndex] = []
            directoryChildren.reserveCapacity(filesPerDirectory)
            for fileOffset in 0..<filesPerDirectory {
                let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                let name =
                    directoryOffset.isMultiple(of: 100) && fileOffset == 777
                    ? String(format: "needle-%06d.dat", directoryOffset)
                    : String(format: "item-%04d.dat", fileOffset)
                let fileID = directoryID + "/" + name
                let sequence = (directoryOffset * filesPerDirectory) + fileOffset
                let allocatedSize = Int64(((sequence * 37) % 16_384) + 1)
                nodes.append(
                    FileNodeRecord(
                        id: fileID,
                        url: URL(filePath: fileID),
                        name: name,
                        isDirectory: false,
                        isSymbolicLink: false,
                        allocatedSize: allocatedSize,
                        logicalSize: allocatedSize,
                        descendantFileCount: 1,
                        lastModified: Date(timeIntervalSinceReferenceDate: Double(sequence % 10_000)),
                        isPackage: false,
                        isAccessible: true,
                        isSelfAccessible: true,
                        isSynthetic: false,
                        isAutoSummarized: false
                    ))
                parentIndices[Int(fileIndex.rawValue)] = directoryIndex
                directoryChildren.append(fileIndex)
            }
            childIndicesByIndex[Int(directoryIndex.rawValue)] = directoryChildren
        }
        childIndicesByIndex[0] = rootChildren

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(fileCount),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: directoryCount + 1,
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        let expectedTextQueryCount =
            filesPerDirectory > 777
            ? ((directoryCount - 1) / 100) + 1
            : 0
        let pathDirectoryOffset = directoryCount / 2
        return Fixture(
            shape: FileBrowserBenchmarkFixtureShape.wide.rawValue,
            store: store,
            fileCount: fileCount,
            directoryCount: directoryCount,
            expectedTextQueryCount: expectedTextQueryCount,
            pathQuery: FileBrowserQuery(
                text: String(format: "/benchmark/directory-%04d/", pathDirectoryOffset)
            ),
            expectedPathQueryCount: filesPerDirectory
        )
    }

    private static func makeDirectoryHeavyFixture(
        directoryCount: Int
    ) -> Fixture {
        let maximumDepth = 64
        let fileCount = directoryCount
        let nodeCount = (directoryCount * 2) + 1
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let rootID = "/benchmark"

        var nodes = [
            FileNodeRecord(
                id: rootID,
                url: URL(filePath: rootID, directoryHint: .isDirectory),
                name: "benchmark",
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: Int64(fileCount),
                logicalSize: Int64(fileCount),
                descendantFileCount: fileCount,
                lastModified: nil,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            )
        ]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: nodeCount)
        var parentIndices = [FileTreeNodeIndex?](repeating: nil, count: nodeCount)

        // A forest of bounded chains keeps the fixture realistic while making
        // parent-path storage scale with directory count rather than shallow breadth.
        for directoryOffset in 0..<directoryCount {
            let depth = directoryOffset % maximumDepth
            let parentIndex: FileTreeNodeIndex
            if depth == 0 {
                parentIndex = rootIndex
            } else {
                parentIndex = FileTreeNodeIndex(rawValue: UInt32(directoryOffset))
            }
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(directoryOffset + 1))
            let directoryName =
                depth == 0
                ? String(format: "Branch-%05d", directoryOffset / maximumDepth)
                : String(
                    format: depth.isMultiple(of: 2) ? "Folder-%03d" : "segment-%03d",
                    depth
                )
            let directoryID = nodes[Int(parentIndex.rawValue)].id + "/" + directoryName
            let descendantFileCount = min(
                maximumDepth - depth,
                directoryCount - directoryOffset
            )
            nodes.append(
                FileNodeRecord(
                    id: directoryID,
                    url: URL(filePath: directoryID, directoryHint: .isDirectory),
                    name: directoryName,
                    isDirectory: true,
                    isSymbolicLink: false,
                    allocatedSize: Int64(descendantFileCount),
                    logicalSize: Int64(descendantFileCount),
                    descendantFileCount: descendantFileCount,
                    lastModified: nil,
                    isPackage: false,
                    isAccessible: true,
                    isSelfAccessible: true,
                    isSynthetic: false,
                    isAutoSummarized: false
                ))
            parentIndices[Int(directoryIndex.rawValue)] = parentIndex
            childIndicesByIndex[Int(parentIndex.rawValue)].append(directoryIndex)
        }

        for directoryOffset in 0..<directoryCount {
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(directoryOffset + 1))
            let fileIndex = FileTreeNodeIndex(
                rawValue: UInt32(directoryCount + directoryOffset + 1)
            )
            let name = directoryOffset.isMultiple(of: 100) ? "needle.dat" : "item.dat"
            let fileID = nodes[Int(directoryIndex.rawValue)].id + "/" + name
            let allocatedSize = Int64(((directoryOffset * 37) % 16_384) + 1)
            nodes.append(
                FileNodeRecord(
                    id: fileID,
                    url: URL(filePath: fileID),
                    name: name,
                    isDirectory: false,
                    isSymbolicLink: false,
                    allocatedSize: allocatedSize,
                    logicalSize: allocatedSize,
                    descendantFileCount: 1,
                    lastModified: Date(
                        timeIntervalSinceReferenceDate: Double(directoryOffset % 10_000)
                    ),
                    isPackage: false,
                    isAccessible: true,
                    isSelfAccessible: true,
                    isSynthetic: false,
                    isAutoSummarized: false
                ))
            parentIndices[Int(fileIndex.rawValue)] = directoryIndex
            childIndicesByIndex[Int(directoryIndex.rawValue)].append(fileIndex)
        }

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(fileCount),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: directoryCount + 1,
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        let pathDirectoryOffset = min(maximumDepth - 1, directoryCount - 1)
        let pathDirectoryIndex = FileTreeNodeIndex(rawValue: UInt32(pathDirectoryOffset + 1))
        return Fixture(
            shape: "\(FileBrowserBenchmarkFixtureShape.directoryHeavy.rawValue)-depth-\(maximumDepth)",
            store: store,
            fileCount: fileCount,
            directoryCount: directoryCount,
            expectedTextQueryCount: ((directoryCount - 1) / 100) + 1,
            pathQuery: FileBrowserQuery(
                text: nodes[Int(pathDirectoryIndex.rawValue)].id + "/"
            ),
            expectedPathQueryCount: 1
        )
    }

    private static func assertSorted(
        _ nodes: [FileNodeRecord],
        using sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for offset in 1..<nodes.count {
            let lhs = nodes[offset - 1]
            let rhs = nodes[offset]
            var result = ComparisonResult.orderedSame
            for comparator in sortOrder {
                result = comparator.compare(lhs, rhs, fileTreeStore: fileTreeStore)
                if result != .orderedSame {
                    break
                }
            }
            if result == .orderedSame {
                result = FileNodeSortComparison.fallback(
                    lhsName: lhs.name,
                    lhsID: lhs.id,
                    rhsName: rhs.name,
                    rhsID: rhs.id
                )
            }
            #expect(result != .orderedDescending, sourceLocation: sourceLocation)
        }
    }

    private static func fingerprint(_ nodes: [FileNodeRecord]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for node in nodes {
            for byte in node.id.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= UInt64(bitPattern: node.allocatedSize)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func measureAsync<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> BenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try await operation()
        return BenchmarkMeasurement(
            value: value,
            seconds: BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        )
    }

    private static func measureAsyncWithMemory<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> MemoryBenchmarkMeasurement<Value> {
        let startRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        let sampler = BenchmarkMemorySampler(initialRSS: startRSS)
        let samplerTask = Task {
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let startedAt = ContinuousClock.now
        let value = try await operation()
        let seconds = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        samplerTask.cancel()
        _ = await samplerTask.result
        sampler.sample()
        let endRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        return MemoryBenchmarkMeasurement(
            value: value,
            seconds: seconds,
            startRSS: startRSS,
            endRSS: endRSS,
            peakRSS: max(sampler.peak(), endRSS)
        )
    }

    private static func median(_ values: [Double]) -> Double {
        BenchmarkSupport.median(values)!
    }

    private static func reportSamples(
        phase: String,
        samples: [SearchSample],
        count: Int,
        extra: String = ""
    ) {
        let seconds = samples.map(\.seconds)
        let sampleExtra = "samples=\(seconds.map { BenchmarkSupport.format($0) }.joined(separator: ","))"
        report(
            phase: phase,
            seconds: median(seconds),
            count: count,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: extra.isEmpty ? sampleExtra : "\(extra) \(sampleExtra)"
        )
    }

    private static func memoryReportExtra(
        shape: String,
        currentRSS: UInt64,
        extra: String = ""
    ) -> String {
        let memoryExtra = "shape=\(shape) current_rss=\(currentRSS)"
        return extra.isEmpty ? memoryExtra : "\(memoryExtra) \(extra)"
    }

    private static func phaseMemoryReportExtra(
        shape: String,
        startRSS: UInt64,
        endRSS: UInt64,
        phasePeakRSS: UInt64,
        extra: String = ""
    ) -> String {
        let memoryExtra = "shape=\(shape) start_rss=\(startRSS) end_rss=\(endRSS) " + "phase_peak_rss=\(phasePeakRSS)"
        return extra.isEmpty ? memoryExtra : "\(memoryExtra) \(extra)"
    }

    private static func report(
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        BenchmarkSupport.report(
            prefix: "RADIX_FILE_BROWSER_BENCH_RESULT",
            phase: phase,
            seconds: seconds,
            count: count,
            peakRSS: peakRSS,
            extra: extra
        )
    }
}

@MainActor
private final class FileBrowserPublicationProbe: ObservableObject {
    @Published private var displayState = FileBrowserDisplayState()

    var nodeCount: Int {
        displayState.nodes.count
    }

    func node(id: FileNodeRecord.ID) -> FileNodeRecord? {
        displayState.node(id: id)
    }

    func publish(_ projection: FileBrowserDisplayProjection) {
        displayState = FileBrowserDisplayState(projection: projection, context: .empty)
    }

    func seed(with nodes: [FileNodeRecord]) {
        var independentNodes = nodes
        independentNodes.reverse()
        displayState = FileBrowserDisplayState(nodes: independentNodes, context: .empty)
    }
}

private struct Fixture: Sendable {
    let shape: String
    let store: FileTreeStore
    let fileCount: Int
    let directoryCount: Int
    let expectedTextQueryCount: Int
    let pathQuery: FileBrowserQuery
    let expectedPathQueryCount: Int
}

private enum FileBrowserBenchmarkFixtureShape: String {
    case wide
    case directoryHeavy = "directory-heavy"

    init(environmentValue: String?) {
        self = Self(rawValue: environmentValue?.lowercased() ?? "wide") ?? .wide
    }

    var defaultDirectoryCount: Int {
        switch self {
        case .wide:
            1_000
        case .directoryHeavy:
            500_000
        }
    }
}

private struct SearchSample {
    let seconds: Double
    let resultCount: Int
}

private struct MemoryBenchmarkMeasurement<Value> {
    let value: Value
    let seconds: Double
    let startRSS: UInt64
    let endRSS: UInt64
    let peakRSS: UInt64
}

private struct CancellationMeasurement {
    let seconds: Double
    let wasCancelled: Bool
    let completedBeforeCancellation: Bool
}

private struct FileBrowserBenchmarkTimeoutError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
