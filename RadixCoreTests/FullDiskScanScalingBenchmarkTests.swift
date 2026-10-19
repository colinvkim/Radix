import Darwin
import Foundation
import Testing

@testable import RadixCore

struct FullDiskScanScalingBenchmarkTests {
    @Test
    func testScenarioMatrixCoversCartesianProduct() throws {
        let scenarios = try BenchmarkScenario.allNames.map {
            try #require(BenchmarkScenario(rawValue: $0))
        }
        let combinations = Set(
            scenarios.map {
                "\($0.packagesExpanded)-\($0.automaticSummarization)-\($0.exclusionProfile.rawValue)"
            })

        #expect(scenarios.count == 12)
        #expect(combinations.count == 12)
        #expect(BenchmarkScenario(rawValue: "collapsed-auto-unknown") == nil)
    }

    @Test
    func testRepresentationIgnoresEphemeralDirectoriesOnlyUnderTarget() {
        #expect(Self.representationExcludedPath(forTarget: "/") == "/private/var/folders")
        #expect(Self.representationExcludedPath(forTarget: "/private") == "/private/var/folders")
        #expect(Self.representationExcludedPath(forTarget: "/Applications") == nil)
        #expect(Self.representationExcludedPath(forTarget: "/private/var/folders/ab/cd/T") == nil)

        func makeStore(temporaryChild: FileNodeRecord, applicationsChild: FileNodeRecord) -> FileTreeStore {
            let temporary = makeTestDirectoryNode(
                id: "/private/var/folders/ab/cd/T", name: "T", children: [temporaryChild])
            let applications = makeTestDirectoryNode(
                id: "/Applications", name: "Applications", children: [applicationsChild])
            let root = makeTestDirectoryNode(id: "/", name: "/", children: [applications, temporary])
            return FileTreeStore(root: root, childrenByID: [
                root.id: [applications, temporary],
                applications.id: [applicationsChild],
                temporary.id: [temporaryChild],
            ])
        }
        let app = makeTestDirectoryNode(id: "/Applications/Kept.app", name: "Kept.app", children: [], isPackage: true)
        let otherApp = makeTestDirectoryNode(id: "/Applications/Other.app", name: "Other.app", children: [], isPackage: true)
        let summarized = makeTestSummarizedDirectoryNode(
            id: "/private/var/folders/ab/cd/T/swift-generated-sources", name: "swift-generated-sources", size: 1)
        let temporaryPackage = makeTestDirectoryNode(
            id: "/private/var/folders/ab/cd/T/Build.app", name: "Build.app", children: [], isPackage: true)

        let excluded = "/private/var/folders"
        let first = Self.representationStats(
            makeStore(temporaryChild: summarized, applicationsChild: app), excludingDescendantsOf: excluded)
        let second = Self.representationStats(
            makeStore(temporaryChild: temporaryPackage, applicationsChild: app), excludingDescendantsOf: excluded)
        let changedOutside = Self.representationStats(
            makeStore(temporaryChild: summarized, applicationsChild: otherApp), excludingDescendantsOf: excluded)
        let unfiltered = Self.representationStats(
            makeStore(temporaryChild: temporaryPackage, applicationsChild: app), excludingDescendantsOf: nil)

        #expect(first.packageNodes == 1)
        #expect(first.autoSummarizedNodes == 0)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint != changedOutside.fingerprint)
        #expect(unfiltered.packageNodes == 2)
    }

