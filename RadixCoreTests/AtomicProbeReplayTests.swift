import Darwin
import Dispatch
import Foundation
import Testing

@testable import RadixCore

struct AtomicProbeReplayTests {
    private enum DirectoryProbeBudget: CaseIterable {
        case minimum
        case scaled
        case maximum

        var minimumFileCount: Int {
            switch self {
            case .minimum: 3
            case .scaled: 1_024
            case .maximum: 4_096
            }
        }

        var directoryLimit: Int {
            switch self {
            case .minimum: 64
            case .scaled: 256
            case .maximum: 512
            }
        }
    }

    @Test(arguments: [false, true], DirectoryProbeBudget.allCases)
    private func testDirectoryOnlyProbeStopsAtBoundedDirectoryBudget(
        forceFallback: Bool,
        budget: DirectoryProbeBudget
    ) throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for index in 0...budget.directoryLimit {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: "empty-\(index)", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        let outcome = try probe(
            at: rootURL,
            minFileCount: budget.minimumFileCount,
            forcedBulkFailure: forceFallback ? BulkDirectoryEnumerator.ForcedFailure(batchCount: 0, errorCode: ENOTSUP) : nil,
            isNodeDependencyLayout: false
        )

        #expect(outcome.profile.observedDirectoryCount == budget.directoryLimit)
        #expect(outcome.profile.observedFileCount == 0)
        #expect(outcome.visitedItemCount == budget.directoryLimit)
        #expect(outcome.resumeState == nil)
        #expect(!outcome.fullyExhausted)
    }

    @Test(arguments: [false, true])
    func testDirectoryOnlyProbeVisitsEveryDirectoryBelowBudget(forceFallback: Bool) throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for index in 0..<63 {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: "empty-\(index)", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        let outcome = try probe(
            at: rootURL,
            minFileCount: 3,
            forcedBulkFailure: forceFallback ? BulkDirectoryEnumerator.ForcedFailure(batchCount: 0, errorCode: ENOTSUP) : nil,
            isNodeDependencyLayout: false
        )

        #expect(outcome.profile.observedDirectoryCount == 63)
        #expect(outcome.profile.observedFileCount == 0)
        #expect(outcome.visitedItemCount == 63)
        #expect(outcome.resumeState == nil)
    }

