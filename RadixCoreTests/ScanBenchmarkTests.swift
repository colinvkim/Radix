import Foundation
import Testing

@testable import RadixCore

#if DEBUG
    private final class AutoSummaryBenchmarkProfile: @unchecked Sendable {
        struct Snapshot {
            let probeCount: Int
            let acceptedProbeCount: Int
            let probedItemCount: Int
            let summarizedDirectoryCount: Int
            let summarizedFileCount: Int
            let reusedDirectoryCount: Int
            let reusedEntryCount: Int
        }

        private let lock = NSLock()
        private var probeCount = 0
        private var acceptedProbeCount = 0
        private var probedItemCount = 0
        private var summarizedDirectoryCount = 0
        private var summarizedFileCount = 0
        private var reusedDirectoryCount = 0
        private var reusedEntryCount = 0

        func record(_ event: ScanAutoSummaryProfileEvent) {
            lock.lock()
            switch event {
            case .probeCompleted(let visitedItemCount, let wasAccepted):
                probeCount += 1
                acceptedProbeCount += wasAccepted ? 1 : 0
                probedItemCount += visitedItemCount
            case .directorySummarized(let descendantFileCount):
                summarizedDirectoryCount += 1
                summarizedFileCount += descendantFileCount
            case .reusedDirectoryListing(let entryCount):
                reusedDirectoryCount += 1
                reusedEntryCount += entryCount
            }
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                probeCount: probeCount,
                acceptedProbeCount: acceptedProbeCount,
                probedItemCount: probedItemCount,
                summarizedDirectoryCount: summarizedDirectoryCount,
                summarizedFileCount: summarizedFileCount,
                reusedDirectoryCount: reusedDirectoryCount,
                reusedEntryCount: reusedEntryCount
            )
        }
    }
#endif