    @Test
    func testRepresentationExcludesSummarizedEphemeralRoot() {
        let app = makeTestDirectoryNode(id: "/Applications/Kept.app", name: "Kept.app", children: [], isPackage: true)
        let summarized = makeTestSummarizedDirectoryNode(
            id: "/private/var/folders", name: "folders", size: 1, descendantFileCount: 3)
        let root = makeTestDirectoryNode(id: "/", name: "/", children: [app, summarized])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [app, summarized]])
        let filtered = Self.representationStats(store, excludingDescendantsOf: summarized.id)
        let unfiltered = Self.representationStats(store, excludingDescendantsOf: nil)
        let referenceRoot = makeTestDirectoryNode(id: "/", name: "/", children: [app])
        let reference = Self.representationStats(
            FileTreeStore(root: referenceRoot, childrenByID: [referenceRoot.id: [app]]),
            excludingDescendantsOf: nil
        )

        #expect(filtered.packageNodes == 1)
        #expect(filtered.autoSummarizedNodes == 0)
        #expect(filtered.summarizedDescendantFiles == 0)
        #expect(filtered.fingerprint == reference.fingerprint)
        #expect(unfiltered.autoSummarizedNodes == 1)
        #expect(unfiltered.summarizedDescendantFiles == 3)
    }

    @Test
    func testRootScanRequiresExplicitAuthorization() throws {
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let rootSymlinkURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: rootSymlinkURL,
            withDestinationURL: rootURL
        )
        defer { try? FileManager.default.removeItem(at: rootSymlinkURL) }
        let collapsedScenario = try #require(BenchmarkScenario(rawValue: "collapsed-auto-none"))
        let expandedScenario = try #require(BenchmarkScenario(rawValue: "expanded-auto-none"))

        #expect(
            BenchmarkSafetyPolicy.refusalReason(
                targetURL: rootURL,
                scenario: collapsedScenario,
                environment: [:]
            ) != nil)
        #expect(
            BenchmarkSafetyPolicy.refusalReason(
                targetURL: rootSymlinkURL,
                scenario: collapsedScenario,
                environment: [:]
            ) != nil)
        #expect(
            BenchmarkSafetyPolicy.refusalReason(
                targetURL: rootURL,
                scenario: collapsedScenario,
                environment: ["RADIX_BENCH_FULL_SCAN_ALLOW_ROOT": "1"]
            ) == nil)
        #expect(
            BenchmarkSafetyPolicy.refusalReason(
                targetURL: rootURL,
                scenario: expandedScenario,
                environment: ["RADIX_BENCH_FULL_SCAN_ALLOW_ROOT": "1"]
            ) != nil)
        #expect(
            BenchmarkSafetyPolicy.refusalReason(
                targetURL: rootURL,
                scenario: expandedScenario,
                environment: [
                    "RADIX_BENCH_FULL_SCAN_ALLOW_ROOT": "1",
                    "RADIX_BENCH_FULL_SCAN_ALLOW_EXPANDED_ROOT": "1",
                ]
            ) == nil)
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_FULL_SCAN_SCALING"] == "1",
            "Set RADIX_BENCH_FULL_SCAN_SCALING=1 to run the full-disk scaling benchmark."))
    func testFullDiskScanScalingBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenarioName =
            environment["RADIX_BENCH_FULL_SCAN_SCENARIO"]
            ?? "collapsed-auto-none"
        let scenario = try #require(BenchmarkScenario(rawValue: scenarioName))
        let targetURL = URL(
            filePath: environment["RADIX_BENCH_FULL_SCAN_PATH"] ?? "/Applications",
            directoryHint: .isDirectory
        ).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw TestFixtureError("Benchmark path does not exist: \(targetURL.path)")
        }
        if let refusalReason = BenchmarkSafetyPolicy.refusalReason(
            targetURL: targetURL,
            scenario: scenario,
            environment: environment
        ) {
            throw TestFixtureError(refusalReason)
        }

        let options = scenario.makeOptions()
        let completion = try await Self.measureCompletedScan(
            targetURL: targetURL,
            options: options
        )
        let measuresCancellation = environment["RADIX_BENCH_FULL_SCAN_CANCELLATION"] != "0"
        let cancellation: CancellationMeasurement?
        if measuresCancellation {
            let cancellationDelayMilliseconds = max(
                environment["RADIX_BENCH_FULL_SCAN_CANCEL_AFTER_MS"].flatMap(Int.init) ?? 250,
                1
            )
            cancellation = await Self.measureCancellation(
                targetURL: targetURL,
                options: options,
                delayMilliseconds: cancellationDelayMilliseconds,
                finalizationFraction: environment["RADIX_BENCH_FULL_SCAN_CANCEL_FINALIZATION_FRACTION"].flatMap(
                    Double.init)
            )
        } else {
            cancellation = nil
        }

        if let cancellation {
            #expect(cancellation.streamTerminated)
            #expect(cancellation.poolShutdown)
            #expect(cancellation.workersQuiescent)
            #expect(!(cancellation.emittedFinished))
            #expect(cancellation.unexpectedError == nil)
        }

        let record = BenchmarkRecord(
            round: environment["RADIX_BENCH_FULL_SCAN_ROUND"].flatMap(Int.init),
            sequenceIndex: environment["RADIX_BENCH_FULL_SCAN_SEQUENCE"].flatMap(Int.init),
            scenario: scenario.rawValue,
            path: targetURL.path,
            packagesExpanded: scenario.packagesExpanded,
            automaticSummarization: scenario.automaticSummarization,
            exclusionProfile: scenario.exclusionProfile.rawValue,
            exclusionPatternCount: options.exclusionPatterns.count,
            wallSeconds: completion.wallSeconds,
            userCPUSeconds: completion.userCPUSeconds,
            systemCPUSeconds: completion.systemCPUSeconds,
            startRSSBytes: completion.startRSSBytes,
            currentRSSBytes: completion.currentRSSBytes,
            peakRSSBytes: completion.peakRSSBytes,
            peakRSSIncreaseBytes: completion.peakRSSBytes >= completion.startRSSBytes
                ? completion.peakRSSBytes - completion.startRSSBytes
                : 0,
            retainedNodes: completion.retainedNodes,
            representationExcludedPath: completion.representationExcludedPath,
            packageNodes: completion.packageNodes,
            autoSummarizedNodes: completion.autoSummarizedNodes,
            summarizedDescendantFiles: completion.summarizedDescendantFiles,
            representationFingerprint: completion.representationFingerprint,
            enumeratedItems: completion.enumeratedItems,
            ordinaryDiscoveredItems: completion.ordinaryDiscoveredItems,
            ordinaryCompletedItems: completion.ordinaryCompletedItems,
            summaryAdditionalVisitedItems: completion.summaryAdditionalVisitedItems,
            metadataWorkItems: completion.metadataWorkItems,
            ordinaryDirectoryEnumerations: completion.ordinaryDirectoryEnumerations,
            filesVisited: completion.filesVisited,
            directoriesVisited: completion.directoriesVisited,
            aggregateFiles: completion.aggregateFiles,
            aggregateDirectories: completion.aggregateDirectories,
            allocatedBytes: completion.allocatedBytes,
            logicalBytes: completion.logicalBytes,
            progressEvents: completion.progressEvents,
            warningEvents: completion.warningEvents,
            warnings: completion.warnings,
            warningFingerprint: completion.warningFingerprint,
            warningOrderFingerprint: completion.warningOrderFingerprint,
            semanticFingerprint: completion.semanticFingerprint,
            treeFingerprint: completion.treeFingerprint,
            cancellationDelayMilliseconds: cancellation?.delayMilliseconds,
            cancellationLatencySeconds: cancellation?.latencySeconds,
            cancellationProgressObserved: cancellation?.progressObserved,
            cancellationStreamTerminated: cancellation?.streamTerminated,
            cancellationPoolShutdown: cancellation?.poolShutdown,
            cancellationWorkersQuiescent: cancellation?.workersQuiescent,
            cancellationEmittedFinished: cancellation?.emittedFinished,
            cancellationUnexpectedError: cancellation?.unexpectedError
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = String(decoding: try encoder.encode(record), as: UTF8.self)
        print("RADIX_BENCH_FULL_SCAN_SCALING_RESULT \(output)")
    }

    private static func measureCompletedScan(
        targetURL: URL,
        options: ScanOptions
    ) async throws -> CompletionMeasurement {
        let startRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        let sampler = BenchmarkMemorySampler(initialRSS: startRSS)
        let samplerTask = Task {
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { samplerTask.cancel() }
        let cpuAtStart = ProcessCPUTime.current()
        let startedAt = ContinuousClock.now
        var progressEvents = 0
        var warningEvents = 0
        var finalMetrics = ScanMetrics()
        var finalSnapshot: ScanSnapshot?
        let engine = ScanEngine()

        for try await event in engine.scan(
            target: ScanTarget(url: targetURL),
            options: options
        ) {
            switch event {
            case .executionMode:
                break
            case .progress(let metrics):
                finalMetrics = metrics
                progressEvents += 1
            case .warning:
                warningEvents += 1
            case .finished(let snapshot):
                finalSnapshot = snapshot
            }
        }

        let wallSeconds = BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        let cpuAtEnd = ProcessCPUTime.current()
        samplerTask.cancel()
        _ = await samplerTask.result
        sampler.sample()
        let currentRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        let snapshot = try #require(finalSnapshot)
        let representationExcludedPath = representationExcludedPath(forTarget: targetURL.path)
        let representation = representationStats(
            snapshot.treeStore,
            excludingDescendantsOf: representationExcludedPath
        )
        let ordinaryDiscoveredItems = max(finalMetrics.discoveredItems, 0)
        let summaryAdditionalVisitedItems = max(
            finalMetrics.completedSummaryAdditionalVisitedItemCount,
            0
        )
        let enumeratedItems = ScanIntegerMath.addingClamped(
            ordinaryDiscoveredItems,
            summaryAdditionalVisitedItems
        )
        let metadataWorkItems = ScanIntegerMath.addingClamped(
            max(finalMetrics.filesVisited, 0),
            max(finalMetrics.directoriesVisited, 0)
        )

        return CompletionMeasurement(
            wallSeconds: wallSeconds,
            userCPUSeconds: max(0, cpuAtEnd.userSeconds - cpuAtStart.userSeconds),
            systemCPUSeconds: max(0, cpuAtEnd.systemSeconds - cpuAtStart.systemSeconds),
            startRSSBytes: startRSS,
            currentRSSBytes: currentRSS,
            peakRSSBytes: max(sampler.peak(), currentRSS),
            retainedNodes: snapshot.treeStore.nodeCount,
            representationExcludedPath: representationExcludedPath,
            packageNodes: representation.packageNodes,
            autoSummarizedNodes: representation.autoSummarizedNodes,
            summarizedDescendantFiles: representation.summarizedDescendantFiles,
            representationFingerprint: representation.fingerprint,
            enumeratedItems: enumeratedItems,
            ordinaryDiscoveredItems: ordinaryDiscoveredItems,
            ordinaryCompletedItems: max(finalMetrics.completedItems, 0),
            summaryAdditionalVisitedItems: summaryAdditionalVisitedItems,
            metadataWorkItems: metadataWorkItems,
            ordinaryDirectoryEnumerations: max(finalMetrics.enumeratedDirectoryCount, 0),
            filesVisited: max(finalMetrics.filesVisited, 0),
            directoriesVisited: max(finalMetrics.directoriesVisited, 0),
            aggregateFiles: snapshot.aggregateStats.fileCount,
            aggregateDirectories: snapshot.aggregateStats.directoryCount,
            allocatedBytes: snapshot.aggregateStats.totalAllocatedSize,
            logicalBytes: snapshot.aggregateStats.totalLogicalSize,
            progressEvents: progressEvents,
            warningEvents: warningEvents,
            warnings: snapshot.scanWarnings.count,
            warningFingerprint: scanWarningFingerprint(snapshot.scanWarnings),
            warningOrderFingerprint: scanOrderedWarningFingerprint(snapshot.scanWarnings),
            semanticFingerprint: semanticFingerprint(snapshot),
            treeFingerprint: scanResultFingerprint(snapshot.treeStore)
        )
    }

    private static func measureCancellation(
        targetURL: URL,
        options: ScanOptions,
        delayMilliseconds: Int,
        finalizationFraction: Double?
    ) async -> CancellationMeasurement {
        let observation = CancellationObservation()
        let workerActivity = BenchmarkWorkerActivity()
        let engine = ScanEngine(
            atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver(
                didStart: { _, _ in workerActivity.didStart() },
                didFinish: { _, _ in workerActivity.didFinish() },
                didShutdown: { workerActivity.didShutdown() }
            ))
        let consumer = Task {
            var emittedFinished = false
            var unexpectedError: String?
            do {
                for try await event in engine.scan(
                    target: ScanTarget(url: targetURL),
                    options: options
                ) {
                    switch event {
                    case .progress(let metrics):
                        await observation.recordProgress(metrics)
                    case .finished:
                        emittedFinished = true
                    case .executionMode, .warning:
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                unexpectedError = String(describing: error)
            }
            await observation.recordTermination(
                emittedFinished: emittedFinished,
                unexpectedError: unexpectedError
            )
        }

        if let finalizationFraction {
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while await observation.observedFinalizationFraction() < finalizationFraction,
                await observation.outcome() == nil, ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(1))
            }
            let observed = await observation.observedFinalizationFraction()
            #expect(observed >= finalizationFraction)
            print("RADIX_BENCH_FINALIZATION_CANCEL observed_fraction=\(observed) delay_ms=\(delayMilliseconds)")
        }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        let clock = ContinuousClock()
        let cancellationStartedAt = clock.now
        consumer.cancel()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await observation.outcome() == nil || !workerActivity.hasShutdown,
            clock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let outcome = await observation.outcome()
        let latencySeconds = BenchmarkSupport.durationSeconds(cancellationStartedAt.duration(to: clock.now))

        return CancellationMeasurement(
            delayMilliseconds: delayMilliseconds,
            latencySeconds: latencySeconds,
            progressObserved: await observation.progressObserved(),
            streamTerminated: outcome != nil,
            poolShutdown: workerActivity.hasShutdown,
            workersQuiescent: workerActivity.isQuiescent,
            emittedFinished: outcome?.emittedFinished ?? false,
            unexpectedError: outcome?.unexpectedError
        )
    }

    private static func semanticFingerprint(_ snapshot: ScanSnapshot) -> String {
        var fingerprint = BenchmarkFingerprint()
        fingerprint.append(snapshot.target.url.path)
        fingerprint.append(snapshot.root.allocatedSize)
        fingerprint.append(snapshot.root.unduplicatedAllocatedSize)
        fingerprint.append(snapshot.root.dataAllocatedSize)
        fingerprint.append(snapshot.root.logicalSize)
        fingerprint.append(Int64(snapshot.aggregateStats.fileCount))
        fingerprint.append(scanWarningFingerprint(snapshot.scanWarnings))
        return fingerprint.description
    }

    /// Per-user temporary and cache directories. Build and test processes,
    /// including the ones running this benchmark, write there during a run, so
    /// auto-summary picks a different folder inside it from run to run.
    private static let ephemeralRootPath = "/private/var/folders"

    private static func representationExcludedPath(forTarget targetPath: String) -> String? {
        let targetPrefix = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
        return ephemeralRootPath.hasPrefix(targetPrefix) ? ephemeralRootPath : nil
    }

    /// Counts and fingerprints packages and auto-summarized folders outside
    /// `excludedPath`, so runs over the same disk compare equal.
    private static func representationStats(
        _ store: FileTreeStore,
        excludingDescendantsOf excludedPath: String?
    ) -> RepresentationStats {
        let excludedPrefix = excludedPath.map { $0 + "/" }
        var packageNodes = 0
        var autoSummarizedNodes = 0
        var summarizedDescendantFiles = 0
        var representedPaths: [String] = []
        for nodeIndex in store.indexedNodeIndices() {
            guard let node = store.node(at: nodeIndex),
                  node.isPackage || node.isAutoSummarized else { continue }
            if let excludedPrefix, node.id == excludedPath || node.id.hasPrefix(excludedPrefix) {
                continue
            }
            if node.isPackage {
                packageNodes += 1
            }
            if node.isAutoSummarized {
                autoSummarizedNodes += 1
            }
            summarizedDescendantFiles = ScanIntegerMath.addingClamped(
                summarizedDescendantFiles,
                max(node.descendantFileCount, 0)
            )
            representedPaths.append("\(node.isPackage ? "P" : "-")\(node.isAutoSummarized ? "S" : "-")\(node.id)")
        }
        var fingerprint = BenchmarkFingerprint()
        for path in representedPaths.sorted() {
            fingerprint.append(path)
        }
        return RepresentationStats(
            packageNodes: packageNodes,
            autoSummarizedNodes: autoSummarizedNodes,
            summarizedDescendantFiles: summarizedDescendantFiles,
            fingerprint: fingerprint.description
        )
    }

}