    @Test
    func testBulkProbeFailureFallsBackWithoutReplayState() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "files", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 3)
        let outcome = try probe(
            at: rootURL,
            minFileCount: 2,
            forcedBulkFailure: BulkDirectoryEnumerator.ForcedFailure(batchCount: 0, errorCode: ENOTSUP),
            maxAverageFileSize: 256
        )

        #expect(outcome.profile.observedDirectoryCount == 1)
        #expect(outcome.profile.observedFileCount == 2)
        #expect(outcome.profile.totalSampledLogicalSize == 256)
        #expect(outcome.visitedItemCount == 3)
        #expect(outcome.resumeState == nil)
        #expect(outcome.reusableDirectoryListings.isEmpty)
    }

    @Test
    func testThresholdRejectionReusesWholeMultiBatchDirectory() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1_600)
        let outcome = try probe(at: rootURL, minFileCount: 3)

        #expect(outcome.resumeState == nil)
        #expect(outcome.profile.observedFileCount == 3)
        #expect(outcome.visitedItemCount == 4)
        #expect(!outcome.fullyExhausted)
        let listing = try #require(outcome.reusableDirectoryListings[childURL.path])
        #expect(listing.entries.count == 1_600)
        #expect(listing.enumeratedItemCount == 1_600)
        #expect(listing.entries.reduce(Int64(0)) { $0 + ($1.metadata?.logicalSize ?? 0) } == 204_800)
        let reference = try probe(at: rootURL, minFileCount: 3, replayEntryLimit: 0)
        let replayed = try walkProbeReplay(at: rootURL, outcome: outcome)
        let restarted = try walkProbeReplay(at: rootURL, outcome: reference)
        #expect(replayed.nodes == restarted.nodes)
        #expect(replayed.nativeReopens == 0)
        #expect(restarted.nativeReopens == 1)
    }

    @Test
    func testRejectionSealsAncestorsAndKeepsCompletedSiblingWithoutOpeningTail() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let completedURL = rootURL.appending(path: "completed", directoryHint: .isDirectory)
        let branchURL = rootURL.appending(path: "branch", directoryHint: .isDirectory)
        let leafURL = branchURL.appending(path: "leaf", directoryHint: .isDirectory)
        let unopenedURL = rootURL.appending(path: "unopened", directoryHint: .isDirectory)
        try makeProbeFiles(at: completedURL, count: 1)
        try makeProbeFiles(at: leafURL, count: 1_600)
        try makeProbeFiles(at: unopenedURL, count: 1)
        #if DEBUG
        let diagnostics = ScanDiagnostics()
        #else
        let diagnostics: ScanDiagnosticsContext? = nil
        #endif
        let outcome = try probe(
            at: rootURL,
            minFileCount: 4,
            orderedChildNames: ["completed", "branch", "unopened"],
            diagnostics: diagnostics
        )

        #expect(outcome.profile.observedFileCount == 4)
        #expect(outcome.profile.observedDirectoryCount == 3)
        #expect(outcome.visitedItemCount == 7)
        #expect(!outcome.fullyExhausted)
        #expect(outcome.reusableDirectoryListings.count == 3)
        #expect(outcome.reusableDirectoryListings[completedURL.path]?.entries.count == 1)
        #expect(outcome.reusableDirectoryListings[branchURL.path]?.entries.count == 1)
        #expect(outcome.reusableDirectoryListings[leafURL.path]?.entries.count == 1_600)
        #expect(outcome.reusableDirectoryListings[unopenedURL.path] == nil)
        #if DEBUG
        #expect(try nativeCursorOpenCount(diagnostics, rootURL: rootURL) == 4)
        #endif
    }

    @Test
    func testReplayBudgetDropsOversizedPrefixAndRetainsFittingCompletedListing() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let completedURL = rootURL.appending(path: "completed", directoryHint: .isDirectory)
        let wideURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: completedURL, count: 1)
        try makeProbeFiles(at: wideURL, count: 1_600)
        let outcome = try probe(
            at: rootURL,
            minFileCount: 4,
            replayEntryLimit: 500,
            orderedChildNames: ["completed", "wide"]
        )
        let reference = try probe(
            at: rootURL,
            minFileCount: 4,
            replayEntryLimit: 0,
            orderedChildNames: ["completed", "wide"]
        )

        #expect(outcome.profile.observedFileCount == 4)
        #expect(outcome.visitedItemCount == reference.visitedItemCount)
        #expect(outcome.profile.totalSampledLogicalSize == reference.profile.totalSampledLogicalSize)
        #expect(outcome.reusableDirectoryListings.count == 1)
        #expect(outcome.reusableDirectoryListings[completedURL.path]?.entries.count == 1)
        #expect(outcome.reusableDirectoryListings[wideURL.path] == nil)
        let replayed = try walkProbeReplay(at: rootURL, outcome: outcome)
        let restarted = try walkProbeReplay(at: rootURL, outcome: reference)
        #expect(replayed.nodes == restarted.nodes)
        #expect(replayed.nodes.count { !$0.isDirectory } == 1_601)
        #expect(replayed.nodes.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.logicalSize } == 204_928)
        #expect(replayed.nativeReopens == 1)
        #expect(restarted.nativeReopens == 2)
    }

    @Test
    func testEmptyListingsConsumeReplayBudget() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for name in ["empty-a", "empty-b"] {
            try makeProbeFiles(at: rootURL.appending(path: name, directoryHint: .isDirectory), count: 0)
        }
        try makeProbeFiles(at: rootURL.appending(path: "wide", directoryHint: .isDirectory), count: 30)
        let outcome = try probe(
            at: rootURL,
            minFileCount: 3,
            replayEntryLimit: 1,
            orderedChildNames: ["empty-a", "empty-b", "wide"]
        )

        #expect(outcome.reusableDirectoryListings.count == 1)
        let listing = try #require(outcome.reusableDirectoryListings[rootURL.appending(path: "empty-a").path])
        #expect(listing.entries.isEmpty)
        #expect(listing.enumeratedItemCount == 0)
        #expect(outcome.profile.observedFileCount == 3)
        #expect(outcome.visitedItemCount == 6)
    }

    @Test(arguments: [EIO, ENOTSUP])
    func testLateDrainFailureDiscardsListingAndLeavesOrdinaryFailureHandling(errorCode: Int32) async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1_600)
        let failure = BulkDirectoryEnumerator.ForcedFailure(batchCount: 1, errorCode: errorCode)
        let outcome = try probe(at: rootURL, minFileCount: 3, forcedBulkFailure: failure)

        #expect(outcome.resumeState == nil)
        #expect(outcome.reusableDirectoryListings[childURL.path] == nil)
        #expect(outcome.profile.observedFileCount == 3)
        #expect(outcome.visitedItemCount == 4)
        #expect(!outcome.fullyExhausted)
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        let snapshot = try await replaySnapshot(
            at: childURL,
            options: options,
            engine: ScanEngine(forcedBulkFailure: failure)
        )
        if errorCode == ENOTSUP {
            #expect(snapshot.aggregateStats.fileCount == 1_600)
            #expect(snapshot.aggregateStats.totalLogicalSize == 204_800)
            #expect(snapshot.scanWarnings.isEmpty)
        } else {
            let cursor = try BulkDirectoryEnumerator.makeCursor(
                at: childURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                cancellationCheck: {}
            )
            defer { cursor.invalidate() }
            let batch = try cursor.nextBatch(cancellationCheck: {})
            let firstBatch = try #require(batch)
            #expect(firstBatch.entries.count < 1_600)
            #expect(snapshot.aggregateStats.fileCount == firstBatch.entries.count)
            #expect(snapshot.aggregateStats.totalLogicalSize == Int64(firstBatch.entries.count * 128))
            #expect(snapshot.scanWarnings.count == 1)
            #expect(snapshot.scanWarnings.first?.path == childURL.path)
            #expect(snapshot.scanWarnings.first?.category == .fileSystem)
        }
    }

    @Test
    func testCancellationDuringDrainPropagatesAndClosesCursor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1_600)
        let baseline = try fixtureDescriptorCount(at: childURL)
        let checks = CancellationProbe(throwOnCheck: Int.max)
        let reference = try probe(at: rootURL, minFileCount: 3, replayEntryLimit: 0, cancellationCheck: checks.check)
        #expect(reference.profile.observedFileCount == 3)
        let cancellation = CancellationProbe(throwOnCheck: checks.checkCount)

        #expect(throws: CancellationError.self) {
            try probe(at: rootURL, minFileCount: 3, cancellationCheck: cancellation.check)
        }
        #expect(try fixtureDescriptorCount(at: childURL) == baseline)
    }

    @Test
    func testRejectedOutcomeRetainsNoDescriptorAndAcceptedOutcomeStillResumes() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1_600)
        let baseline = try fixtureDescriptorCount(at: childURL)
        let outcomes = try (0..<3).map { _ in try probe(at: rootURL, minFileCount: 3) }
        try withExtendedLifetime(outcomes) {
            #expect(outcomes.allSatisfy { $0.reusableDirectoryListings[childURL.path]?.entries.count == 1_600 })
            let retainedDescriptorCount = try fixtureDescriptorCount(at: childURL)
            #expect(retainedDescriptorCount == baseline)
        }
        let accepted = try probe(at: rootURL, minFileCount: 3, maxAverageFileSize: 256)
        let resume = try #require(accepted.resumeState)
        #expect(accepted.profile.observedFileCount == 3)
        #expect(accepted.visitedItemCount == 4)
        #expect(resume.workItems.count == 2)
        #expect(resume.partial.descendantFileCount == 3)
        #expect(resume.partial.logicalSize == 384)
        #expect(try fixtureDescriptorCount(at: childURL) == baseline + 1)
        resume.invalidateCursors()
        #expect(try fixtureDescriptorCount(at: childURL) == baseline)
    }

    @Test
    func testProbeRejectsReplacedDirectoryIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1)
        let loader = ScanMetadataLoader()
        let discovered = DirectoryEntry(url: childURL, metadata: try loader.metadata(for: childURL))
        try FileManager.default.moveItem(at: childURL, to: rootURL.appending(path: "original"))
        try makeProbeFiles(at: childURL, count: 30)
        let outcome = try probe(at: rootURL, minFileCount: 3, rootEntries: [discovered])

        #expect(outcome.profile.observedDirectoryCount == 1)
        #expect(outcome.profile.observedFileCount == 0)
        #expect(outcome.visitedItemCount == 1)
        #expect(!outcome.fullyExhausted)
        #expect(outcome.reusableDirectoryListings[childURL.path] == nil)
    }

    #if DEBUG
    @Test
    func testProbePreservesFirmlinkIdentityException() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let firmlinkURL = URL(filePath: "/Users", directoryHint: .isDirectory)
        #expect(!ScanEngine.verifiesDirectoryIdentity(at: firmlinkURL))
        let discovered = DirectoryEntry(
            url: firmlinkURL,
            metadata: try ScanMetadataLoader().metadata(for: rootURL)
        )
        let diagnostics = ScanDiagnostics()
        let cancellation = CancellationProbe(throwOnCheck: 5)
        #expect(throws: CancellationError.self) {
            try probe(
                at: rootURL,
                minFileCount: 3,
                cancellationCheck: cancellation.check,
                rootEntries: [discovered],
                diagnostics: diagnostics
            )
        }
        #expect(try nativeCursorOpenCount(diagnostics, rootURL: rootURL) == 2)
    }
    #endif

    @Test
    func testEagerListingValidatesDiscoveredIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
        try makeProbeFiles(at: childURL, count: 1)
        let loader = ScanMetadataLoader()
        let staleIdentity = try loader.fileSystemIdentity(at: childURL)
        try FileManager.default.moveItem(at: childURL, to: rootURL.appending(path: "original"))
        try makeProbeFiles(at: childURL, count: 30)
        #expect(throws: NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE), userInfo: [NSURLErrorKey: childURL])) {
            try BulkDirectoryEnumerator.directoryEntries(
                at: childURL,
                expectedIdentity: staleIdentity,
                includeHiddenFiles: true,
                metadataLoader: loader,
                cancellationCheck: {}
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADIX_BENCH_REJECTED_PROBE"] == "1"))
    func testRejectedProbeReplayBenchmark() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let wideURL = rootURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: wideURL, count: 1_600)
        let limits = [0, 500, AtomicDirectoryProbeListing.retainedEntryLimit]
        let iterations = max(5, Int(ProcessInfo.processInfo.environment["RADIX_BENCH_ITERATIONS"] ?? "5") ?? 5)
        let reference = try walkProbeReplay(at: rootURL, outcome: probe(at: rootURL, minFileCount: 3, replayEntryLimit: 0))
        #expect(reference.nodes.count { !$0.isDirectory } == 1_600)
        #expect(reference.nodes.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.logicalSize } == 204_800)
        var elapsedSamples: [Int: [Double]] = [:]
        var probeSamples: [Int: [Double]] = [:]
        for iteration in -1..<iterations {
            let offset = max(0, iteration) % limits.count
            let orderedLimits = Array(limits[offset...] + limits[..<offset])
            for limit in orderedLimits {
                let start = DispatchTime.now().uptimeNanoseconds
                let outcome = try probe(at: rootURL, minFileCount: 3, replayEntryLimit: limit)
                let probeEnd = DispatchTime.now().uptimeNanoseconds
                let replayed = try walkProbeReplay(at: rootURL, outcome: outcome)
                let end = DispatchTime.now().uptimeNanoseconds
                #expect(outcome.profile.observedFileCount == 3)
                #expect(outcome.visitedItemCount == 4)
                #expect(outcome.resumeState == nil)
                #expect(replayed.nodes == reference.nodes)
                let expectedReopens = limit == AtomicDirectoryProbeListing.retainedEntryLimit ? 0 : 1
                #expect(replayed.nativeReopens == expectedReopens)
                if iteration >= 0 {
                    elapsedSamples[limit, default: []].append(Double(end - start) / 1_000_000)
                    probeSamples[limit, default: []].append(Double(probeEnd - start) / 1_000_000)
                }
            }
        }
        for limit in limits {
            let elapsed = try #require(elapsedSamples[limit]).sorted()
            let probeTimes = try #require(probeSamples[limit]).sorted()
            let reopens = limit == AtomicDirectoryProbeListing.retainedEntryLimit ? 0 : 1
            print("RADIX_REJECTED_PROBE budget=\(limit) runs=\(elapsed.count) files=1600 logical_bytes=204800 ordinary_native_reopens=\(reopens) total_ms_median=\(elapsed[elapsed.count / 2]) total_ms_min=\(elapsed[0]) total_ms_max=\(elapsed[elapsed.count - 1]) probe_ms_median=\(probeTimes[probeTimes.count / 2])")
        }
    }

    @Test
    func testRejectedReplayMatchesCompleteScanWithExclusionsHiddenFilesAndHardLinks() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cacheURL = rootURL.appending(path: "projects/cache", directoryHint: .isDirectory)
        let wideURL = cacheURL.appending(path: "wide", directoryHint: .isDirectory)
        try makeProbeFiles(at: wideURL, count: 1_600)
        try Data(repeating: 0x62, count: 8_192).write(to: wideURL.appending(path: "ignored.tmp"))
        try Data(repeating: 0x63, count: 8_192).write(to: wideURL.appending(path: ".hidden.bin"))
        try FileManager.default.linkItem(
            at: wideURL.appending(path: "payload-0.bin"),
            to: wideURL.appending(path: "hardlink.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: wideURL.appending(path: "cycle"),
            withDestinationURL: rootURL
        )
        var options = ScanOptions(includeHiddenFiles: false)
        options.exclusionPatterns = ["*.tmp"]
        options.autoSummarizeMinFileCount = 3
        options.autoSummarizeMaxAverageFileSize = 1
        options.autoSummarizeMinDepthForSummarization = 2
        let enabled = try await replaySnapshot(at: rootURL, options: options)
        options.autoSummarizeDirectories = false
        let disabled = try await replaySnapshot(at: rootURL, options: options)

        #expect(enabled.aggregateStats.fileCount == 1_601)
        #expect(enabled.aggregateStats.totalLogicalSize == 204_928 + Int64(rootURL.path.utf8.count))
        #expect(enabled.scanWarnings.isEmpty)
        #expect(enabled.treeStore.indexedNodeIDs() == disabled.treeStore.indexedNodeIDs())
        for id in disabled.treeStore.indexedNodeIDs() {
            #expect(enabled.treeStore.node(id: id) == disabled.treeStore.node(id: id), Comment(rawValue: id))
            #expect(enabled.treeStore.children(of: id).map(\.id) == disabled.treeStore.children(of: id).map(\.id))
        }
        #expect(enabled.aggregateStats.totalAllocatedSize == disabled.aggregateStats.totalAllocatedSize)
        #expect(enabled.aggregateStats.directoryCount == disabled.aggregateStats.directoryCount)
        #expect(enabled.aggregateStats.accessibleItemCount == disabled.aggregateStats.accessibleItemCount)
        #expect(enabled.aggregateStats.inaccessibleItemCount == disabled.aggregateStats.inaccessibleItemCount)
    }
}