struct ScanBenchmarkTests {
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_INCREMENTAL"] == "1",
            "Set RADIX_BENCH_INCREMENTAL=1 to run the incremental rescan benchmark."))
    func testIncrementalRescanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directoryCount = max(
            environment["RADIX_BENCH_INCREMENTAL_DIRECTORIES"].flatMap(Int.init) ?? 100,
            100
        )
        let filesPerDirectory = max(
            environment["RADIX_BENCH_INCREMENTAL_FILES_PER_DIRECTORY"].flatMap(Int.init) ?? 100,
            1
        )

        for mutation in IncrementalBenchmarkRootMutation.allCases {
            try await runRootMutationBenchmark(
                mutation,
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory
            )
        }
        for changedDirectoryCount in [1, 10, 100] {
            try await runScatteredChangesBenchmark(
                changedDirectoryCount: changedDirectoryCount,
                directoryCount: directoryCount,
                filesPerDirectory: filesPerDirectory
            )
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH"] == "1",
            "Set RADIX_BENCH=1 to run the real-world scan benchmark."))
    func testRealWorldScanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let benchmarkPath = environment["RADIX_BENCH_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: benchmarkPath, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw TestFixtureError("Benchmark path does not exist: \(targetURL.path)")
        }

        #if DEBUG
            let autoSummaryProfile =
                environment["RADIX_BENCH_AUTO_SUMMARY_PROFILE"] == "1"
                ? AutoSummaryBenchmarkProfile()
                : nil
            let autoSummaryProfileReporter: ScanEngine.AutoSummaryProfileReporter?
            if let autoSummaryProfile {
                autoSummaryProfileReporter = { @Sendable event in
                    autoSummaryProfile.record(event)
                }
            } else {
                autoSummaryProfileReporter = nil
            }
            let engine =
                if let autoSummaryProfileReporter {
                    ScanEngine(autoSummaryProfileReporter: autoSummaryProfileReporter)
                } else {
                    ScanEngine()
                }
        #else
            let engine = ScanEngine()
        #endif
        var options = ScanOptions()
        options.includeHiddenFiles = environment["RADIX_BENCH_INCLUDE_HIDDEN"] == "1"
        options.autoSummarizeDirectories = environment["RADIX_BENCH_AUTO_SUMMARIZE"] != "0"
        if environment["RADIX_BENCH_COMMON_EXCLUSIONS"] == "1" {
            options.exclusionPatterns = ScanExclusionMatcher.commonPresetPatterns
        }
        let startedAt = ContinuousClock.now
        var progressEvents = 0
        var warningEvents = 0
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: targetURL), options: options) {
            switch event {
            case .executionMode:
                break
            case .progress:
                progressEvents += 1
            case .warning:
                warningEvents += 1
            case .finished(let snapshot):
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let snapshot = try #require(finalSnapshot)
        let elapsedSeconds = BenchmarkSupport.durationSeconds(elapsed)
        #if DEBUG
            let profile = autoSummaryProfile?.snapshot()
            let autoSummaryProfileOutput = """
                auto_summary_probes=\(profile?.probeCount ?? 0)
                auto_summary_accepted_probes=\(profile?.acceptedProbeCount ?? 0)
                auto_summary_probed_items=\(profile?.probedItemCount ?? 0)
                auto_summary_directories=\(profile?.summarizedDirectoryCount ?? 0)
                auto_summary_files=\(profile?.summarizedFileCount ?? 0)
                auto_summary_reused_directories=\(profile?.reusedDirectoryCount ?? 0)
                auto_summary_reused_entries=\(profile?.reusedEntryCount ?? 0)
                """
        #else
            let autoSummaryProfileOutput = ""
        #endif

        print(
            """
            RADIX_BENCH_RESULT path=\(targetURL.path)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            include_hidden=\(options.includeHiddenFiles)
            auto_summarize=\(options.autoSummarizeDirectories)
            exclusions=\(options.exclusionPatterns.count)
            files=\(snapshot.aggregateStats.fileCount)
            folders=\(snapshot.aggregateStats.directoryCount)
            nodes=\(snapshot.treeStore.nodeCount)
            warnings=\(snapshot.scanWarnings.count)
            warning_fingerprint=\(scanWarningFingerprint(snapshot.scanWarnings))
            warning_order_fingerprint=\(scanOrderedWarningFingerprint(snapshot.scanWarnings))
            progress_events=\(progressEvents)
            discovered=\(snapshot.aggregateStats.totalAllocatedSize)
            fingerprint=\(Self.resultFingerprint(snapshot.treeStore))
            \(autoSummaryProfileOutput)
            """
        )
    }

    @MainActor
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_TREE_REMOVAL"] == "1",
            "Set RADIX_BENCH_TREE_REMOVAL=1 to run the tree-removal benchmark."))
    func testTreeRemovalBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let usesHardLinks = environment["RADIX_BENCH_TREE_HARD_LINKS"] == "1"
        let usesLogicalScope = environment["RADIX_BENCH_TREE_LOGICAL_SCOPE"] == "1"
        let removesDirectory = environment["RADIX_BENCH_TREE_REMOVE_DIRECTORY"] == "1"
        let directoryCount =
            environment["RADIX_BENCH_TREE_DIRECTORIES"]
            .flatMap(Int.init)
            .map { max(2, $0) } ?? 200
        let filesPerDirectory =
            environment["RADIX_BENCH_TREE_FILES_PER_DIRECTORY"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 1_000
        let fileCount = directoryCount * filesPerDirectory
        let nodeCount = fileCount + directoryCount + 1
        let totalAllocatedSize = usesHardLinks ? filesPerDirectory : fileCount
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        var nodes = [
            FileNodeRecord(
                id: "/benchmark",
                url: URL(filePath: "/benchmark", directoryHint: .isDirectory),
                name: "benchmark",
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: Int64(totalAllocatedSize),
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
        var removalID = ""

        for directoryOffset in 0..<directoryCount {
            let directoryIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            let directoryID = String(format: "/benchmark/directory-%06d", directoryOffset)
            nodes.append(
                FileNodeRecord(
                    id: directoryID,
                    url: URL(filePath: directoryID, directoryHint: .isDirectory),
                    name: URL(filePath: directoryID).lastPathComponent,
                    isDirectory: true,
                    isSymbolicLink: false,
                    allocatedSize: Int64(usesHardLinks && directoryOffset > 0 ? 0 : filesPerDirectory),
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
            if removesDirectory, directoryOffset == 0 {
                removalID = directoryID
            }

            var directoryChildren: [FileTreeNodeIndex] = []
            directoryChildren.reserveCapacity(filesPerDirectory)
            for fileOffset in 0..<filesPerDirectory {
                let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                let fileID = directoryID + String(format: "/file-%06d.bin", fileOffset)
                let allocatedSize: Int64 = usesHardLinks && directoryOffset > 0 ? 0 : 1
                nodes.append(
                    FileNodeRecord(
                        id: fileID,
                        url: URL(filePath: fileID),
                        name: URL(filePath: fileID).lastPathComponent,
                        isDirectory: false,
                        isSymbolicLink: false,
                        allocatedSize: allocatedSize,
                        unduplicatedAllocatedSize: 1,
                        dataAllocatedSize: 1,
                        logicalSize: 1,
                        descendantFileCount: 1,
                        lastModified: nil,
                        fileIdentity: usesHardLinks
                            ? FileIdentity(device: 1, inode: UInt64(fileOffset + 1))
                            : nil,
                        linkCount: usesHardLinks ? UInt64(directoryCount) : 1,
                        isPackage: false,
                        isAccessible: true,
                        isSelfAccessible: true,
                        isSynthetic: false,
                        isAutoSummarized: false
                    ))
                parentIndices[Int(fileIndex.rawValue)] = directoryIndex
                directoryChildren.append(fileIndex)
                if !removesDirectory,
                    directoryOffset == 0,
                    fileOffset == filesPerDirectory / 2
                {
                    removalID = fileID
                }
            }
            childIndicesByIndex[Int(directoryIndex.rawValue)] = directoryChildren
        }
        childIndicesByIndex[0] = rootChildren
        let orderedNodeIndices = nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) }
        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(totalAllocatedSize),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: directoryCount + 1,
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        let benchmarkStore =
            usesLogicalScope
            ? try #require(store.logicalScope(rootedAt: store.rootID))
            : store

        let startedAt = ContinuousClock.now
        let updatedStore = try #require(benchmarkStore.removingSubtree(id: removalID))
        let filterFinishedAt = ContinuousClock.now
        let sunburstSegments = SunburstLayout.segments(
            in: updatedStore,
            rootID: updatedStore.root.id,
            depthLimit: 4
        )
        let sunburstFinishedAt = ContinuousClock.now
        let treemapSegments = TreemapLayout.segments(
            in: updatedStore,
            rootID: updatedStore.root.id,
            depthLimit: 4,
            size: CGSize(width: 1_200, height: 800)
        )
        let finishedAt = ContinuousClock.now
        let filterElapsedSeconds = BenchmarkSupport.durationSeconds(
            startedAt.duration(to: filterFinishedAt)
        )
        let sunburstElapsedSeconds = BenchmarkSupport.durationSeconds(
            filterFinishedAt.duration(to: sunburstFinishedAt)
        )
        let treemapElapsedSeconds = BenchmarkSupport.durationSeconds(
            sunburstFinishedAt.duration(to: finishedAt)
        )
        let endToEndElapsedSeconds = BenchmarkSupport.durationSeconds(startedAt.duration(to: finishedAt))

        let removedNodeCount = removesDirectory ? filesPerDirectory + 1 : 1
        let removedFileCount = removesDirectory ? filesPerDirectory : 1
        #expect(updatedStore.nodeCount == nodeCount - removedNodeCount)
        #expect(updatedStore.aggregateStats.fileCount == fileCount - removedFileCount)
        #expect(
            updatedStore.aggregateStats.totalAllocatedSize
                == Int64(usesHardLinks ? filesPerDirectory : fileCount - removedFileCount))
        print(
            "RADIX_BENCH_TREE_REMOVAL_RESULT nodes=\(nodeCount) "
                + "removed=\(removedNodeCount) hard_links=\(usesHardLinks) " + "logical_scope=\(usesLogicalScope) "
                + "filter=\(String(format: "%.6f", filterElapsedSeconds))s "
                + "sunburst=\(String(format: "%.6f", sunburstElapsedSeconds))s "
                + "sunburst_segments=\(sunburstSegments.count) "
                + "treemap=\(String(format: "%.6f", treemapElapsedSeconds))s "
                + "treemap_segments=\(treemapSegments.count) "
                + "end_to_end=\(String(format: "%.6f", endToEndElapsedSeconds))s"
        )
    }

    /// Release gate for the startup-volume namespace. It compares the optimized
    /// bulk/descriptor scanner with the independent Foundation enumeration path
    /// and verifies that macOS firmlink roots were actually traversed.
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_STARTUP_SCAN_REGRESSION"] == "1",
            "Set RADIX_STARTUP_SCAN_REGRESSION=1 to compare startup-volume scanner paths."))
    func testStartupVolumeScannerParityGate() async throws {
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let target = ScanTarget(url: rootURL, kind: .volume)
        var options = ScanOptions()
        // macOS marks several startup-volume namespace roots (including
        // /private) hidden even though they are essential to whole-disk parity.
        options.includeHiddenFiles = true
        // Keep the release gate bounded and machine-independent by excluding
        // user homes and volatile per-user system caches. Both scanner paths
        // receive identical rules; firmlink opening and aggregate parity across
        // the startup-volume namespace remain covered.
        options.exclusionPatterns =
            ScanExclusionMatcher.commonPresetPatterns + [
                "Users/*/",
                "private/var/",
            ]
        let optimizedSnapshot = try await finishedSnapshot(
            target: target,
            options: options,
            engine: ScanEngine()
        )
        let foundationSnapshot = try await finishedSnapshot(
            target: target,
            options: options,
            engine: ScanEngine(directoryContents: { url, keys, enumerationOptions, cancellationCheck in
                try cancellationCheck()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions
                )
                try cancellationCheck()
                return contents
            })
        )

        let firmlinkRoots = [
            "/Applications",
            "/Library",
            "/Users",
            "/private",
        ]

        let optimizedRootChildIDs = optimizedSnapshot.treeStore.childIDs(of: optimizedSnapshot.root.id)
        let foundationRootChildIDs = foundationSnapshot.treeStore.childIDs(of: foundationSnapshot.root.id)

        for path in firmlinkRoots where FileManager.default.fileExists(atPath: path) {
            let optimizedNode = try #require(
                optimizedSnapshot.treeStore.node(id: path),
                "Optimized startup scan omitted firmlink root \(path). Root children: \(optimizedRootChildIDs)")
            let foundationNode = try #require(
                foundationSnapshot.treeStore.node(id: path),
                "Foundation startup scan omitted firmlink root \(path). Root children: \(foundationRootChildIDs)")
            #expect(optimizedNode.isSelfAccessible, "Optimized startup scan could not open \(path)")
            #expect(foundationNode.isSelfAccessible, "Foundation startup scan could not open \(path)")
            if path != "/Users" {
                #expect(optimizedNode.allocatedSize > 0, "Optimized startup scan found no data at \(path)")
                #expect(foundationNode.allocatedSize > 0, "Foundation startup scan found no data at \(path)")
            }
        }

        let optimizedStaleWarnings = optimizedSnapshot.scanWarnings.filter {
            $0.message.localizedCaseInsensitiveContains("stale")
        }
        let foundationStaleWarnings = foundationSnapshot.scanWarnings.filter {
            $0.message.localizedCaseInsensitiveContains("stale")
        }
        #expect(optimizedStaleWarnings.isEmpty, "Optimized scan reported stale handles: \(optimizedStaleWarnings)")
        #expect(foundationStaleWarnings.isEmpty, "Foundation scan reported stale handles: \(foundationStaleWarnings)")

        assertWithinRelativeTolerance(
            optimizedSnapshot.aggregateStats.totalAllocatedSize,
            foundationSnapshot.aggregateStats.totalAllocatedSize,
            // Live allocated-byte metadata is the noisiest signal: APFS clones,
            // sparse files, and directories that become inaccessible between
            // the sequential scans can shift it without changing traversal.
            // The v1.5 regression was orders of magnitude larger.
            tolerance: 0.15,
            label: "allocated bytes"
        )
        assertWithinRelativeTolerance(
            Int64(optimizedSnapshot.aggregateStats.fileCount),
            Int64(foundationSnapshot.aggregateStats.fileCount),
            tolerance: 0.05,
            label: "file count"
        )
        assertWithinRelativeTolerance(
            Int64(optimizedSnapshot.aggregateStats.directoryCount),
            Int64(foundationSnapshot.aggregateStats.directoryCount),
            tolerance: 0.05,
            label: "directory count"
        )

        print(
            """
            RADIX_STARTUP_SCAN_REGRESSION_RESULT
            optimized_bytes=\(optimizedSnapshot.aggregateStats.totalAllocatedSize)
            foundation_bytes=\(foundationSnapshot.aggregateStats.totalAllocatedSize)
            optimized_files=\(optimizedSnapshot.aggregateStats.fileCount)
            foundation_files=\(foundationSnapshot.aggregateStats.fileCount)
            optimized_folders=\(optimizedSnapshot.aggregateStats.directoryCount)
            foundation_folders=\(foundationSnapshot.aggregateStats.directoryCount)
            optimized_warnings=\(optimizedSnapshot.scanWarnings.count)
            foundation_warnings=\(foundationSnapshot.scanWarnings.count)
            """
        )
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_WIDE_DIRECTORY"] == "1",
            "Set RADIX_BENCH_WIDE_DIRECTORY=1 to run the wide-directory benchmark."))
    func testWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let fileCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FILE_COUNTS"],
            defaultValues: [128, 1_000, 10_000]
        )
        let iterations =
            environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers =
            environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers =
            environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "coordinator-leaf-preparation",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                usesWorkerSideLeafPreparation: false
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "leaf-batch-256",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                leafPreparationBatchLimit: 256
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "leaf-batch-1024",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                leafPreparationBatchLimit: 1_024
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            ),
        ]

        for fileCount in fileCounts {
            let rootURL = try makeWideBenchmarkDirectory(fileCount: fileCount)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            for configuration in configurations {
                _ = try await runWideDirectoryBenchmark(
                    rootURL: rootURL,
                    fileCount: fileCount,
                    configuration: configuration,
                    iteration: 0,
                    isWarmup: true
                )
            }

            var elapsedByConfiguration: [String: [Double]] = [:]
            for iteration in 1...iterations {
                for configuration in Self.benchmarkConfigurationOrder(
                    configurations,
                    iteration: iteration
                ) {
                    let elapsedSeconds = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: iteration,
                        isWarmup: false
                    )
                    elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                }
            }

            for configuration in configurations {
                let elapsed = elapsedByConfiguration[configuration.name, default: []]
                guard !elapsed.isEmpty else { continue }
                let average = elapsed.reduce(0, +) / Double(elapsed.count)
                print(
                    """
                    RADIX_BENCH_WIDE_SUMMARY files=\(fileCount)
                    config=\(configuration.name)
                    traversal_workers=\(configuration.traversalWorkerDescription)
                    requested_classification_workers=\(configuration.classificationWorkerDescription)
                    leaf_preparation=\(configuration.leafPreparationDescription)
                    leaf_batch_limit=\(configuration.leafPreparationBatchDescription)
                    iterations=\(elapsed.count)
                    avg_elapsed=\(String(format: "%.3f", average))s
                    min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                    max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                    """
                )
            }
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_DEFERRED_FILTERING"] == "1",
            "Set RADIX_BENCH_DEFERRED_FILTERING=1 to run the deferred-filtering benchmark."))
    func testDeferredBulkEntryFilteringBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fileCount =
            environment["RADIX_BENCH_DEFERRED_FILTERING_FILES"]
            .flatMap(Int.init)
            .map { max(1_000, $0) } ?? 30_000
        let includedStride =
            environment["RADIX_BENCH_DEFERRED_FILTERING_INCLUDED_STRIDE"]
            .flatMap(Int.init)
            .map { max(2, $0) } ?? 10
        let iterations =
            environment["RADIX_BENCH_DEFERRED_FILTERING_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(3, $0) } ?? 7
        let rootURL = try makeDeferredFilteringBenchmarkDirectory(
            fileCount: fileCount,
            includedStride: includedStride
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configurations = [
            DeferredFilteringBenchmarkConfiguration(name: "legacy", usesDeferredFiltering: false),
            DeferredFilteringBenchmarkConfiguration(name: "deferred", usesDeferredFiltering: true),
        ]
        var referenceFingerprint: String?
        for configuration in configurations {
            let result = try await runDeferredFilteringBenchmark(
                rootURL: rootURL,
                fileCount: fileCount,
                includedStride: includedStride,
                configuration: configuration,
                iteration: 0,
                isWarmup: true
            )
            if let referenceFingerprint {
                #expect(result.fingerprint == referenceFingerprint)
            } else {
                referenceFingerprint = result.fingerprint
            }
        }

        var elapsedByConfiguration: [String: [Double]] = [:]
        for iteration in 1...iterations {
            let orderedConfigurations =
                iteration.isMultiple(of: 2)
                ? configurations
                : Array(configurations.reversed())
            for configuration in orderedConfigurations {
                let result = try await runDeferredFilteringBenchmark(
                    rootURL: rootURL,
                    fileCount: fileCount,
                    includedStride: includedStride,
                    configuration: configuration,
                    iteration: iteration,
                    isWarmup: false
                )
                #expect(result.fingerprint == referenceFingerprint)
                elapsedByConfiguration[configuration.name, default: []].append(result.elapsedSeconds)
            }
        }

        for configuration in configurations {
            let elapsed = elapsedByConfiguration[configuration.name, default: []]
            let average = elapsed.reduce(0, +) / Double(elapsed.count)
            let median = elapsed.sorted()[elapsed.count / 2]
            print(
                "RADIX_BENCH_DEFERRED_FILTERING_SUMMARY "
                    + "files=\(fileCount) included_stride=\(includedStride) "
                    + "config=\(configuration.name) iterations=\(elapsed.count) "
                    + "avg_elapsed=\(String(format: "%.6f", average))s "
                    + "median_elapsed=\(String(format: "%.6f", median))s "
                    + "min_elapsed=\(String(format: "%.6f", elapsed.min() ?? average))s "
                    + "max_elapsed=\(String(format: "%.6f", elapsed.max() ?? average))s"
            )
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_WIDE_FANOUT"] == "1",
            "Set RADIX_BENCH_WIDE_FANOUT=1 to run the fanout wide-directory benchmark."))
    func testFanoutWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let childDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_DIR_COUNTS"],
            defaultValues: [8]
        )
        let filesPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_FILES_PER_DIR"],
            defaultValues: [1_000]
        )
        let iterations =
            environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers =
            environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers =
            environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "coordinator-leaf-preparation",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                usesWorkerSideLeafPreparation: false
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "leaf-batch-256",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                leafPreparationBatchLimit: 256
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "leaf-batch-1024",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil,
                leafPreparationBatchLimit: 1_024
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-only",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            ),
        ]

        for childDirectoryCount in childDirectoryCounts {
            for filesPerDirectory in filesPerDirectoryCounts {
                let rootURL = try makeFanoutWideBenchmarkDirectory(
                    childDirectoryCount: childDirectoryCount,
                    filesPerDirectory: filesPerDirectory
                )
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let fileCount = childDirectoryCount * filesPerDirectory

                for configuration in configurations {
                    _ = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: 0,
                        isWarmup: true
                    )
                }

                var elapsedByConfiguration: [String: [Double]] = [:]
                for iteration in 1...iterations {
                    for configuration in Self.benchmarkConfigurationOrder(
                        configurations,
                        iteration: iteration
                    ) {
                        let elapsedSeconds = try await runWideDirectoryBenchmark(
                            rootURL: rootURL,
                            fileCount: fileCount,
                            configuration: configuration,
                            iteration: iteration,
                            isWarmup: false
                        )
                        elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                    }
                }

                for configuration in configurations {
                    let elapsed = elapsedByConfiguration[configuration.name, default: []]
                    guard !elapsed.isEmpty else { continue }
                    let average = elapsed.reduce(0, +) / Double(elapsed.count)
                    print(
                        """
                        RADIX_BENCH_WIDE_FANOUT_SUMMARY child_dirs=\(childDirectoryCount)
                        files_per_dir=\(filesPerDirectory)
                        files=\(fileCount)
                        config=\(configuration.name)
                        traversal_workers=\(configuration.traversalWorkerDescription)
                        requested_classification_workers=\(configuration.classificationWorkerDescription)
                        leaf_preparation=\(configuration.leafPreparationDescription)
                        leaf_batch_limit=\(configuration.leafPreparationBatchDescription)
                        iterations=\(elapsed.count)
                        avg_elapsed=\(String(format: "%.3f", average))s
                        min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                        max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                        """
                    )
                }
            }
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_DEEP_DIRECTORY"] == "1",
            "Set RADIX_BENCH_DEEP_DIRECTORY=1 to run the deep-directory benchmark."))
    func testDeepDirectoryScanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let depth =
            environment["RADIX_BENCH_DEEP_DEPTH"]
            .flatMap(Int.init)
            .map { min(max(1, $0), 400) } ?? 256
        let iterations =
            environment["RADIX_BENCH_DEEP_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let rootURL = try makeDeepBenchmarkDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for usesBulkEnumeration in [true, false] {
            _ = try await runDeepDirectoryBenchmark(
                rootURL: rootURL,
                depth: depth,
                usesBulkEnumeration: usesBulkEnumeration,
                iteration: 0,
                isWarmup: true
            )
        }

        var elapsedByMode: [Bool: [Double]] = [:]
        for iteration in 1...iterations {
            for usesBulkEnumeration in [true, false] {
                let elapsed = try await runDeepDirectoryBenchmark(
                    rootURL: rootURL,
                    depth: depth,
                    usesBulkEnumeration: usesBulkEnumeration,
                    iteration: iteration,
                    isWarmup: false
                )
                elapsedByMode[usesBulkEnumeration, default: []].append(elapsed)
            }
        }

        for usesBulkEnumeration in [true, false] {
            let elapsed = elapsedByMode[usesBulkEnumeration, default: []]
            let average = elapsed.reduce(0, +) / Double(elapsed.count)
            print(
                "RADIX_BENCH_DEEP_SUMMARY mode=\(usesBulkEnumeration ? "bulk" : "foundation") "
                    + "depth=\(depth) iterations=\(elapsed.count) "
                    + "avg_elapsed=\(String(format: "%.3f", average))s "
                    + "min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s "
                    + "max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s"
            )
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_ATOMIC_PROBE"] == "1",
            "Set RADIX_BENCH_ATOMIC_PROBE=1 to run the atomic-probe benchmark."))
    func testAtomicProbeResumeBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let directoryCount =
            environment["RADIX_BENCH_ATOMIC_PROBE_DIRS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 32
        let filesPerDirectory =
            environment["RADIX_BENCH_ATOMIC_PROBE_FILES_PER_DIR"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 200
        let minFileCount =
            environment["RADIX_BENCH_ATOMIC_PROBE_THRESHOLD"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 5_000
        let iterations =
            environment["RADIX_BENCH_ATOMIC_PROBE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let workerLimit =
            environment["RADIX_BENCH_ATOMIC_PROBE_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 8
        let fileCount = directoryCount * filesPerDirectory
        guard fileCount >= minFileCount else {
            throw TestFixtureError("Atomic-probe fixture must contain at least the threshold file count.")
        }

        let rootURL = try makeAtomicProbeBenchmarkDirectory(
            directoryCount: directoryCount,
            filesPerDirectory: filesPerDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntriesValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            ))
        let rootEntries = try #require(rootEntriesValue).entries

        for resumesProbe in [false, true] {
            _ = try await runAtomicProbeBenchmark(
                rootURL: rootURL,
                rootEntries: rootEntries,
                rootMetadata: rootMetadata,
                expectedFileCount: fileCount,
                minFileCount: minFileCount,
                workerLimit: workerLimit,
                resumesProbe: resumesProbe
            )
        }

        var elapsedByMode: [Bool: [Double]] = [:]
        for iteration in 1...iterations {
            for resumesProbe in [false, true] {
                let elapsed = try await runAtomicProbeBenchmark(
                    rootURL: rootURL,
                    rootEntries: rootEntries,
                    rootMetadata: rootMetadata,
                    expectedFileCount: fileCount,
                    minFileCount: minFileCount,
                    workerLimit: workerLimit,
                    resumesProbe: resumesProbe
                )
                elapsedByMode[resumesProbe, default: []].append(elapsed)
                print(
                    "RADIX_BENCH_ATOMIC_PROBE_RESULT mode=\(resumesProbe ? "resume" : "restart") iteration=\(iteration) elapsed=\(String(format: "%.3f", elapsed))s"
                )
            }
        }

        for resumesProbe in [false, true] {
            let elapsed = elapsedByMode[resumesProbe, default: []]
            let average = elapsed.reduce(0, +) / Double(elapsed.count)
            print(
                "RADIX_BENCH_ATOMIC_PROBE_SUMMARY mode=\(resumesProbe ? "resume" : "restart") files=\(fileCount) threshold=\(minFileCount) workers=\(workerLimit) iterations=\(elapsed.count) avg_elapsed=\(String(format: "%.3f", average))s"
            )
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_PACKAGE_CLASSIFIER"] == "1",
            "Set RADIX_BENCH_PACKAGE_CLASSIFIER=1 to run the package-classifier benchmark."))
    func testPackageClassifierBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        let directoryCount =
            environment["RADIX_BENCH_PACKAGE_CLASSIFIER_DIRS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 10_000
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-package-classifier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var directoryURLs: [URL] = []
        directoryURLs.reserveCapacity(directoryCount)
        for index in 0..<directoryCount {
            let name: String
            if index.isMultiple(of: 1_000) {
                name = "Candidate-\(index).app"
            } else if index.isMultiple(of: 997) {
                name = "Ambiguous-\(index).radixunknown"
            } else if index.isMultiple(of: 2) {
                name = "Ordinary-\(index).txt"
            } else {
                name = "Extensionless-\(index)"
            }
            let url = rootURL.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directoryURLs.append(url)
        }

        let legacyStart = ContinuousClock.now
        let legacyValues = directoryURLs.map { url in
            (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
        let legacyElapsed = Self.elapsedSeconds(since: legacyStart)

        let counter = PackageClassifierBenchmarkCounter()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counter.recordLookup()
            return try? url.resourceValues(forKeys: [.isPackageKey]).isPackage
        })
        let coldStart = ContinuousClock.now
        let coldValues = directoryURLs.map {
            classifier.classification(for: $0, hasFinderPackageFlag: false).isPackage
        }
        let coldElapsed = Self.elapsedSeconds(since: coldStart)
        let coldLookups = counter.lookupCount

        let warmStart = ContinuousClock.now
        let warmValues = directoryURLs.map {
            classifier.classification(for: $0, hasFinderPackageFlag: false).isPackage
        }
        let warmElapsed = Self.elapsedSeconds(since: warmStart)
        let warmLookups = counter.lookupCount - coldLookups

        #expect(coldValues == legacyValues)
        #expect(warmValues == legacyValues)
        let extensionlessCount = directoryURLs.count { $0.pathExtension.isEmpty }
        let foundationExtensionCount = Set(
            directoryURLs.lazy.map(\.pathExtension).filter { !$0.isEmpty && $0 != "txt" }
        ).count
        #expect(coldLookups == extensionlessCount + foundationExtensionCount)
        #expect(warmLookups == extensionlessCount)
        #expect(coldLookups < directoryCount)
        let reduction = 100 * (1 - Double(coldLookups) / Double(directoryCount))
        print(
            "RADIX_BENCH_PACKAGE_CLASSIFIER dirs=\(directoryCount) legacy_elapsed=\(String(format: "%.3f", legacyElapsed))s cold_elapsed=\(String(format: "%.3f", coldElapsed))s warm_elapsed=\(String(format: "%.3f", warmElapsed))s cold_foundation_lookups=\(coldLookups) warm_foundation_lookups=\(warmLookups) lookup_reduction=\(String(format: "%.1f", reduction))%"
        )
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_PACKAGE_SUMMARY"] == "1",
            "Set RADIX_BENCH_PACKAGE_SUMMARY=1 to run the package summary benchmark."))
    func testPackageSummaryBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let directoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_DIR_COUNTS"],
            defaultValues: [16]
        )
        let filesPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_FILES_PER_DIR"],
            defaultValues: [2_500]
        )
        let symlinksPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_SYMLINKS_PER_DIR"],
            defaultValues: [0]
        )
        let iterations =
            environment["RADIX_BENCH_PACKAGE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let summaryWorkers =
            environment["RADIX_BENCH_PACKAGE_SUMMARY_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 8

        let configurations = [
            PackageSummaryBenchmarkConfiguration(name: "default-policy", atomicSummaryWorkerLimit: nil),
            PackageSummaryBenchmarkConfiguration(name: "serial-summary", atomicSummaryWorkerLimit: 1),
            PackageSummaryBenchmarkConfiguration(name: "parallel-summary", atomicSummaryWorkerLimit: summaryWorkers),
        ]

        for directoryCount in directoryCounts {
            for filesPerDirectory in filesPerDirectoryCounts {
                for symlinksPerDirectory in symlinksPerDirectoryCounts {
                    let rootURL = try makePackageSummaryBenchmarkDirectory(
                        directoryCount: directoryCount,
                        filesPerDirectory: filesPerDirectory,
                        symlinksPerDirectory: symlinksPerDirectory
                    )
                    defer { try? FileManager.default.removeItem(at: rootURL) }
                    let fileCount = directoryCount * filesPerDirectory + (symlinksPerDirectory > 0 ? directoryCount : 0)
                    let symlinkCount = directoryCount * symlinksPerDirectory

                    for configuration in configurations {
                        _ = try await runPackageSummaryBenchmark(
                            rootURL: rootURL,
                            fileCount: fileCount,
                            symlinkCount: symlinkCount,
                            packageCount: 1,
                            configuration: configuration,
                            iteration: 0,
                            isWarmup: true
                        )
                    }

                    var elapsedByConfiguration: [String: [Double]] = [:]
                    for iteration in 1...iterations {
                        for configuration in configurations {
                            let elapsedSeconds = try await runPackageSummaryBenchmark(
                                rootURL: rootURL,
                                fileCount: fileCount,
                                symlinkCount: symlinkCount,
                                packageCount: 1,
                                configuration: configuration,
                                iteration: iteration,
                                isWarmup: false
                            )
                            elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                        }
                    }

                    for configuration in configurations {
                        let elapsed = elapsedByConfiguration[configuration.name, default: []]
                        guard !elapsed.isEmpty else { continue }
                        let average = elapsed.reduce(0, +) / Double(elapsed.count)
                        print(
                            """
                            RADIX_BENCH_PACKAGE_SUMMARY dirs=\(directoryCount)
                            files_per_dir=\(filesPerDirectory)
                            symlinks_per_dir=\(symlinksPerDirectory)
                            files=\(fileCount)
                            symlinks=\(symlinkCount)
                            config=\(configuration.name)
                            summary_workers=\(configuration.workerDescription)
                            iterations=\(elapsed.count)
                            avg_elapsed=\(String(format: "%.3f", average))s
                            min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                            max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                            """
                        )
                    }
                }
            }
        }

        let siblingPackageCount =
            environment["RADIX_BENCH_PACKAGE_SIBLING_COUNT"]
            .flatMap(Int.init)
            .map { max(2, $0) } ?? 32
        let siblingFilesPerPackage =
            environment["RADIX_BENCH_PACKAGE_SIBLING_FILES"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 64
        let siblingRootURL = try makeSiblingPackageSummaryBenchmarkDirectory(
            packageCount: siblingPackageCount,
            filesPerPackage: siblingFilesPerPackage
        )
        defer { try? FileManager.default.removeItem(at: siblingRootURL) }
        let siblingFileCount = siblingPackageCount * siblingFilesPerPackage
        for configuration in configurations {
            _ = try await runPackageSummaryBenchmark(
                rootURL: siblingRootURL,
                fileCount: siblingFileCount,
                symlinkCount: 0,
                packageCount: siblingPackageCount,
                configuration: configuration,
                iteration: 0,
                isWarmup: true
            )
            for iteration in 1...iterations {
                _ = try await runPackageSummaryBenchmark(
                    rootURL: siblingRootURL,
                    fileCount: siblingFileCount,
                    symlinkCount: 0,
                    packageCount: siblingPackageCount,
                    configuration: configuration,
                    iteration: iteration,
                    isWarmup: false
                )
            }
        }
    }

    private struct WideDirectoryBenchmarkConfiguration {
        let name: String
        let traversalWorkerLimit: Int?
        let classificationWorkerLimit: Int?
        let usesWorkerSideLeafPreparation: Bool
        let leafPreparationBatchLimit: Int?

        init(
            name: String,
            traversalWorkerLimit: Int?,
            classificationWorkerLimit: Int?,
            usesWorkerSideLeafPreparation: Bool = true,
            leafPreparationBatchLimit: Int? = nil
        ) {
            self.name = name
            self.traversalWorkerLimit = traversalWorkerLimit
            self.classificationWorkerLimit = classificationWorkerLimit
            self.usesWorkerSideLeafPreparation = usesWorkerSideLeafPreparation
            self.leafPreparationBatchLimit = leafPreparationBatchLimit
        }

        var traversalWorkerDescription: String {
            traversalWorkerLimit.map(String.init) ?? "default"
        }

        var classificationWorkerDescription: String {
            classificationWorkerLimit.map(String.init) ?? "default"
        }

        var leafPreparationDescription: String {
            usesWorkerSideLeafPreparation ? "worker-batches" : "coordinator"
        }

        var leafPreparationBatchDescription: String {
            guard usesWorkerSideLeafPreparation else { return "none" }
            return leafPreparationBatchLimit.map(String.init) ?? "default"
        }
    }

    private struct PackageSummaryBenchmarkConfiguration {
        let name: String
        let atomicSummaryWorkerLimit: Int?

        var workerDescription: String {
            atomicSummaryWorkerLimit.map(String.init) ?? "default"
        }
    }

    private struct DeferredFilteringBenchmarkConfiguration {
        let name: String
        let usesDeferredFiltering: Bool
    }

    private static func benchmarkConfigurationOrder(
        _ configurations: [WideDirectoryBenchmarkConfiguration],
        iteration: Int
    ) -> [WideDirectoryBenchmarkConfiguration] {
        iteration.isMultiple(of: 2) ? configurations : Array(configurations.reversed())
    }

    private static func integerList(from value: String?, defaultValues: [Int]) -> [Int] {
        guard let value else { return defaultValues }
        let parsed =
            value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        return parsed.isEmpty ? defaultValues : parsed
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        BenchmarkSupport.durationSeconds(start.duration(to: .now))
    }

    private static func resultFingerprint(_ store: FileTreeStore) -> String {
        scanResultFingerprint(store)
    }

    private func runRootMutationBenchmark(
        _ mutation: IncrementalBenchmarkRootMutation,
        directoryCount: Int,
        filesPerDirectory: Int
    ) async throws {
        let rootURL = try makeIncrementalBenchmarkDirectory(
            directoryCount: directoryCount,
            filesPerDirectory: filesPerDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let existingFileURL = rootURL.appending(path: "root-existing.dat")
        let createdFileURL = rootURL.appending(path: "root-created.dat")
        let event: FileSystemEventRecord
        let mutate: () throws -> Void
        switch mutation {
        case .create:
            event = FileSystemEventRecord(
                path: createdFileURL.path,
                eventID: 15,
                flags: [.itemCreated, .itemIsFile]
            )
            mutate = {
                try Data(repeating: 0x43, count: 8_192).write(to: createdFileURL)
            }
        case .modify:
            event = FileSystemEventRecord(
                path: existingFileURL.path,
                eventID: 15,
                flags: [.itemModified, .itemIsFile]
            )
            mutate = {
                try Data(repeating: 0x4D, count: 16_384).write(to: existingFileURL)
            }
        case .delete:
            event = FileSystemEventRecord(
                path: existingFileURL.path,
                eventID: 15,
                flags: [.itemRemoved, .itemIsFile]
            )
            mutate = {
                try FileManager.default.removeItem(at: existingFileURL)
            }
        }

        try await runIncrementalBenchmarkScenario(
            name: "root_\(mutation.rawValue)",
            rootURL: rootURL,
            events: [event],
            mutate: mutate
        )
    }

    private func runScatteredChangesBenchmark(
        changedDirectoryCount: Int,
        directoryCount: Int,
        filesPerDirectory: Int
    ) async throws {
        let rootURL = try makeIncrementalBenchmarkDirectory(
            directoryCount: directoryCount,
            filesPerDirectory: filesPerDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let changedFileURLs = (0..<changedDirectoryCount).map { directoryIndex in
            incrementalBenchmarkDirectoryURL(rootURL: rootURL, index: directoryIndex)
                .appending(path: "changed.dat")
        }
        let events = changedFileURLs.map { fileURL in
            FileSystemEventRecord(
                path: fileURL.path,
                eventID: 15,
                flags: [.itemCreated, .itemIsFile]
            )
        }

        try await runIncrementalBenchmarkScenario(
            name: "scattered_\(changedDirectoryCount)",
            rootURL: rootURL,
            events: events,
            mutate: {
                for fileURL in changedFileURLs {
                    try Data(repeating: 0x53, count: 8_192).write(to: fileURL)
                }
            }
        )
    }

    private func runIncrementalBenchmarkScenario(
        name: String,
        rootURL: URL,
        events: [FileSystemEventRecord],
        mutate: () throws -> Void
    ) async throws {
        let since = ScanIncrementalCheckpoint(volumeUUID: "benchmark-volume", eventID: 10)
        let through = ScanIncrementalCheckpoint(volumeUUID: "benchmark-volume", eventID: 20)
        let history = FileSystemEventHistory(since: since, through: through, events: events)
        let provider = IncrementalBenchmarkHistoryProvider(
            checkpoints: [
                since,
                through,
                ScanIncrementalCheckpoint(volumeUUID: "benchmark-volume", eventID: 30),
            ],
            history: history
        )
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let baseline = try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        )

        try mutate()
        let matcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path
        )
        let plan = IncrementalRescanPlanner().plan(
            history: history,
            target: target,
            treeStore: baseline.treeStore,
            exclusionMatcher: matcher
        )

        let incrementalStart = ContinuousClock.now
        let incremental = try await finishedSnapshot(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline
            )
        )
        let incrementalSeconds = Self.elapsedSeconds(since: incrementalStart)

        let fullStart = ContinuousClock.now
        let full = try await finishedSnapshot(
            target: target,
            options: options,
            engine: ScanEngine()
        )
        let fullSeconds = Self.elapsedSeconds(since: fullStart)

        let incrementalFingerprint = Self.resultFingerprint(incremental.treeStore)
        let fullFingerprint = Self.resultFingerprint(full.treeStore)
        assertEquivalentScanResults(
            incremental,
            full,
            incrementalFingerprint: incrementalFingerprint,
            fullFingerprint: fullFingerprint,
            scenario: name
        )

        print(
            """
            RADIX_BENCH_INCREMENTAL_RESULT scenario=\(name)
            plan=\(Self.description(of: plan))
            changed_paths=\(events.count)
            baseline_nodes=\(baseline.treeStore.nodeCount)
            result_nodes=\(incremental.treeStore.nodeCount)
            incremental_elapsed=\(String(format: "%.6f", incrementalSeconds))s
            full_elapsed=\(String(format: "%.6f", fullSeconds))s
            full_to_incremental_ratio=\(String(format: "%.3f", fullSeconds / max(incrementalSeconds, 0.000_001)))
            warnings=\(incremental.scanWarnings.count)
            fingerprint=\(incrementalFingerprint)
            """
        )
    }

    private func makeIncrementalBenchmarkDirectory(
        directoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: "radix-incremental-benchmark-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x42, count: 128)
        try payload.write(to: rootURL.appending(path: "root-existing.dat"))

        for directoryIndex in 0..<directoryCount {
            let directoryURL = incrementalBenchmarkDirectoryURL(
                rootURL: rootURL,
                index: directoryIndex
            )
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            for fileIndex in 0..<filesPerDirectory {
                try payload.write(
                    to: directoryURL.appending(
                        path: String(format: "file-%06d.dat", fileIndex)
                    ))
            }
        }
        return rootURL
    }

    private func incrementalBenchmarkDirectoryURL(rootURL: URL, index: Int) -> URL {
        rootURL.appending(
            path: String(format: "directory-%04d", index),
            directoryHint: .isDirectory
        )
    }

    private func assertEquivalentScanResults(
        _ incremental: ScanSnapshot,
        _ full: ScanSnapshot,
        incrementalFingerprint: String,
        fullFingerprint: String,
        scenario: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            incrementalFingerprint == fullFingerprint,
            "\(scenario): \(Self.firstDifference(incremental.treeStore, full.treeStore) ?? "fingerprint only")",
            sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.totalAllocatedSize == full.aggregateStats.totalAllocatedSize,
            Comment(rawValue: scenario), sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.totalLogicalSize == full.aggregateStats.totalLogicalSize,
            Comment(rawValue: scenario), sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.fileCount == full.aggregateStats.fileCount, Comment(rawValue: scenario),
            sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.directoryCount == full.aggregateStats.directoryCount,
            Comment(rawValue: scenario), sourceLocation: sourceLocation)
        #expect(
            Self.warningSignatures(incremental.scanWarnings) == Self.warningSignatures(full.scanWarnings),
            Comment(rawValue: scenario), sourceLocation: sourceLocation)
    }

    private static func warningSignatures(_ warnings: [ScanWarning]) -> [String] {
        warnings.map { "\($0.category.rawValue)|\($0.path)|\($0.message)" }.sorted()
    }

    private static func firstDifference(
        _ incremental: FileTreeStore,
        _ full: FileTreeStore
    ) -> String? {
        let incrementalIDs = incremental.indexedNodeIDs()
        let fullIDs = full.indexedNodeIDs()
        if incrementalIDs != fullIDs {
            let offset =
                zip(incrementalIDs, fullIDs).enumerated().first {
                    $0.element.0 != $0.element.1
                }?.offset ?? min(incrementalIDs.count, fullIDs.count)
            return "node order differs at \(offset)"
        }
        for nodeID in fullIDs {
            let incrementalNode = incremental.node(id: nodeID)
            let fullNode = full.node(id: nodeID)
            if incrementalNode != fullNode {
                if incrementalNode?.lastModified != fullNode?.lastModified {
                    return
                        "lastModified differs at \(nodeID) incremental=\(String(format: "%.9f", incrementalNode?.lastModified?.timeIntervalSinceReferenceDate ?? -1)) full=\(String(format: "%.9f", fullNode?.lastModified?.timeIntervalSinceReferenceDate ?? -1))"
                }
                return
                    "node metadata differs at \(nodeID) incremental=\(String(reflecting: incrementalNode)) full=\(String(reflecting: fullNode))"
            }
            if incremental.childIDs(of: nodeID) != full.childIDs(of: nodeID) {
                return "child order differs at \(nodeID)"
            }
        }
        return nil
    }

    private static func description(of plan: IncrementalRescanPlan) -> String {
        switch plan {
        case .noChanges:
            return "no_changes"
        case .update(let relistDirectoryIDs, let rescanSubtreeIDs):
            return "relist_\(relistDirectoryIDs.count)_subtrees_\(rescanSubtreeIDs.count)"
        case .fullScan(let reason):
            return "full_scan_\(reason.rawValue)"
        }
    }

    private func makeAtomicProbeBenchmarkDirectory(
        directoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-atomic-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: 32)
        for directoryIndex in 0..<directoryCount {
            let directoryURL = rootURL.appending(
                path: String(format: "shard-%04d", directoryIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerDirectory {
                try payload.write(
                    to: directoryURL.appending(path: String(format: "payload-%06d.dat", fileIndex))
                )
            }
        }
        return rootURL
    }

    private func makeDeepBenchmarkDirectory(depth: Int) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-deep-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        var directoryURL = rootURL
        for index in 0..<depth {
            directoryURL.append(path: "d", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try payload.write(
                to: directoryURL.appending(path: String(format: "f-%03d.dat", index))
            )
        }
        return rootURL
    }

    private func runDeepDirectoryBenchmark(
        rootURL: URL,
        depth: Int,
        usesBulkEnumeration: Bool,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        let engine: ScanEngine
        if usesBulkEnumeration {
            engine = ScanEngine()
        } else {
            engine = ScanEngine(directoryContents: { url, keys, enumerationOptions, cancellationCheck in
                try cancellationCheck()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions
                )
                try cancellationCheck()
                return contents
            })
        }

        let startedAt = ContinuousClock.now
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )
        let elapsed = Self.elapsedSeconds(since: startedAt)
        #expect(snapshot.aggregateStats.fileCount == depth)
        #expect(snapshot.aggregateStats.directoryCount == depth + 1)
        #expect(snapshot.treeStore.nodeCount == (depth * 2) + 1)

        print(
            "RADIX_BENCH_DEEP_RESULT phase=\(isWarmup ? "warmup" : "measure") "
                + "mode=\(usesBulkEnumeration ? "bulk" : "foundation") "
                + "depth=\(depth) iteration=\(iteration) "
                + "elapsed=\(String(format: "%.3f", elapsed))s"
        )
        return elapsed
    }

    private func runAtomicProbeBenchmark(
        rootURL: URL,
        rootEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        expectedFileCount: Int,
        minFileCount: Int,
        workerLimit: Int,
        resumesProbe: Bool
    ) async throws -> Double {
        let metadataLoader = ScanMetadataLoader()
        let pool = AtomicDirectorySummaryPool(
            workerLimit: workerLimit,
            progressEmissionInterval: 0
        )
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            summaryPool: pool
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: [],
            rootURL: rootURL
        )
        var progressContinuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let progressStream = AsyncThrowingStream<ScanProgressEvent, Error> { continuation in
            progressContinuation = continuation
        }
        defer { progressContinuation.finish() }
        var metrics = ScanMetrics()
        var emissionState = ScanEmissionState()
        let startedAt = ContinuousClock.now
        let summary: AtomicDirectorySummary?

        if resumesProbe {
            summary = try await summarizer.summaryDecisionIfNeeded(
                url: rootURL,
                childEntries: rootEntries,
                metadata: rootMetadata,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                isNodeDependencyLayout: true,
                minFileCount: minFileCount,
                maxAverageFileSize: 256,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation,
                emissionState: &emissionState
            ).summary
        } else {
            let outcome = try summarizer.descendantAtomicProbeProfile(
                at: rootURL,
                rootEntries: rootEntries,
                rootMetadata: rootMetadata,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                isNodeDependencyLayout: true,
                minFileCount: minFileCount,
                maxAverageFileSize: 256,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation,
                emissionState: &emissionState
            )
            #expect(
                outcome.profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: 256
                ))
            summary = try await summarizer.summarize(
                at: rootURL,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                ownerNodeID: rootURL.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation
            )
        }
        _ = progressStream

        #expect(summary?.descendantFileCount == expectedFileCount)
        let elapsed = startedAt.duration(to: .now)
        await pool.finish()
        return BenchmarkSupport.durationSeconds(elapsed)
    }

    private func makeWideBenchmarkDirectory(fileCount: Int) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for index in 0..<fileCount {
            let fileURL = rootURL.appending(path: String(format: "file-%08d.dat", index))
            try payload.write(to: fileURL, options: .atomic)
        }

        return rootURL
    }

    private func makeDeferredFilteringBenchmarkDirectory(
        fileCount: Int,
        includedStride: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: "radix-deferred-filtering-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for index in 0..<fileCount {
            let suffix = index.isMultiple(of: includedStride) ? "dat" : "tmp"
            try payload.write(
                to: rootURL.appending(path: String(format: "file-%08d.%@", index, suffix))
            )
        }
        return rootURL
    }

    private func makeFanoutWideBenchmarkDirectory(
        childDirectoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for directoryIndex in 0..<childDirectoryCount {
            let directoryURL = rootURL.appending(
                path: String(format: "group-%03d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<filesPerDirectory {
                let fileURL = directoryURL.appending(path: String(format: "file-%08d.dat", fileIndex))
                try payload.write(to: fileURL, options: .atomic)
            }
        }

        return rootURL
    }

    private func makePackageSummaryBenchmarkDirectory(
        directoryCount: Int,
        filesPerDirectory: Int,
        symlinksPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-package-summary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Payload.app", directoryHint: .isDirectory)
        let resourcesURL =
            packageURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for directoryIndex in 0..<directoryCount {
            let directoryURL = resourcesURL.appending(
                path: String(format: "bucket-%03d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let targetURL = directoryURL.appending(path: "symlink-target.dat")
            if symlinksPerDirectory > 0 {
                try payload.write(to: targetURL, options: .atomic)
            }
            for fileIndex in 0..<filesPerDirectory {
                let fileURL = directoryURL.appending(path: String(format: "asset-%08d.dat", fileIndex))
                try payload.write(to: fileURL, options: .atomic)
            }
            for symlinkIndex in 0..<symlinksPerDirectory {
                let symlinkURL = directoryURL.appending(path: String(format: "alias-%08d.dat", symlinkIndex))
                try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
            }
        }

        return rootURL
    }

    private func makeSiblingPackageSummaryBenchmarkDirectory(
        packageCount: Int,
        filesPerPackage: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-sibling-package-summary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let payload = Data([0x41])
        for packageIndex in 0..<packageCount {
            let packageURL = rootURL.appending(
                path: String(format: "Payload-%04d.app", packageIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerPackage {
                try payload.write(
                    to: packageURL.appending(path: String(format: "asset-%06d.dat", fileIndex)),
                    options: .atomic
                )
            }
        }
        return rootURL
    }

    private func runWideDirectoryBenchmark(
        rootURL: URL,
        fileCount: Int,
        configuration: WideDirectoryBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        var options = ScanOptions()
        options.directoryTraversalWorkerLimit = configuration.traversalWorkerLimit
        options.directoryClassificationWorkerLimit = configuration.classificationWorkerLimit

        let engine = ScanEngine(
            usesWorkerSideLeafPreparation: configuration.usesWorkerSideLeafPreparation,
            workerSideLeafPreparationBatchLimit: configuration.leafPreparationBatchLimit
        )
        let startedAt = ContinuousClock.now
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = BenchmarkSupport.durationSeconds(elapsed)
        let snapshot = try #require(finalSnapshot)
        #expect(snapshot.aggregateStats.fileCount == fileCount)
        #expect(snapshot.root.descendantFileCount == fileCount)

        let phase = isWarmup ? "warmup" : "measure"
        print(
            """
            RADIX_BENCH_WIDE_RESULT phase=\(phase)
            files=\(fileCount)
            config=\(configuration.name)
            iteration=\(iteration)
            traversal_workers=\(configuration.traversalWorkerDescription)
            requested_classification_workers=\(configuration.classificationWorkerDescription)
            leaf_preparation=\(configuration.leafPreparationDescription)
            leaf_batch_limit=\(configuration.leafPreparationBatchDescription)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            """
        )

        return elapsedSeconds
    }

    private func runDeferredFilteringBenchmark(
        rootURL: URL,
        fileCount: Int,
        includedStride: Int,
        configuration: DeferredFilteringBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> (elapsedSeconds: Double, fingerprint: String) {
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.exclusionPatterns = ["*.tmp"]
        let engine = ScanEngine(
            usesDeferredBulkEntryFiltering: configuration.usesDeferredFiltering
        )
        let startedAt = ContinuousClock.now
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let elapsedSeconds = Self.elapsedSeconds(since: startedAt)
        let expectedFileCount = (fileCount + includedStride - 1) / includedStride
        #expect(snapshot.aggregateStats.fileCount == expectedFileCount)
        #expect(snapshot.root.descendantFileCount == expectedFileCount)
        let fingerprint = Self.resultFingerprint(snapshot.treeStore)

        print(
            "RADIX_BENCH_DEFERRED_FILTERING_RESULT "
                + "phase=\(isWarmup ? "warmup" : "measure") "
                + "files=\(fileCount) included=\(expectedFileCount) "
                + "config=\(configuration.name) iteration=\(iteration) "
                + "elapsed=\(String(format: "%.6f", elapsedSeconds))s "
                + "fingerprint=\(fingerprint)"
        )
        return (elapsedSeconds, fingerprint)
    }

    private func runPackageSummaryBenchmark(
        rootURL: URL,
        fileCount: Int,
        symlinkCount: Int,
        packageCount: Int,
        configuration: PackageSummaryBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        var options = ScanOptions()
        options.atomicSummaryWorkerLimit = configuration.atomicSummaryWorkerLimit

        let workerProbe = PackageSummaryBenchmarkWorkerProbe()
        let engine = ScanEngine(
            atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver(
                didStart: workerProbe.didStart,
                didFinish: workerProbe.didFinish
            ))
        let startedAt = ContinuousClock.now
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = BenchmarkSupport.durationSeconds(elapsed)
        let snapshot = try #require(finalSnapshot)
        let packageNodes = snapshot.treeStore.children(of: snapshot.root.id).filter(\.isPackage)
        #expect(snapshot.aggregateStats.fileCount == fileCount)
        #expect(packageNodes.count == packageCount)
        #expect(packageNodes.reduce(0) { $0 + $1.descendantFileCount } == fileCount)
        #expect(packageNodes.allSatisfy { !snapshot.treeStore.childIDsByID.keys.contains($0.id) })
        if let configuredLimit = configuration.atomicSummaryWorkerLimit {
            #expect(workerProbe.peakWorkerCount <= configuredLimit)
        }

        let phase = isWarmup ? "warmup" : "measure"
        print(
            """
            RADIX_BENCH_PACKAGE_RESULT phase=\(phase)
            packages=\(packageCount)
            files=\(fileCount)
            symlinks=\(symlinkCount)
            config=\(configuration.name)
            iteration=\(iteration)
            summary_workers=\(configuration.workerDescription)
            peak_workers=\(workerProbe.peakWorkerCount)
            peak_concurrent_packages=\(workerProbe.peakOwnerCount)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            """
        )

        return elapsedSeconds
    }

    private func finishedSnapshot(
        target: ScanTarget,
        options: ScanOptions,
        engine: ScanEngine
    ) async throws -> ScanSnapshot {
        var finalSnapshot: ScanSnapshot?
        for try await event in engine.scan(target: target, options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }
        return try #require(finalSnapshot)
    }

    private func finishedSnapshot(
        from stream: AsyncThrowingStream<ScanProgressEvent, Error>
    ) async throws -> ScanSnapshot {
        for try await event in stream {
            if case .finished(let snapshot) = event {
                return snapshot
            }
        }
        Issue.record("Expected a finished scan snapshot")
        throw CancellationError()
    }

    private func assertWithinRelativeTolerance(
        _ first: Int64,
        _ second: Int64,
        tolerance: Double,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let denominator = max(Double(max(abs(first), abs(second))), 1)
        let relativeDifference = Double(abs(first - second)) / denominator
        #expect(
            relativeDifference <= tolerance, "Startup scanner \(label) differed by \(relativeDifference * 100)%",
            sourceLocation: sourceLocation)
    }
}

private enum IncrementalBenchmarkRootMutation: String, CaseIterable {
    case create
    case modify
    case delete
}

private final class IncrementalBenchmarkHistoryProvider: FileSystemEventHistoryProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var checkpoints: [ScanIncrementalCheckpoint]
    private let storedHistory: FileSystemEventHistory

    init(
        checkpoints: [ScanIncrementalCheckpoint],
        history: FileSystemEventHistory
    ) {
        self.checkpoints = checkpoints
        self.storedHistory = history
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        guard !checkpoints.isEmpty else {
            throw FileSystemEventHistoryError.eventIDUnavailable(targetURL.path)
        }
        return checkpoints.removeFirst()
    }

    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory {
        _ = targetURL
        precondition(since == storedHistory.since)
        precondition(through == storedHistory.through)
        return storedHistory
    }
}

private final class PackageClassifierBenchmarkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lookups
    }

    func recordLookup() {
        lock.lock()
        lookups += 1
        lock.unlock()
    }
}

private final class PackageSummaryBenchmarkWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWorkers = 0
    private var peakWorkers = 0
    private var activeCountsByOwner: [String: Int] = [:]
    private var peakOwners = 0

    var peakWorkerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakWorkers
    }

    var peakOwnerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakOwners
    }

    func didStart(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        lock.lock()
        activeWorkers += 1
        peakWorkers = max(peakWorkers, activeWorkers)
        activeCountsByOwner[ownerNodeID, default: 0] += 1
        peakOwners = max(peakOwners, activeCountsByOwner.count)
        lock.unlock()
    }

    func didFinish(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        lock.lock()
        activeWorkers = max(activeWorkers - 1, 0)
        let remaining = max(activeCountsByOwner[ownerNodeID, default: 0] - 1, 0)
        if remaining == 0 {
            activeCountsByOwner.removeValue(forKey: ownerNodeID)
        } else {
            activeCountsByOwner[ownerNodeID] = remaining
        }
        lock.unlock()
    }
}