private enum BenchmarkSafetyPolicy {
    static func refusalReason(
        targetURL: URL,
        scenario: BenchmarkScenario,
        environment: [String: String]
    ) -> String? {
        guard targetURL.resolvingSymlinksInPath().standardizedFileURL.path == "/" else {
            return nil
        }
        guard environment["RADIX_BENCH_FULL_SCAN_ALLOW_ROOT"] == "1" else {
            return "Set RADIX_BENCH_FULL_SCAN_ALLOW_ROOT=1 to scan the startup volume."
        }
        let allowsExpandedRoot = environment["RADIX_BENCH_FULL_SCAN_ALLOW_EXPANDED_ROOT"] == "1"
        guard !scenario.packagesExpanded || allowsExpandedRoot else {
            return "Set RADIX_BENCH_FULL_SCAN_ALLOW_EXPANDED_ROOT=1 to expand packages at /."
        }
        return nil
    }
}

private struct BenchmarkScenario {
    enum ExclusionProfile: String {
        case none
        case noMatch = "no-match"
        case common
    }

    static let allNames = [
        "collapsed-auto-none",
        "collapsed-auto-no-match",
        "collapsed-auto-common",
        "collapsed-manual-none",
        "collapsed-manual-no-match",
        "collapsed-manual-common",
        "expanded-auto-none",
        "expanded-auto-no-match",
        "expanded-auto-common",
        "expanded-manual-none",
        "expanded-manual-no-match",
        "expanded-manual-common",
    ]