private func makeProbeFiles(at directoryURL: URL, count: Int) throws {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    for index in 0..<count {
        try Data(repeating: 0x61, count: 128).write(to: directoryURL.appending(path: "payload-\(index).bin"))
    }
}

private func probe(
    at rootURL: URL,
    minFileCount: Int,
    replayEntryLimit: Int = AtomicDirectoryProbeListing.retainedEntryLimit,
    forcedBulkFailure: BulkDirectoryEnumerator.ForcedFailure? = nil,
    cancellationCheck: CancellationCheck = {},
    orderedChildNames: [String]? = nil,
    rootEntries suppliedRootEntries: [DirectoryEntry]? = nil,
    maxAverageFileSize: Int64 = 1,
    isNodeDependencyLayout: Bool = true,
    diagnostics: ScanDiagnosticsContext? = nil
) throws -> AtomicDirectoryProbeOutcome {
    let loader = ScanMetadataLoader(diagnostics: diagnostics)
    let rootMetadata = try loader.metadata(for: rootURL)
    let result = try BulkDirectoryEnumerator.directoryEntries(
        at: rootURL,
        includeHiddenFiles: true,
        metadataLoader: loader,
        cancellationCheck: {}
    )
    var rootEntries = try suppliedRootEntries ?? #require(result).entries
    if let orderedChildNames {
        rootEntries.sort {
            orderedChildNames.firstIndex(of: $0.url.lastPathComponent)!
                < orderedChildNames.firstIndex(of: $1.url.lastPathComponent)!
        }
    }
    let pool = AtomicDirectorySummaryPool(workerLimit: 1)
    let summarizer = AtomicDirectorySummarizer(metadataLoader: loader, summaryPool: pool)
    let (_, continuation) = AsyncThrowingStream<ScanProgressEvent, Error>.makeStream()
    defer { continuation.finish() }
    var metrics = ScanMetrics()
    var emissionState = ScanEmissionState()
    return try summarizer.descendantAtomicProbeProfile(
        at: rootURL,
        rootEntries: rootEntries,
        rootMetadata: rootMetadata,
        includeHiddenFiles: true,
        treatPackagesAsDirectories: false,
        isNodeDependencyLayout: isNodeDependencyLayout,
        minFileCount: minFileCount,
        maxAverageFileSize: maxAverageFileSize,
        exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
        cancellationCheck: cancellationCheck,
        metrics: &metrics,
        continuation: continuation,
        emissionState: &emissionState,
        replayEntryLimit: replayEntryLimit,
        forcedBulkFailure: forcedBulkFailure
    )
}