    let rawValue: String
    let packagesExpanded: Bool
    let automaticSummarization: Bool
    let exclusionProfile: ExclusionProfile

    init?(rawValue: String) {
        guard Self.allNames.contains(rawValue) else { return nil }
        self.rawValue = rawValue
        packagesExpanded = rawValue.hasPrefix("expanded-")
        automaticSummarization = rawValue.contains("-auto-")
        if rawValue.hasSuffix("-no-match") {
            exclusionProfile = .noMatch
        } else if rawValue.hasSuffix("-common") {
            exclusionProfile = .common
        } else {
            exclusionProfile = .none
        }
    }

    func makeOptions() -> ScanOptions {
        var options = ScanOptions()
        options.includeHiddenFiles = true
        options.treatPackagesAsDirectories = packagesExpanded
        options.autoSummarizeDirectories = automaticSummarization
        switch exclusionProfile {
        case .none:
            options.exclusionPatterns = []
        case .noMatch:
            options.exclusionPatterns = [
                "__radix_benchmark_no_match_71F2A8C4__/",
                "*.radix-benchmark-no-match-71F2A8C4",
                "Library/**/__radix_benchmark_no_match_71F2A8C4__/",
            ]
        case .common:
            options.exclusionPatterns = ScanExclusionMatcher.commonPresetPatterns
        }
        return options
    }
}

private struct CompletionMeasurement {
    let wallSeconds: Double
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let startRSSBytes: UInt64
    let currentRSSBytes: UInt64
    let peakRSSBytes: UInt64
    let retainedNodes: Int
    let representationExcludedPath: String?
    let packageNodes: Int
    let autoSummarizedNodes: Int
    let summarizedDescendantFiles: Int
    let representationFingerprint: String
    let enumeratedItems: Int
    let ordinaryDiscoveredItems: Int
    let ordinaryCompletedItems: Int
    let summaryAdditionalVisitedItems: Int
    let metadataWorkItems: Int
    let ordinaryDirectoryEnumerations: Int
    let filesVisited: Int
    let directoriesVisited: Int
    let aggregateFiles: Int
    let aggregateDirectories: Int
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let progressEvents: Int
    let warningEvents: Int
    let warnings: Int
    let warningFingerprint: String
    let warningOrderFingerprint: String
    let semanticFingerprint: String
    let treeFingerprint: String
}

private struct RepresentationStats {
    let packageNodes: Int
    let autoSummarizedNodes: Int
    let summarizedDescendantFiles: Int
    let fingerprint: String
}

private struct CancellationMeasurement {
    let delayMilliseconds: Int
    let latencySeconds: Double
    let progressObserved: Bool
    let streamTerminated: Bool
    let poolShutdown: Bool
    let workersQuiescent: Bool
    let emittedFinished: Bool
    let unexpectedError: String?
}