private func fixtureDescriptorCount(at directoryURL: URL) throws -> Int {
    let expected = try ScanMetadataLoader().fileSystemIdentity(at: directoryURL)
    return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").reduce(0) { count, name in
        guard let descriptor = Int32(name) else { return count }
        var status = stat()
        return count + (fstat(descriptor, &status) == 0 && FileIdentity(fileSystemStatus: status) == expected ? 1 : 0)
    }
}

private func replaySnapshot(
    at rootURL: URL,
    options: ScanOptions,
    engine: ScanEngine = ScanEngine()
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
        if case .finished(let snapshot) = event { return snapshot }
    }
    Issue.record("Expected a finished scan")
    throw CancellationError()
}

private func walkProbeReplay(
    at rootURL: URL,
    outcome: AtomicDirectoryProbeOutcome
) throws -> (nodes: [FileNodeRecord], nativeReopens: Int) {
    let loader = ScanMetadataLoader()
    let engine = ScanEngine()
    let rootResult = try BulkDirectoryEnumerator.directoryEntries(
        at: rootURL,
        includeHiddenFiles: true,
        metadataLoader: loader,
        cancellationCheck: {}
    )
    var pending = try #require(rootResult).entries
    var nodes: [FileNodeRecord] = []
    var nativeReopens = 0
    while let entry = pending.popLast() {
        let metadata = try #require(entry.metadata)
        nodes.append(engine.makeFileNode(url: entry.url, metadata: metadata))
        guard metadata.isDirectory else { continue }
        if let listing = outcome.reusableDirectoryListings[entry.url.path] {
            pending.append(contentsOf: listing.entries)
        } else {
            nativeReopens += 1
            let result = try BulkDirectoryEnumerator.directoryEntries(
                at: entry.url,
                includeHiddenFiles: true,
                metadataLoader: loader,
                cancellationCheck: {}
            )
            pending.append(contentsOf: try #require(result).entries)
        }
    }
    return (nodes.sorted { $0.id < $1.id }, nativeReopens)
}

#if DEBUG
private func nativeCursorOpenCount(_ diagnostics: ScanDiagnostics, rootURL: URL) throws -> Int {
    let report = diagnostics.makeReport(targetPath: rootURL.path, elapsedSeconds: 0)
    let line = try #require(report.split(separator: "\n").first { $0.contains("bulk.cursor.open: ") })
    let count = try #require(line.split(separator: " ").first { $0.hasPrefix("count=") })
    return try #require(Int(count.dropFirst("count=".count)))
}
#endif