private struct BenchmarkRecord: Encodable {
    let round: Int?
    let sequenceIndex: Int?
    let scenario: String
    let path: String
    let packagesExpanded: Bool
    let automaticSummarization: Bool
    let exclusionProfile: String
    let exclusionPatternCount: Int
    let wallSeconds: Double
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let startRSSBytes: UInt64
    let currentRSSBytes: UInt64
    let peakRSSBytes: UInt64
    let peakRSSIncreaseBytes: UInt64
    let retainedNodes: Int
    let representationExcludedPath: String?
    let packageNodes: Int
    let autoSummarizedNodes: Int
    let summarizedDescendantFiles: Int
    let representationFingerprint: String
    let enumeratedItems: Int
    let ordinaryDiscoveredItems: Int
    let ordinaryCompletedItems: Int
    let summaryAdditionalVisitedItems: Int
    let metadataWorkItems: Int
    let ordinaryDirectoryEnumerations: Int
    let filesVisited: Int
    let directoriesVisited: Int
    let aggregateFiles: Int
    let aggregateDirectories: Int
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let progressEvents: Int
    let warningEvents: Int
    let warnings: Int
    let warningFingerprint: String
    let warningOrderFingerprint: String
    let semanticFingerprint: String
    let treeFingerprint: String
    let cancellationDelayMilliseconds: Int?
    let cancellationLatencySeconds: Double?
    let cancellationProgressObserved: Bool?
    let cancellationStreamTerminated: Bool?
    let cancellationPoolShutdown: Bool?
    let cancellationWorkersQuiescent: Bool?
    let cancellationEmittedFinished: Bool?
    let cancellationUnexpectedError: String?
}

private struct ProcessCPUTime {
    let userSeconds: Double
    let systemSeconds: Double

    static func current() -> ProcessCPUTime {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return ProcessCPUTime(userSeconds: 0, systemSeconds: 0)
        }
        return ProcessCPUTime(
            userSeconds: seconds(usage.ru_utime),
            systemSeconds: seconds(usage.ru_stime)
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

private actor CancellationObservation {
    struct Outcome {
        let emittedFinished: Bool
        let unexpectedError: String?
    }

    private var didObserveProgress = false
    private var finalizationFraction: Double = 0
    private var terminationOutcome: Outcome?

    func recordProgress(_ metrics: ScanMetrics) {
        didObserveProgress = true
        if metrics.isFinalizing { finalizationFraction = metrics.finalizationFraction }
    }

    func observedFinalizationFraction() -> Double { finalizationFraction }

    func recordTermination(emittedFinished: Bool, unexpectedError: String?) {
        terminationOutcome = Outcome(
            emittedFinished: emittedFinished,
            unexpectedError: unexpectedError
        )
    }

    func progressObserved() -> Bool {
        didObserveProgress
    }

    func outcome() -> Outcome? {
        terminationOutcome
    }
}

private final class BenchmarkWorkerActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWorkerCount = 0
    private var didObserveShutdown = false

    var hasShutdown: Bool {
        lock.withLock { didObserveShutdown }
    }

    var isQuiescent: Bool {
        lock.withLock { activeWorkerCount == 0 }
    }

    func didStart() {
        lock.withLock {
            activeWorkerCount += 1
        }
    }

    func didFinish() {
        lock.withLock {
            activeWorkerCount = max(activeWorkerCount - 1, 0)
        }
    }

    func didShutdown() {
        lock.withLock {
            didObserveShutdown = true
        }
    }
}

private struct BenchmarkFingerprint: CustomStringConvertible {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211
    private var value = Self.offsetBasis

    var description: String {
        String(format: "%016llx", value)
    }

    mutating func append(_ value: String) {
        append(UInt64(value.utf8.count))
        for byte in value.utf8 {
            append(byte)
        }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    private mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private mutating func append(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= Self.prime
    }
}
