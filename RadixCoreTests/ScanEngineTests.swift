import Darwin
import XCTest
@testable import RadixCore

final class ScanEngineTests: XCTestCase {
    func testNativeAtomicWorkResultPreservesExcludedVisitedCount() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let nestedURL = rootURL.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 11).write(to: rootURL.appending(path: "visible.bin"))
        try Data(repeating: 0x22, count: 7).write(to: rootURL.appending(path: ".hidden.bin"))
        try Data(repeating: 0x33, count: 13).write(to: rootURL.appending(path: "ignored.tmp"))

        let metadataLoader = ScanMetadataLoader()
        let expectedIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let (progressReporter, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        let result = try AtomicDirectorySummarizer.processPooledWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: expectedIdentity
            ),
            includeHiddenFiles: false,
            exclusionMatcher: ScanExclusionMatcher(patterns: ["*.tmp"], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            forcesFoundationTraversal: false
        )

        XCTAssertEqual(result.partial.descendantFileCount, 1)
        XCTAssertEqual(result.partial.logicalSize, 11)
        XCTAssertEqual(result.partial.visitedItemCount, 3)
        XCTAssertTrue(result.partial.warnings.isEmpty)
        XCTAssertEqual(result.pendingItems.count, 1)
        XCTAssertEqual(
            result.pendingItems.first?.url.resolvingSymlinksInPath(),
            nestedURL.resolvingSymlinksInPath()
        )
    }

    func testFoundationAtomicWorkResultSeedsProtectedChildrenAndPreservesSemantics() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let nestedURL = rootURL.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 11).write(to: rootURL.appending(path: "visible.bin"))
        try Data(repeating: 0x22, count: 7).write(to: rootURL.appending(path: ".hidden.bin"))
        try Data(repeating: 0x33, count: 13).write(to: rootURL.appending(path: "ignored.tmp"))
        try Data(repeating: 0x44, count: 20).write(to: nestedURL.appending(path: "nested.bin"))

        let metadataLoader = ScanMetadataLoader()
        let expectedIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let (progressReporter, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        let rootResult = try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: expectedIdentity
            ),
            includeHiddenFiles: false,
            exclusionMatcher: ScanExclusionMatcher(patterns: ["*.tmp"], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0
        )

        XCTAssertEqual(rootResult.partial.descendantFileCount, 1)
        XCTAssertEqual(rootResult.partial.logicalSize, 11)
        XCTAssertEqual(rootResult.partial.visitedItemCount, 3)
        XCTAssertTrue(rootResult.partial.warnings.isEmpty)
        XCTAssertEqual(rootResult.pendingItems.count, 1)
        let childWork = try XCTUnwrap(rootResult.pendingItems.first)
        XCTAssertEqual(
            childWork.url.resolvingSymlinksInPath(),
            nestedURL.resolvingSymlinksInPath()
        )
        XCTAssertTrue(childWork.expectedIdentity?.isFileSystemIdentity == true)

        let childResult = try AtomicDirectorySummarizer.processFoundationWorkItem(
            childWork,
            includeHiddenFiles: false,
            exclusionMatcher: ScanExclusionMatcher(patterns: ["*.tmp"], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0
        )
        let accumulator = AtomicSummaryAccumulator(seed: rootResult.partial)
        accumulator.merge(childResult.partial)
        let summary = accumulator.makeSummary()
        XCTAssertEqual(summary.descendantFileCount, 2)
        XCTAssertEqual(summary.logicalSize, 31)
        XCTAssertEqual(summary.visitedItemCount, 4)
        XCTAssertTrue(summary.isAccessible)
        XCTAssertTrue(summary.warnings.isEmpty)
    }

    func testFoundationAtomicWorkResultStopsAtVolumeBoundary() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let boundaryURL = rootURL.appending(path: "Mounted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: boundaryURL, withIntermediateDirectories: true)
        try Data([0x11]).write(to: boundaryURL.appending(path: "foreign.bin"))

        let metadataLoader = ScanMetadataLoader()
        let rootIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let policy = try rejectingVolumeBoundaryPolicy(
            for: rootURL,
            metadataLoader: metadataLoader
        )
        let (progressReporter, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }

        let result = try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: rootIdentity,
                volumeBoundaryPolicy: policy
            ),
            includeHiddenFiles: true,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0
        )

        XCTAssertTrue(result.pendingItems.isEmpty)
        XCTAssertEqual(result.partial.descendantFileCount, 0)
        XCTAssertEqual(result.partial.logicalSize, 0)
        XCTAssertEqual(result.partial.warnings.count, 1)
        XCTAssertEqual(
            result.partial.warnings.first.map {
                URL(filePath: $0.path).resolvingSymlinksInPath().path
            },
            boundaryURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(result.partial.warnings.first?.category, .fileSystem)
    }

    func testPooledPackageSummaryStopsAtVolumeBoundary() async throws {
        let packageURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let boundaryURL = packageURL.appending(path: "Mounted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: boundaryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 7).write(to: packageURL.appending(path: "local.bin"))
        try Data(repeating: 0x22, count: 13).write(to: boundaryURL.appending(path: "foreign.bin"))

        let metadataLoader = ScanMetadataLoader()
        let rootIdentity = try metadataLoader.fileSystemIdentity(at: packageURL)
        let policy = try rejectingVolumeBoundaryPolicy(
            for: packageURL,
            metadataLoader: metadataLoader
        )
        let pool = AtomicDirectorySummaryPool(workerLimit: 2, progressEmissionInterval: 0)
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            summaryPool: pool,
            volumeBoundaryPolicy: policy
        )
        let (_, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        var metrics = ScanMetrics()

        let summary = try await summarizer.summarize(
            at: packageURL,
            treatPackagesAsDirectories: true,
            progressWeight: 1,
            progressKind: .package,
            ownerNodeID: packageURL.path,
            expectedRootIdentity: rootIdentity,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: packageURL),
            cancellationCheck: {},
            metrics: &metrics,
            continuation: continuation
        )
        await pool.finish()

        XCTAssertEqual(summary?.descendantFileCount, 1)
        XCTAssertEqual(summary?.logicalSize, 7)
        XCTAssertEqual(summary?.warnings.count, 1)
        XCTAssertEqual(summary?.warnings.first?.path, boundaryURL.path)
        XCTAssertEqual(summary?.warnings.first?.category, .fileSystem)
    }

    func testAutoSummaryProbeStopsAtVolumeBoundary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let boundaryURL = rootURL.appending(path: "Mounted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: boundaryURL, withIntermediateDirectories: true)
        try Data([0x11]).write(to: boundaryURL.appending(path: "foreign.bin"))

        let metadataLoader = ScanMetadataLoader()
        let policy = try rejectingVolumeBoundaryPolicy(
            for: rootURL,
            metadataLoader: metadataLoader
        )
        let pool = AtomicDirectorySummaryPool(workerLimit: 2, progressEmissionInterval: 0)
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            summaryPool: pool,
            volumeBoundaryPolicy: policy
        )
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let boundaryMetadata = try metadataLoader.metadata(for: boundaryURL)
        let rootEntries = [DirectoryEntry(
            url: boundaryURL,
            metadata: boundaryMetadata,
            isDirectoryHint: true
        )]
        let (_, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        var metrics = ScanMetrics()
        var emissionState = ScanEmissionState()

        let decision = try await summarizer.summaryDecisionIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: true,
            isNodeDependencyLayout: false,
            minFileCount: 1,
            maxAverageFileSize: 256,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            cancellationCheck: {},
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        )
        await pool.finish()

        XCTAssertNil(decision.summary)
    }

    func testFoundationAtomicWorkResultRejectsPreAndPostEnumerationReplacement() throws {
        let parentURL = try makeTemporaryDirectory()
        let foreignURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
            try? FileManager.default.removeItem(at: foreignURL)
        }
        let rootURL = parentURL.appending(path: "ReplaceMe", directoryHint: .isDirectory)
        let originalURL = parentURL.appending(path: "Original", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data([0x11]).write(to: rootURL.appending(path: "original.bin"))
        try Data([0x22]).write(to: foreignURL.appending(path: "foreign.bin"))

        let metadataLoader = ScanMetadataLoader()
        let expectedIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let (progressReporter, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        let matcher = ScanExclusionMatcher(patterns: [], rootURL: parentURL)
        let preMismatch = try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: FileIdentity(device: 0, inode: 0)
            ),
            includeHiddenFiles: true,
            exclusionMatcher: matcher,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0
        )
        XCTAssertEqual(preMismatch.partial.visitedItemCount, 0)
        XCTAssertEqual(preMismatch.partial.descendantFileCount, 0)
        XCTAssertTrue(preMismatch.pendingItems.isEmpty)
        XCTAssertEqual(preMismatch.partial.warnings.count, 1)
        XCTAssertEqual(preMismatch.partial.warnings.first?.category, .fileSystem)

        let postMismatch = try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                expectedIdentity: expectedIdentity
            ),
            includeHiddenFiles: true,
            exclusionMatcher: matcher,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0,
            directoryContents: { url, keys, options, cancellationCheck in
                try cancellationCheck()
                try FileManager.default.moveItem(at: rootURL, to: originalURL)
                try FileManager.default.createSymbolicLink(at: rootURL, withDestinationURL: foreignURL)
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [foreignURL.appending(path: "foreign.bin")]
                )
            }
        )
        XCTAssertEqual(postMismatch.partial.visitedItemCount, 1)
        XCTAssertEqual(postMismatch.partial.descendantFileCount, 0)
        XCTAssertEqual(postMismatch.partial.logicalSize, 0)
        XCTAssertTrue(postMismatch.pendingItems.isEmpty)
        XCTAssertEqual(postMismatch.partial.warnings.count, 1)
        XCTAssertEqual(postMismatch.partial.warnings.first?.path, rootURL.path)
        XCTAssertEqual(postMismatch.partial.warnings.first?.category, .fileSystem)
    }

    func testFoundationAtomicWorkResultSkipsChildWithoutFilesystemIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        let metadataLoader = ScanMetadataLoader(fileSystemInfoProvider: { _, _ in (nil, 1) })
        let (progressReporter, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }

        let result = try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path
            ),
            includeHiddenFiles: true,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            progressReporter: progressReporter,
            progressVisitedItemCount: 0
        )

        XCTAssertTrue(result.pendingItems.isEmpty)
        XCTAssertEqual(result.partial.warnings.count, 1)
        XCTAssertEqual(
            result.partial.warnings.first.map {
                URL(filePath: $0.path).resolvingSymlinksInPath().path
            },
            childURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(result.partial.warnings.first?.category, .fileSystem)
    }

    func testPooledFoundationRestartMatchesPooledSummary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let nestedURL = rootURL.appending(path: "Nested", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Payload.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let originalURL = rootURL.appending(path: "original.bin")
        try Data(repeating: 0x11, count: 64).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: nestedURL.appending(path: "linked.bin"))
        try Data(repeating: 0x22, count: 32).write(to: packageURL.appending(path: "asset.bin"))
        try Data(repeating: 0x33, count: 16).write(to: rootURL.appending(path: ".hidden.bin"))
        try Data(repeating: 0x44, count: 8).write(to: nestedURL.appending(path: "ignored.tmp"))
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "alias.bin"),
            withDestinationURL: originalURL
        )

        let metadataLoader = ScanMetadataLoader()
        let rootIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let matcher = ScanExclusionMatcher(patterns: ["*.tmp"], rootURL: rootURL)
        let (_, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        let pool = AtomicDirectorySummaryPool(workerLimit: 3, progressEmissionInterval: 0)
        let reference = try await pool.summarize(AtomicSummaryPoolRequest(
            url: rootURL,
            expectedRootIdentity: rootIdentity,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            progressWeight: 1,
            progressKind: .autoSummary,
            representedItemCount: 0,
            ownerNodeID: rootURL.path,
            exclusionMatcher: matcher,
            metadataLoader: metadataLoader,
            volumeBoundaryPolicy: .unrestricted,
            cancellationCheck: {},
            metrics: ScanMetrics(),
            continuation: continuation,
            resumeState: nil
        ))

        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 0
        )
        let restarted = try await pool.summarize(AtomicSummaryPoolRequest(
            url: rootURL,
            expectedRootIdentity: rootIdentity,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            progressWeight: 1,
            progressKind: .autoSummary,
            representedItemCount: 0,
            ownerNodeID: rootURL.path,
            exclusionMatcher: matcher,
            metadataLoader: metadataLoader,
            volumeBoundaryPolicy: .unrestricted,
            cancellationCheck: {},
            metrics: ScanMetrics(),
            continuation: continuation,
            resumeState: AtomicDirectoryProbeResumeState(
                partial: AtomicDirectorySummaryPartial(),
                workItems: [AtomicSummaryWorkItem(
                    url: rootURL,
                    treatPackagesAsDirectories: false,
                    ownerNodeID: rootURL.path,
                    expectedIdentity: rootIdentity,
                    cursor: cursor,
                    needsCursor: false,
                    requiresRootRestartOnFallback: true
                )],
                visitedItemCount: 0
            )
        ))
        await pool.finish()

        let referenceSummary = try XCTUnwrap(reference)
        let restartedSummary = try XCTUnwrap(restarted)
        XCTAssertEqual(restartedSummary.allocatedSize, referenceSummary.allocatedSize)
        XCTAssertEqual(restartedSummary.logicalSize, referenceSummary.logicalSize)
        XCTAssertEqual(restartedSummary.descendantFileCount, referenceSummary.descendantFileCount)
        XCTAssertEqual(restartedSummary.visitedItemCount, referenceSummary.visitedItemCount)
        XCTAssertEqual(restartedSummary.isAccessible, referenceSummary.isAccessible)
        XCTAssertEqual(
            warningSemantics(restartedSummary.warnings),
            warningSemantics(referenceSummary.warnings)
        )
        XCTAssertEqual(
            restartedSummary.sharedAllocationAccumulator.duplicateAllocatedSizeByOwner,
            referenceSummary.sharedAllocationAccumulator.duplicateAllocatedSizeByOwner
        )
        XCTAssertEqual(
            restartedSummary.sharedAllocationAccumulator.identityCount,
            referenceSummary.sharedAllocationAccumulator.identityCount
        )
    }

    func testLateNativeFallbackPreservesOriginalRootIdentity() async throws {
        let parentURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let rootURL = parentURL.appending(path: "Root", directoryHint: .isDirectory)
        let movedURL = parentURL.appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for index in 0..<128 {
            try Data([UInt8(index)]).write(to: rootURL.appending(path: "payload-\(index).bin"))
        }
        let metadataLoader = ScanMetadataLoader()
        let originalIdentity = try metadataLoader.fileSystemIdentity(at: rootURL)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 1
        )
        try FileManager.default.moveItem(at: rootURL, to: movedURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: rootURL.appending(path: "foreign.bin"))

        let (_, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }
        let pool = AtomicDirectorySummaryPool(workerLimit: 1, progressEmissionInterval: 0)
        let summary = try await pool.summarize(AtomicSummaryPoolRequest(
            url: rootURL,
            expectedRootIdentity: originalIdentity,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: true,
            progressWeight: 1,
            progressKind: .autoSummary,
            representedItemCount: 0,
            ownerNodeID: rootURL.path,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: metadataLoader,
            volumeBoundaryPolicy: .unrestricted,
            cancellationCheck: {},
            metrics: ScanMetrics(),
            continuation: continuation,
            resumeState: AtomicDirectoryProbeResumeState(
                partial: AtomicDirectorySummaryPartial(),
                workItems: [AtomicSummaryWorkItem(
                    url: rootURL,
                    treatPackagesAsDirectories: true,
                    ownerNodeID: rootURL.path,
                    expectedIdentity: originalIdentity,
                    cursor: cursor,
                    needsCursor: false,
                    requiresRootRestartOnFallback: true
                )],
                visitedItemCount: 0
            )
        ))
        await pool.finish()

        XCTAssertEqual(summary?.descendantFileCount, 0)
        XCTAssertEqual(summary?.logicalSize, 0)
        XCTAssertTrue(summary?.warnings.contains {
            $0.path == rootURL.path && $0.category == .fileSystem
        } == true)
    }

    func testFoundationAtomicWorkCancellationDoesNotReturnPartialWork() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let urls = try (0..<4).map { index in
            let url = rootURL.appending(path: "payload-\(index).bin")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let cancellation = AtomicFoundationCancellation(cancelAfterCheckCount: 3)
        let (_, continuation) = makeAtomicSummaryProgressReporter()
        defer { continuation.finish() }

        XCTAssertThrowsError(try AtomicDirectorySummarizer.processFoundationWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path
            ),
            includeHiddenFiles: true,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: cancellation.check,
            progressReporter: AtomicSummaryProgressReporter(
                metrics: ScanMetrics(),
                continuation: continuation
            ),
            progressVisitedItemCount: 0,
            directoryContents: { _, _, _, _ in
                ScanEngine.DirectoryEnumerationResult(urls: urls)
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPooledReusedEntriesReloadMissingPrefetchedMetadata() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appending(path: "payload.dat")
        try Data(repeating: 0xAB, count: 32).write(to: fileURL)

        var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        _ = AsyncThrowingStream<ScanProgressEvent, Error> {
            continuation = $0
        }
        let result = try AtomicDirectorySummarizer.processPooledWorkItem(
            AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                bufferedEntries: [DirectoryEntry(
                    url: fileURL,
                    metadata: nil,
                    localizedEnumerationError: CocoaError(.fileReadUnknown)
                )],
                needsCursor: false,
                reloadsMissingBufferedMetadata: true
            ),
            includeHiddenFiles: true,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {},
            progressReporter: AtomicSummaryProgressReporter(
                metrics: ScanMetrics(),
                continuation: continuation
            ),
            forcesFoundationTraversal: false
        )

        XCTAssertEqual(result.partial.descendantFileCount, 1)
        XCTAssertEqual(result.partial.logicalSize, 32)
        XCTAssertEqual(result.partial.visitedItemCount, 1)
        XCTAssertTrue(result.partial.warnings.isEmpty)
    }

    func testAtomicSummarySizeAccumulationClampsInsteadOfOverflowing() {
        var partial = AtomicDirectorySummaryPartial(
            allocatedSize: Int64.max,
            logicalSize: Int64.max,
            descendantFileCount: Int.max
        )
        let metadata = NodeMetadata(
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            logicalSize: 1,
            allocatedSize: 1,
            lastModified: nil,
            isReadable: true,
            volumeCapacity: nil,
            fileIdentity: nil,
            linkCount: 1
        )

        partial.accumulateFile(
            metadata,
            url: URL(filePath: "/overflow.bin"),
            ownerNodeID: "/"
        )

        XCTAssertEqual(partial.allocatedSize, Int64.max)
        XCTAssertEqual(partial.logicalSize, Int64.max)
        XCTAssertEqual(partial.descendantFileCount, Int.max)

        let accumulator = AtomicSummaryAccumulator(seed: partial)
        accumulator.merge(AtomicDirectorySummaryPartial(
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1
        ))
        let summary = accumulator.makeSummary()
        XCTAssertEqual(summary.allocatedSize, Int64.max)
        XCTAssertEqual(summary.logicalSize, Int64.max)
        XCTAssertEqual(summary.descendantFileCount, Int.max)
    }

    func testSummaryProgressThrottlePublishesOnlyWhenDueOrForced() async throws {
        let clock = AtomicSummaryProgressClock(
            Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let pool = AtomicDirectorySummaryPool(
            workerLimit: 1,
            progressEmissionInterval: 1,
            progressNow: clock.now
        )
        var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<ScanProgressEvent, Error> {
            continuation = $0
        }
        var firstMetrics = ScanMetrics()
        firstMetrics.progressFraction = 0.6
        firstMetrics.completedPackageSummaryCount = 1
        var throttledMetrics = ScanMetrics()
        throttledMetrics.progressFraction = 0.2
        throttledMetrics.completedPackageSummaryCount = 2
        var forcedMetrics = ScanMetrics()
        forcedMetrics.progressFraction = 0.1
        forcedMetrics.completedPackageSummaryCount = 3

        pool.updateProgress(firstMetrics, continuation: continuation, currentPath: "/first")
        pool.updateProgress(
            throttledMetrics,
            continuation: continuation,
            currentPath: "/throttled"
        )
        clock.advance(by: 1)
        pool.reportCurrentPath("/due", continuation: continuation)
        pool.reportCurrentPath("/throttled-again", continuation: continuation)
        pool.updateProgress(
            forcedMetrics,
            continuation: continuation,
            currentPath: "/forced",
            force: true
        )
        continuation.finish()

        var publications: [ScanMetrics] = []
        for try await event in stream {
            if case .progress(let publishedMetrics) = event {
                publications.append(publishedMetrics)
            }
        }

        XCTAssertEqual(publications.map(\.currentPath), ["/first", "/due", "/forced"])
        XCTAssertEqual(publications.map(\.completedPackageSummaryCount), [1, 2, 3])
        XCTAssertTrue(zip(publications, publications.dropFirst()).allSatisfy {
            $0.progressFraction <= $1.progressFraction
        })
    }

    func testSummaryCompletionPublishesBeforeCommittedBaseWithinThrottleInterval() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x11]).write(to: rootURL.appending(path: "payload.bin"))

        let clock = AtomicSummaryProgressClock(
            Date(timeIntervalSinceReferenceDate: 2_000)
        )
        let pool = AtomicDirectorySummaryPool(
            workerLimit: 1,
            progressEmissionInterval: 60,
            progressNow: clock.now
        )
        var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<ScanProgressEvent, Error> {
            continuation = $0
        }
        var queuedMetrics = ScanMetrics()
        queuedMetrics.discoveredItems = 1
        queuedMetrics.pendingPackageSummaryCount = 1
        queuedMetrics.recalculateProgress()
        pool.updateProgress(
            queuedMetrics,
            continuation: continuation,
            currentPath: "/queued"
        )

        let summary = try await pool.summarize(AtomicSummaryPoolRequest(
            url: rootURL,
            expectedRootIdentity: nil,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: true,
            progressWeight: 1,
            progressKind: .package,
            representedItemCount: 0,
            ownerNodeID: rootURL.path,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: ScanMetadataLoader(),
            volumeBoundaryPolicy: .unrestricted,
            cancellationCheck: {},
            metrics: queuedMetrics,
            continuation: continuation,
            resumeState: nil
        ))

        var committedMetrics = queuedMetrics
        committedMetrics.pendingPackageSummaryCount = 0
        committedMetrics.completedPackageSummaryCount = 1
        committedMetrics.completedPackageSummaryVisitedItemCount = summary?.visitedItemCount ?? 0
        committedMetrics.completedSummaryAdditionalVisitedItemCount = summary?.visitedItemCount ?? 0
        committedMetrics.completedItems = 1
        committedMetrics.completedTraversalWeight = 1
        committedMetrics.recalculateProgress()
        pool.updateProgress(
            committedMetrics,
            continuation: continuation,
            currentPath: "/committed",
            force: true
        )
        await pool.finish()
        continuation.finish()

        var publications: [ScanMetrics] = []
        for try await event in stream {
            if case .progress(let metrics) = event {
                publications.append(metrics)
            }
        }

        let completedSummary = try XCTUnwrap(summary)
        XCTAssertEqual(completedSummary.descendantFileCount, 1)
        XCTAssertEqual(publications.count, 3)
        XCTAssertEqual(publications[0].currentPath, "/queued")
        XCTAssertEqual(publications[1].activeAtomicSummaryCount, 1)
        XCTAssertEqual(publications[1].atomicSummaryCompletedTraversalWeight, 1)
        XCTAssertEqual(publications[1].atomicSummaryVisitedItems, completedSummary.visitedItemCount)
        XCTAssertEqual(publications[2].currentPath, "/committed")
        XCTAssertEqual(publications[2].activeAtomicSummaryCount, 0)
        XCTAssertEqual(publications[2].atomicSummaryVisitedItems, 0)
        XCTAssertEqual(publications[2].completedPackageSummaryCount, 1)
        XCTAssertTrue(zip(publications, publications.dropFirst()).allSatisfy {
            $0.progressFraction <= $1.progressFraction
        })
    }

    func testSummaryPathReportingPreservesCanonicalBaseMetrics() async throws {
        let pool = AtomicDirectorySummaryPool(
            workerLimit: 1,
            progressEmissionInterval: 0
        )
        var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<ScanProgressEvent, Error> {
            continuation = $0
        }
        var canonical = ScanMetrics()
        canonical.completedPackageSummaryCount = 1
        canonical.completedPackageSummaryVisitedItemCount = 400
        canonical.completedSummaryAdditionalVisitedItemCount = 400
        canonical.completedTraversalWeight = 0.4

        pool.updateProgress(canonical, continuation: continuation)
        pool.reportCurrentPath("/newer/worker/path", continuation: continuation)
        continuation.finish()

        var publications: [ScanMetrics] = []
        for try await event in stream {
            if case .progress(let metrics) = event {
                publications.append(metrics)
            }
        }

        XCTAssertEqual(publications.count, 2)
        XCTAssertTrue(publications.allSatisfy { $0.completedPackageSummaryCount == 1 })
        XCTAssertTrue(publications.allSatisfy {
            $0.completedSummaryAdditionalVisitedItemCount == 400
        })
        XCTAssertEqual(publications.last?.currentPath, "/newer/worker/path")
    }

    func testSummaryFallbackAdvancesProgressGenerationBeforeRestartedLease() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for index in 0..<128 {
            try Data([UInt8(index)]).write(
                to: rootURL.appending(path: "payload-\(index).dat")
            )
        }

        let metadataLoader = ScanMetadataLoader()
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 0
        )
        let resumeState = AtomicDirectoryProbeResumeState(
            partial: AtomicDirectorySummaryPartial(),
            workItems: [AtomicSummaryWorkItem(
                url: rootURL,
                treatPackagesAsDirectories: true,
                ownerNodeID: rootURL.path,
                cursor: cursor,
                needsCursor: false,
                requiresRootRestartOnFallback: true
            )],
            visitedItemCount: 0
        )
        let lifecycle = AtomicSummaryWorkerLifecycleProbe()
        let pool = AtomicDirectorySummaryPool(
            workerLimit: 1,
            workerObserver: AtomicSummaryWorkerObserver(
                didStart: { _, _ in lifecycle.didStart() },
                didFinish: { _, _ in lifecycle.didFinish() },
                didShutdown: { lifecycle.didShutdown() }
            ),
            progressEmissionInterval: 0
        )
        var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<ScanProgressEvent, Error> {
            continuation = $0
        }
        var base = ScanMetrics()
        base.discoveredItems = 1
        base.enumeratedDirectoryCount = 1
        base.pendingPackageSummaryCount = 1
        pool.updateProgress(base, continuation: continuation)

        let summary = try await pool.summarize(AtomicSummaryPoolRequest(
            url: rootURL,
            expectedRootIdentity: nil,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: true,
            progressWeight: 1,
            progressKind: .package,
            representedItemCount: 0,
            ownerNodeID: rootURL.path,
            exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
            metadataLoader: metadataLoader,
            volumeBoundaryPolicy: .unrestricted,
            cancellationCheck: {},
            metrics: base,
            continuation: continuation,
            resumeState: resumeState
        ))
        await pool.finish()
        await pool.finish()
        continuation.finish()

        var publications: [ScanMetrics] = []
        for try await event in stream {
            if case .progress(let metrics) = event {
                publications.append(metrics)
            }
        }

        XCTAssertEqual(summary?.descendantFileCount, 128)
        let firstRestartedVisit = try XCTUnwrap(publications.first {
            $0.atomicSummaryVisitedItems == 1 && $0.activePackageSummaryCount == 1
        })
        XCTAssertEqual(
            firstRestartedVisit.atomicSummaryEstimatedRemainingItems,
            ScanMetrics.unobservedSummaryEstimatedItemCount
        )
        XCTAssertEqual(lifecycle.activeWorkerCount, 0)
        XCTAssertTrue(lifecycle.didObserveShutdown)
        XCTAssertEqual(lifecycle.shutdownCount, 1)
        XCTAssertEqual(lifecycle.lastEvent, .shutdown)
    }

    func testLowDescriptorBudgetMatchesNormalScanAndStaysWithinPeak() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for branch in 0..<8 {
            let nestedURL = rootURL.appending(
                path: "Branch-\(branch)/Nested/Deep",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(branch), count: branch + 1).write(
                to: nestedURL.appending(path: "payload.bin")
            )
        }
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 4
        let reference = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let descriptorPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 2)
        let constrained = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        )

        let referenceIDs = reference.treeStore.indexedNodeIDs()
        XCTAssertEqual(constrained.treeStore.indexedNodeIDs(), referenceIDs)
        for nodeID in referenceIDs {
            XCTAssertEqual(constrained.treeStore.node(id: nodeID), reference.treeStore.node(id: nodeID), nodeID)
            XCTAssertEqual(
                constrained.treeStore.children(of: nodeID).map(\.id),
                reference.treeStore.children(of: nodeID).map(\.id),
                nodeID
            )
        }
        XCTAssertEqual(constrained.aggregateStats.totalAllocatedSize, reference.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(constrained.aggregateStats.totalLogicalSize, reference.aggregateStats.totalLogicalSize)
        XCTAssertEqual(constrained.aggregateStats.fileCount, reference.aggregateStats.fileCount)
        XCTAssertEqual(constrained.aggregateStats.directoryCount, reference.aggregateStats.directoryCount)
        XCTAssertEqual(constrained.aggregateStats.accessibleItemCount, reference.aggregateStats.accessibleItemCount)
        XCTAssertEqual(constrained.aggregateStats.inaccessibleItemCount, reference.aggregateStats.inaccessibleItemCount)
        let counters = descriptorPool.debugCounters
        XCTAssertLessThanOrEqual(counters.peakOpenDescriptorCount, 2)
        XCTAssertGreaterThan(counters.openatCallCount, 0)
        XCTAssertGreaterThan(counters.fallbackCount, 0)
        XCTAssertEqual(counters.currentOpenDescriptorCount, 0)
    }

    func testBoundedWorkerSideLeafPreparationMatchesCoordinatorPreparation() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let firstDirectoryURL = rootURL.appending(path: "First", directoryHint: .isDirectory)
        let secondDirectoryURL = rootURL.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectoryURL, withIntermediateDirectories: true)

        let originalURL = firstDirectoryURL.appending(path: "café.dat")
        try Data(repeating: 0x41, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(
            at: originalURL,
            to: secondDirectoryURL.appending(path: "hard-link.dat")
        )
        try FileManager.default.createSymbolicLink(
            at: firstDirectoryURL.appending(path: "alias.dat"),
            withDestinationURL: originalURL
        )
        try Data(repeating: 0x42, count: 128).write(
            to: secondDirectoryURL.appending(path: "ordinary.dat")
        )

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 4
        let workerSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(workerSideLeafPreparationBatchLimit: 1)
        )
        let coordinatorSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(usesWorkerSideLeafPreparation: false)
        )

        let nodeIDs = coordinatorSnapshot.treeStore.indexedNodeIDs()
        XCTAssertEqual(workerSnapshot.treeStore.indexedNodeIDs(), nodeIDs)
        XCTAssertEqual(
            workerSnapshot.treeStore.childIDsByID,
            coordinatorSnapshot.treeStore.childIDsByID
        )
        for nodeID in nodeIDs {
            XCTAssertEqual(
                workerSnapshot.treeStore.node(id: nodeID),
                coordinatorSnapshot.treeStore.node(id: nodeID),
                nodeID
            )
        }
        XCTAssertEqual(
            workerSnapshot.aggregateStats.totalAllocatedSize,
            coordinatorSnapshot.aggregateStats.totalAllocatedSize
        )
        XCTAssertEqual(
            workerSnapshot.aggregateStats.totalLogicalSize,
            coordinatorSnapshot.aggregateStats.totalLogicalSize
        )
        XCTAssertEqual(
            workerSnapshot.aggregateStats.fileCount,
            coordinatorSnapshot.aggregateStats.fileCount
        )
        XCTAssertEqual(
            workerSnapshot.aggregateStats.directoryCount,
            coordinatorSnapshot.aggregateStats.directoryCount
        )
        XCTAssertEqual(
            workerSnapshot.aggregateStats.accessibleItemCount,
            coordinatorSnapshot.aggregateStats.accessibleItemCount
        )
        XCTAssertEqual(
            workerSnapshot.aggregateStats.inaccessibleItemCount,
            coordinatorSnapshot.aggregateStats.inaccessibleItemCount
        )
        XCTAssertEqual(workerSnapshot.scanWarnings, coordinatorSnapshot.scanWarnings)
    }

    func testDirectorySymlinkSwapAfterDiscoveryIsRefused() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        let outsideFileURL = outsideURL.appending(path: "outside.bin")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data([0x5A]).write(to: outsideFileURL)

        let blocker = BlockingLiveChildOpen()
        let descriptorPool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 8,
            systemCalls: blocker.systemCalls
        )
        let scanTask = Task {
            try await finishedSnapshot(
                target: ScanTarget(url: rootURL),
                options: ScanOptions(),
                engine: ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
            )
        }
        defer {
            blocker.release()
            scanTask.cancel()
        }
        XCTAssertEqual(blocker.didReachChildOpen.wait(timeout: .now() + 2), .success)
        try FileManager.default.removeItem(at: childURL)
        try FileManager.default.createSymbolicLink(at: childURL, withDestinationURL: outsideURL)
        blocker.release()

        let snapshot = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }
        let childNode = try XCTUnwrap(snapshot.treeStore.node(id: childURL.path))
        XCTAssertFalse(childNode.isAccessible)
        XCTAssertNil(snapshot.treeStore.node(id: childURL.appending(path: "outside.bin").path))
        XCTAssertNil(snapshot.treeStore.node(id: outsideFileURL.path))
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertEqual(descriptorPool.debugCounters.currentOpenDescriptorCount, 0)
    }

    func testCancellingDescriptorRelativeScanClosesInFlightAndRetainedLeases() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data([0x4A]).write(to: childURL.appending(path: "payload.bin"))

        let blocker = BlockingLiveChildOpen()
        let descriptorPool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 8,
            systemCalls: blocker.systemCalls
        )
        let engine = ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        let scanTask = Task {
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event { return true }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return false
        }
        defer {
            blocker.release()
            scanTask.cancel()
        }
        XCTAssertEqual(blocker.didReachChildOpen.wait(timeout: .now() + 2), .success)

        scanTask.cancel()
        blocker.release()
        let didFinish = try await withTimeout(.seconds(2)) {
            await scanTask.value
        }

        XCTAssertFalse(didFinish)
        try await waitUntil("cancelled descriptor leases to close") {
            descriptorPool.debugCounters.currentOpenDescriptorCount == 0
        }
    }

    func testBulkDirectoryEnumerationRejectsIncompleteMetadataAttributeSets() {
        var returned = attribute_set_t()
        returned.commonattr = .max
        returned.fileattr = .max

        XCTAssertTrue(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VREG.rawValue))

        returned.fileattr &= ~attrgroup_t(ATTR_FILE_LINKCOUNT)
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VREG.rawValue))
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VLNK.rawValue))
        XCTAssertTrue(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VDIR.rawValue))

        returned.commonattr &= ~attrgroup_t(ATTR_CMN_OBJTYPE)
        XCTAssertFalse(BulkDirectoryEnumerator.hasRequiredMetadataAttributes(returned, objectType: VDIR.rawValue))
    }

    func testBulkDirectoryEnumerationMatchesScannerMetadataAndHiddenFiltering() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let directoryURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.bin")
        let hardLinkURL = rootURL.appending(path: "payload-link.bin")
        let symbolicLinkURL = rootURL.appending(path: "payload-alias")
        let hiddenURL = rootURL.appending(path: ".hidden")
        var flaggedHiddenURL = rootURL.appending(path: "flagged-hidden")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 4_097).write(to: fileURL)
        try FileManager.default.linkItem(at: fileURL, to: hardLinkURL)
        try FileManager.default.createSymbolicLink(at: symbolicLinkURL, withDestinationURL: fileURL)
        try Data([0x1]).write(to: hiddenURL)
        try Data([0x2]).write(to: flaggedHiddenURL)
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        try flaggedHiddenURL.setResourceValues(hiddenValues)

        let metadataLoader = ScanMetadataLoader()
        let visibleResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        let completeResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))

        XCTAssertEqual(visibleResult.enumeratedItemCount, 7)
        XCTAssertEqual(completeResult.enumeratedItemCount, 7)
        XCTAssertFalse(visibleResult.entries.contains { $0.url.lastPathComponent == ".hidden" })
        XCTAssertFalse(visibleResult.entries.contains { $0.url.lastPathComponent == "flagged-hidden" })
        XCTAssertTrue(completeResult.entries.contains { $0.url.lastPathComponent == ".hidden" })
        XCTAssertTrue(completeResult.entries.contains { $0.url.lastPathComponent == "flagged-hidden" })

        let entriesByName = Dictionary(uniqueKeysWithValues: completeResult.entries.map {
            ($0.url.lastPathComponent, $0)
        })
        let fileMetadata = try XCTUnwrap(entriesByName["payload.bin"]?.metadata)
        let linkMetadata = try XCTUnwrap(entriesByName["payload-link.bin"]?.metadata)
        let symlinkMetadata = try XCTUnwrap(entriesByName["payload-alias"]?.metadata)
        let directoryMetadata = try XCTUnwrap(entriesByName["Folder"]?.metadata)
        let loadedDirectoryMetadata = try metadataLoader.metadata(for: directoryURL)

        XCTAssertEqual(directoryMetadata.lastModified, loadedDirectoryMetadata.lastModified)
        let packageMetadata = try XCTUnwrap(entriesByName["Sample.app"]?.metadata)
        let foundationFileMetadata = try metadataLoader.metadata(for: fileURL)

        XCTAssertEqual(fileMetadata.logicalSize, foundationFileMetadata.logicalSize)
        XCTAssertEqual(fileMetadata.allocatedSize, foundationFileMetadata.allocatedSize)
        XCTAssertEqual(fileMetadata.linkCount, foundationFileMetadata.linkCount)
        XCTAssertEqual(fileMetadata.fileIdentity, linkMetadata.fileIdentity)
        XCTAssertGreaterThan(fileMetadata.linkCount, 1)
        XCTAssertTrue(symlinkMetadata.isSymbolicLink)
        XCTAssertTrue(directoryMetadata.isDirectory)
        XCTAssertFalse(directoryMetadata.isPackage)
        XCTAssertTrue(packageMetadata.isDirectory)
        XCTAssertTrue(packageMetadata.isPackage)
    }

    func testBulkDirectoryCursorStreamsAndCancelsBetweenBatches() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<1_200 {
            try Data([UInt8(index % 256)]).write(
                to: rootURL.appending(path: String(format: "streamed-%06d-with-padding-payload.dat", index))
            )
        }

        let metadataLoader = ScanMetadataLoader()
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )
        var names: Set<String> = []
        var batchCount = 0
        var maxBatchSize = 0
        var enumeratedItemCount = 0
        while let batch = try cursor.nextBatch(cancellationCheck: {}) {
            batchCount += 1
            maxBatchSize = max(maxBatchSize, batch.entries.count)
            enumeratedItemCount += batch.enumeratedItemCount
            names.formUnion(batch.entries.map(\.url.lastPathComponent))
        }

        XCTAssertGreaterThan(batchCount, 1)
        XCTAssertLessThan(maxBatchSize, 1_200)
        XCTAssertEqual(enumeratedItemCount, 1_200)
        XCTAssertEqual(names.count, 1_200)

        let unavailableResult = try BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 1
        )
        XCTAssertNil(unavailableResult, "Late native fallback must discard earlier uncommitted batches.")

        let cancellation = DirectoryEnumerationCancellation()
        let cancellingCursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellation.check
        )
        let firstBatch = try XCTUnwrap(cancellingCursor.nextBatch(cancellationCheck: cancellation.check))
        XCTAssertLessThan(firstBatch.enumeratedItemCount, 1_200)
        cancellation.cancel()
        XCTAssertThrowsError(try cancellingCursor.nextBatch(cancellationCheck: cancellation.check)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let parsingCancellation = CancellationAfterChecks(3)
        let parsingCursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: parsingCancellation.check
        )
        XCTAssertThrowsError(try parsingCursor.nextBatch(cancellationCheck: parsingCancellation.check)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(try parsingCursor.nextBatch(cancellationCheck: {}))
    }

    func testDescriptorRelativeTraversalMatchesBudgetFallback() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for branch in 0..<6 {
            let leafURL = rootURL
                .appending(path: "branch-\(branch)", directoryHint: .isDirectory)
                .appending(path: "nested", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: leafURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(branch), count: 257 + branch).write(
                to: leafURL.appending(path: "payload-\(branch).bin")
            )
        }

        let descriptorPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 32)
        let descriptorEngine = ScanEngine(directoryDescriptorPoolFactory: { descriptorPool })
        let descriptorSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: descriptorEngine
        )

        let fallbackPool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 1)
        let fallbackEngine = ScanEngine(directoryDescriptorPoolFactory: { fallbackPool })
        let fallbackSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: fallbackEngine
        )

        XCTAssertEqual(descriptorSnapshot.treeStore.indexedNodeIDs(), fallbackSnapshot.treeStore.indexedNodeIDs())
        XCTAssertEqual(descriptorSnapshot.treeStore.childIDsByID, fallbackSnapshot.treeStore.childIDsByID)
        XCTAssertEqual(descriptorSnapshot.root.allocatedSize, fallbackSnapshot.root.allocatedSize)
        XCTAssertGreaterThan(descriptorPool.debugCounters.openatCallCount, 0)
        XCTAssertEqual(descriptorPool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertLessThanOrEqual(descriptorPool.debugCounters.peakOpenDescriptorCount, 32)
        XCTAssertGreaterThan(fallbackPool.debugCounters.fallbackCount, 0)
        XCTAssertEqual(fallbackPool.debugCounters.currentOpenDescriptorCount, 0)
        XCTAssertLessThanOrEqual(fallbackPool.debugCounters.peakOpenDescriptorCount, 1)
    }

    func testFoundationFallbackRejectsDirectoryReplacedDuringEnumeration() async throws {
        let rootURL = try makeTemporaryDirectory()
        let foreignRootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: foreignRootURL)
        }

        let directoryURL = rootURL.appending(path: "ReplaceMe", directoryHint: .isDirectory)
        let originalDirectoryURL = rootURL.appending(path: "Original", directoryHint: .isDirectory)
        let foreignFileURL = foreignRootURL.appending(path: "foreign.bin")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: foreignFileURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url.standardizedFileURL == directoryURL.standardizedFileURL {
                try FileManager.default.moveItem(at: directoryURL, to: originalDirectoryURL)
                try FileManager.default.createSymbolicLink(
                    at: directoryURL,
                    withDestinationURL: foreignRootURL
                )
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
            try cancellationCheck()
            return contents
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )

        XCTAssertNil(snapshot.treeStore.node(id: directoryURL.appending(path: "foreign.bin").path))
        XCTAssertTrue(snapshot.scanWarnings.contains { warning in
            warning.path == directoryURL.path && warning.category == .fileSystem
        })
    }

    func testBulkAndFoundationScannersMatchAdversarialFixture() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let unicodeDirectoryURL = rootURL.appending(
            path: "Ångström-文件-🙂",
            directoryHint: .isDirectory
        )
        let ownerDirectoryURL = rootURL.appending(path: "A-Owner", directoryHint: .isDirectory)
        let linkDirectoryURL = rootURL.appending(path: "Z-Link", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Payload.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unicodeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ownerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: packageURL.appending(path: "Contents/Resources", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let sparseURL = unicodeDirectoryURL.appending(path: "sparse-ß.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseURL.path, contents: nil))
        let sparseHandle = try FileHandle(forWritingTo: sparseURL)
        try sparseHandle.truncate(atOffset: 16 * 1_024 * 1_024)
        try sparseHandle.close()
        try Data([0x11]).write(to: unicodeDirectoryURL.appending(path: ".hidden"))

        let ownerURL = ownerDirectoryURL.appending(path: "shared.dat")
        let linkedURL = linkDirectoryURL.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 8_192).write(to: ownerURL)
        try FileManager.default.linkItem(at: ownerURL, to: linkedURL)
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "file-alias"),
            withDestinationURL: ownerURL
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "directory-alias"),
            withDestinationURL: unicodeDirectoryURL
        )
        try Data(repeating: 0x7F, count: 257).write(
            to: packageURL.appending(path: "Contents/Resources/asset.dat")
        )
        try Data(repeating: 0x33, count: 4_096).write(
            to: unicodeDirectoryURL.appending(path: "excluded.tmp")
        )
        let excludedDirectoryURL = rootURL.appending(
            path: "Excluded",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: excludedDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x44, count: 8_192).write(
            to: excludedDirectoryURL.appending(path: "payload.dat")
        )

        var options = ScanOptions()
        options.includeHiddenFiles = true
        options.autoSummarizeDirectories = false
        options.exclusionPatterns = ["*.tmp", "Excluded/"]
        let legacy = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(usesDeferredBulkEntryFiltering: false)
        )
        let optimized = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(usesDeferredBulkEntryFiltering: true)
        )
        let foundation = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
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

        let optimizedNodeIDs = optimized.treeStore.indexedNodeIDs()
        XCTAssertEqual(optimizedNodeIDs, foundation.treeStore.indexedNodeIDs())
        XCTAssertEqual(optimized.treeStore.childIDsByID, foundation.treeStore.childIDsByID)
        XCTAssertEqual(optimized.aggregateStats.totalAllocatedSize, foundation.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(optimized.aggregateStats.totalLogicalSize, foundation.aggregateStats.totalLogicalSize)
        XCTAssertEqual(optimized.aggregateStats.fileCount, foundation.aggregateStats.fileCount)
        XCTAssertEqual(optimized.aggregateStats.directoryCount, foundation.aggregateStats.directoryCount)
        XCTAssertEqual(optimized.aggregateStats.accessibleItemCount, foundation.aggregateStats.accessibleItemCount)
        XCTAssertEqual(optimized.aggregateStats.inaccessibleItemCount, foundation.aggregateStats.inaccessibleItemCount)
        XCTAssertEqual(optimizedNodeIDs, legacy.treeStore.indexedNodeIDs())
        XCTAssertEqual(optimized.treeStore.childIDsByID, legacy.treeStore.childIDsByID)
        XCTAssertEqual(optimized.aggregateStats.totalAllocatedSize, legacy.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(optimized.aggregateStats.totalLogicalSize, legacy.aggregateStats.totalLogicalSize)
        XCTAssertEqual(optimized.aggregateStats.fileCount, legacy.aggregateStats.fileCount)
        XCTAssertEqual(optimized.aggregateStats.directoryCount, legacy.aggregateStats.directoryCount)
        XCTAssertEqual(optimized.aggregateStats.accessibleItemCount, legacy.aggregateStats.accessibleItemCount)
        XCTAssertEqual(optimized.aggregateStats.inaccessibleItemCount, legacy.aggregateStats.inaccessibleItemCount)

        for nodeID in optimizedNodeIDs {
            let optimizedNode = try XCTUnwrap(optimized.treeStore.node(id: nodeID))
            let foundationNode = try XCTUnwrap(foundation.treeStore.node(id: nodeID))
            XCTAssertEqual(optimizedNode, legacy.treeStore.node(id: nodeID), nodeID)
            XCTAssertEqual(optimizedNode.name, foundationNode.name, nodeID)
            XCTAssertEqual(optimizedNode.isDirectory, foundationNode.isDirectory, nodeID)
            XCTAssertEqual(optimizedNode.isSymbolicLink, foundationNode.isSymbolicLink, nodeID)
            XCTAssertEqual(optimizedNode.allocatedSize, foundationNode.allocatedSize, nodeID)
            XCTAssertEqual(
                optimizedNode.unduplicatedAllocatedSize,
                foundationNode.unduplicatedAllocatedSize,
                nodeID
            )
            XCTAssertEqual(optimizedNode.dataAllocatedSize, foundationNode.dataAllocatedSize, nodeID)
            XCTAssertEqual(optimizedNode.logicalSize, foundationNode.logicalSize, nodeID)
            XCTAssertEqual(optimizedNode.descendantFileCount, foundationNode.descendantFileCount, nodeID)
            XCTAssertEqual(optimizedNode.linkCount, foundationNode.linkCount, nodeID)
            XCTAssertEqual(optimizedNode.cloneIdentity, foundationNode.cloneIdentity, nodeID)
            XCTAssertEqual(optimizedNode.mayShareDataBlocks, foundationNode.mayShareDataBlocks, nodeID)
            XCTAssertEqual(optimizedNode.isPackage, foundationNode.isPackage, nodeID)
            XCTAssertEqual(optimizedNode.isAccessible, foundationNode.isAccessible, nodeID)
            XCTAssertEqual(optimizedNode.isSelfAccessible, foundationNode.isSelfAccessible, nodeID)
            if optimizedNode.linkCount > 1 {
                XCTAssertNotNil(optimizedNode.fileIdentity, nodeID)
                XCTAssertNotNil(foundationNode.fileIdentity, nodeID)
            } else if optimizedNode.isSymbolicLink || optimizedNode.isDirectory {
                XCTAssertEqual(optimizedNode.fileIdentity, foundationNode.fileIdentity, nodeID)
            }
        }
    }

    func testPackagesAreLeafNodesByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.isDirectory)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, Int64("binary".utf8.count))
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testPackageLeafNodesIncludeNestedPackageContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Host.app", directoryHint: .isDirectory)
        let nestedPackageURL = packageURL.appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
        let nestedBinaryURL = nestedPackageURL.appending(path: "Contents/MacOS/NestedBinary")

        try FileManager.default.createDirectory(at: nestedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: nestedBinaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Host.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, 2_048)
    }

    func testPackageLeafSizesIgnoreNestedDirectoryEntries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Deep.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/Frameworks/A.framework/Resources/B.bundle/C.txt")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 1_024).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Deep.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 1_024)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 1_024)
    }

    func testPackageRootHardLinksOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Linked.app", directoryHint: .isDirectory)
        let originalURL = packageURL.appending(path: "Contents/Resources/original.bin")
        let linkedURL = packageURL.appending(path: "Contents/Resources/linked.bin")

        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCA, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions()
        )

        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 8_192)
        XCTAssertGreaterThan(snapshot.root.allocatedSize, 0)
        XCTAssertLessThan(snapshot.root.allocatedSize, snapshot.root.logicalSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testHardLinkCrossingAtomicPackageAndVisibleFileUsesLexicographicOwner() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "a-shared.bin")
        let packageURL = rootURL.appending(path: "z.app", directoryHint: .isDirectory)
        let packageLinkURL = packageURL.appending(path: "Contents/Resources/shared.bin")
        try FileManager.default.createDirectory(
            at: packageLinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA6, count: 4_096).write(to: visibleFileURL)
        try FileManager.default.linkItem(at: visibleFileURL, to: packageLinkURL)

        let packageMinimumAllocatedSize = try ScanMetadataLoader().metadata(for: packageURL).allocatedSize
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let visibleNode = try XCTUnwrap(snapshot.treeStore.node(id: visibleFileURL.path))
        let packageNode = try XCTUnwrap(snapshot.treeStore.node(id: packageURL.path))

        XCTAssertGreaterThan(visibleNode.allocatedSize, 0)
        XCTAssertEqual(packageNode.allocatedSize, packageMinimumAllocatedSize)
        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 8_192)
        XCTAssertEqual(
            snapshot.root.allocatedSize,
            visibleNode.allocatedSize + packageNode.allocatedSize
        )
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testParallelPackageSummaryMatchesSerialSummary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Parallel.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Parallel")
        let resourceURL = packageURL.appending(path: "Contents/Resources/Data/blob.dat")
        let hiddenURL = packageURL.appending(path: "Contents/Resources/.hidden")
        let nestedPackageBinaryURL = packageURL
            .appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Nested")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: binaryURL)
        try Data(repeating: 0x2, count: 256).write(to: resourceURL)
        try Data(repeating: 0x3, count: 512).write(to: hiddenURL)
        try Data(repeating: 0x4, count: 1_024).write(to: nestedPackageBinaryURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.atomicSummaryWorkerLimit = 2

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try XCTUnwrap(rootChildren(in: serialSnapshot).first(where: { $0.name == "Parallel.app" }))
        let parallelPackageNode = try XCTUnwrap(rootChildren(in: parallelSnapshot).first(where: { $0.name == "Parallel.app" }))

        XCTAssertEqual(parallelPackageNode.descendantFileCount, serialPackageNode.descendantFileCount)
        XCTAssertEqual(parallelPackageNode.logicalSize, serialPackageNode.logicalSize)
        XCTAssertEqual(parallelPackageNode.allocatedSize, serialPackageNode.allocatedSize)
        XCTAssertEqual(parallelPackageNode.isAccessible, serialPackageNode.isAccessible)
        XCTAssertEqual(parallelPackageNode.isSelfAccessible, serialPackageNode.isSelfAccessible)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
    }

    func testScanWidePackageSummaryPoolMatchesSerialAcrossSiblingPackages() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var firstPayloadURL: URL?
        for packageIndex in 0..<24 {
            let resourcesURL = rootURL
                .appending(
                    path: String(format: "Sibling-%02d.app", packageIndex),
                    directoryHint: .isDirectory
                )
                .appending(path: "Contents/Resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
            for fileIndex in 0..<4 {
                let payloadURL = resourcesURL.appending(
                    path: String(format: "payload-%02d.dat", fileIndex)
                )
                try Data(repeating: UInt8(packageIndex), count: packageIndex + fileIndex + 1)
                    .write(to: payloadURL)
                if packageIndex == 0, fileIndex == 0 {
                    firstPayloadURL = payloadURL
                }
            }
            try Data(repeating: 0xFF, count: 128).write(
                to: resourcesURL.appending(path: ".hidden-payload")
            )
        }

        let sharedSourceURL = try XCTUnwrap(firstPayloadURL)
        let sharedLinkURL = rootURL
            .appending(path: "Sibling-01.app/Contents/Resources/shared-link.dat")
        try FileManager.default.linkItem(at: sharedSourceURL, to: sharedLinkURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var pooledOptions = ScanOptions()
        pooledOptions.atomicSummaryWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: serialOptions
        )
        let pooledSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: pooledOptions
        )
        let serialNodes = Dictionary(uniqueKeysWithValues: rootChildren(in: serialSnapshot).map {
            ($0.name, $0)
        })
        let pooledNodes = Dictionary(uniqueKeysWithValues: rootChildren(in: pooledSnapshot).map {
            ($0.name, $0)
        })

        XCTAssertEqual(pooledNodes.count, 24)
        XCTAssertEqual(Set(pooledNodes.keys), Set(serialNodes.keys))
        for name in serialNodes.keys {
            let serialNode = try XCTUnwrap(serialNodes[name])
            let pooledNode = try XCTUnwrap(pooledNodes[name])
            XCTAssertEqual(pooledNode.descendantFileCount, serialNode.descendantFileCount, name)
            XCTAssertEqual(pooledNode.logicalSize, serialNode.logicalSize, name)
            XCTAssertEqual(pooledNode.allocatedSize, serialNode.allocatedSize, name)
            XCTAssertEqual(pooledNode.isAccessible, serialNode.isAccessible, name)
        }
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.totalAllocatedSize,
            serialSnapshot.aggregateStats.totalAllocatedSize
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.totalLogicalSize,
            serialSnapshot.aggregateStats.totalLogicalSize
        )
        XCTAssertEqual(pooledSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.directoryCount,
            serialSnapshot.aggregateStats.directoryCount
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.accessibleItemCount,
            serialSnapshot.aggregateStats.accessibleItemCount
        )
        XCTAssertEqual(
            pooledSnapshot.aggregateStats.inaccessibleItemCount,
            serialSnapshot.aggregateStats.inaccessibleItemCount
        )
        XCTAssertEqual(pooledSnapshot.scanWarnings, serialSnapshot.scanWarnings)
    }

    func testPackageSummariesShareScanWideBoundedWorkers() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for packageIndex in 0..<4 {
            let packageURL = rootURL.appending(
                path: String(format: "Package-%02d.app", packageIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            for fileIndex in 0..<3 {
                try Data(repeating: UInt8(packageIndex), count: fileIndex + 1).write(
                    to: packageURL.appending(path: "payload-\(fileIndex).dat")
                )
            }
        }

        let probe = BlockingAtomicSummaryWorkerProbe()
        let observer = AtomicSummaryWorkerObserver(
            didStart: probe.didStart,
            didFinish: probe.didFinish
        )
        let engine = ScanEngine(atomicSummaryWorkerObserver: observer)
        var options = ScanOptions()
        options.atomicSummaryWorkerLimit = 2
        options.directoryTraversalWorkerLimit = 1
        let scanTask = Task {
            try await finishedSnapshot(
                target: ScanTarget(url: rootURL),
                options: options,
                engine: engine
            )
        }
        defer {
            probe.releaseAll()
            scanTask.cancel()
        }

        XCTAssertTrue(probe.waitForDistinctActiveOwners(2, timeout: 2))
        XCTAssertEqual(probe.activeWorkerCount, 2)
        XCTAssertEqual(probe.peakActiveWorkerCount, 2)
        XCTAssertEqual(probe.activeOwnerCount, 2)
        probe.releaseAll()

        let snapshot = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }
        let packageNodes = rootChildren(in: snapshot)
        XCTAssertEqual(packageNodes.count, 4)
        XCTAssertTrue(packageNodes.allSatisfy { $0.descendantFileCount == 3 })
        XCTAssertTrue(packageNodes.allSatisfy { !containsChildren($0, in: snapshot) })
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 12)
        XCTAssertEqual(probe.seenOwnerCount, 4)
        XCTAssertGreaterThanOrEqual(probe.maximumDistinctActiveOwnerCount, 2)
        XCTAssertLessThanOrEqual(probe.peakActiveWorkerCount, 2)
        XCTAssertEqual(probe.activeWorkerCount, 0)
    }

    func testRecursiveBulkPackageSummaryMatchesSerialAcrossMultipleBatches() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Wide.app", directoryHint: .isDirectory)
        let wideDirectoryURL = packageURL.appending(
            path: "Contents/Resources/Wide",
            directoryHint: .isDirectory
        )
        let nestedPackageDirectoryURL = packageURL.appending(
            path: "Contents/PlugIns/Nested.bundle/Contents/Resources",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: wideDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageDirectoryURL, withIntermediateDirectories: true)

        for index in 0..<700 {
            try Data([UInt8(index % 256)]).write(
                to: wideDirectoryURL.appending(path: String(format: "wide-payload-%06d-with-padding.dat", index))
            )
        }
        for index in 0..<50 {
            try Data(repeating: UInt8(index), count: 2).write(
                to: nestedPackageDirectoryURL.appending(path: String(format: "nested-%04d.dat", index))
            )
        }

        let originalURL = nestedPackageDirectoryURL.appending(path: "original.bin")
        let linkedURL = wideDirectoryURL.appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 64).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.atomicSummaryWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try XCTUnwrap(rootChildren(in: serialSnapshot).first { $0.name == "Wide.app" })
        let parallelPackageNode = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.name == "Wide.app" })

        XCTAssertEqual(serialPackageNode.descendantFileCount, 752)
        XCTAssertEqual(serialPackageNode.logicalSize, 928)
        XCTAssertEqual(parallelPackageNode.descendantFileCount, serialPackageNode.descendantFileCount)
        XCTAssertEqual(parallelPackageNode.logicalSize, serialPackageNode.logicalSize)
        XCTAssertEqual(parallelPackageNode.allocatedSize, serialPackageNode.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
    }

    func testRecursiveBulkPackageSummaryDoesNotFollowDirectorySymlinks() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let externalDirectoryURL = rootURL.appending(path: "External", directoryHint: .isDirectory)
        let externalFileURL = externalDirectoryURL.appending(path: "large.bin")
        let packageURL = rootURL.appending(path: "Links.app", directoryHint: .isDirectory)
        let resourcesURL = packageURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let localFileURL = resourcesURL.appending(path: "local.bin")
        let externalLinkURL = resourcesURL.appending(path: "ExternalLink")
        let cycleLinkURL = resourcesURL.appending(path: "PackageCycle")

        try FileManager.default.createDirectory(at: externalDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 32_768).write(to: externalFileURL)
        try Data(repeating: 0x11, count: 32).write(to: localFileURL)
        try FileManager.default.createSymbolicLink(at: externalLinkURL, withDestinationURL: externalDirectoryURL)
        try FileManager.default.createSymbolicLink(at: cycleLinkURL, withDestinationURL: packageURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first { $0.name == "Links.app" })

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertLessThan(packageNode.logicalSize, 32_768)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
    }

    func testPackagesCanBeExpandedWhenEnabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(treatPackagesAsDirectories: true)
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(containsChildren(packageNode, in: snapshot))
        XCTAssertEqual(packageNode.descendantFileCount, 1)
    }

    func testPooledSummaryPreservesRootAccessibilityAndErrors() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for state in ["readable", "unreadable", "missing"] {
            let packageURL = rootURL.appending(path: "\(state).app", directoryHint: .isDirectory)
            if state != "missing" {
                try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            }
            if state == "unreadable" {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: packageURL.path)
            }
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageURL.path)
            }

            let pool = AtomicDirectorySummaryPool(workerLimit: 1)
            let summarizer = AtomicDirectorySummarizer(metadataLoader: ScanMetadataLoader(), summaryPool: pool)
            let (_, continuation) = makeAtomicSummaryProgressReporter()
            defer { continuation.finish() }
            var metrics = ScanMetrics()
            let result = try await summarizer.summarize(
                at: packageURL,
                treatPackagesAsDirectories: true,
                progressKind: .package,
                ownerNodeID: packageURL.path,
                exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: packageURL),
                cancellationCheck: {},
                metrics: &metrics,
                continuation: continuation
            )
            await pool.finish()

            let summary = try XCTUnwrap(result)
            XCTAssertEqual(summary.isAccessible, state == "readable", state)
            XCTAssertEqual(summary.warnings.isEmpty, state == "readable", state)
            XCTAssertTrue(summary.warnings.allSatisfy { $0.path == packageURL.path }, state)
            XCTAssertEqual(summary.descendantFileCount, 0, state)
            XCTAssertEqual(summary.allocatedSize, 0, state)
        }
    }

    func testAtomicPackageAccessFailuresProduceWarnings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Locked.app", directoryHint: .isDirectory)
        let readableFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let unreadableDirectoryURL = packageURL.appending(path: "Contents/Private")
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "Secret.dat")

        try FileManager.default.createDirectory(at: readableFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: readableFileURL)
        try Data("secret".utf8).write(to: unreadableFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDirectoryURL.path)
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked.app" }))

        XCTAssertFalse(packageNode.isAccessible)
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertTrue(snapshot.scanWarnings.contains(where: { $0.path.contains("Locked.app") }))
    }

    func testUnreadableOrdinaryDirectoryProducesWarningAndContinuesScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableFileURL = rootURL.appending(path: "visible.txt")
        let unreadableDirectoryURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "secret.txt")

        try Data("visible".utf8).write(to: readableFileURL)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: unreadableFileURL)
        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url.lastPathComponent == "Locked" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedNode.url.path }))

        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isPackage)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertEqual(lockedNode.allocatedSize, 0)
        XCTAssertEqual(lockedNode.logicalSize, 0)
        XCTAssertEqual(lockedNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testLocalizedChildEnumerationFailureKeepsReadableSiblings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableDirectoryURL = rootURL.appending(path: "Readable", directoryHint: .isDirectory)
        let readableFileURL = readableDirectoryURL.appending(path: "nested.txt")
        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let lockedURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: readableDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: readableFileURL)
        try Data("visible".utf8).write(to: visibleFileURL)

        let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let enumeratedLockedURL = lockedURL.withUnsafeFileSystemRepresentation { path -> URL? in
            guard let path, let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return URL(filePath: String(cString: resolvedPath), directoryHint: .isDirectory)
        } ?? lockedURL
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [readableDirectoryURL, visibleFileURL],
                    localizedFailures: [
                        ScanEngine.DirectoryEnumerationFailure(
                            url: enumeratedLockedURL,
                            error: permissionError,
                            isDirectoryHint: true
                        )
                    ]
                )
            }

            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
            return ScanEngine.DirectoryEnumerationResult(urls: urls)
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )

        let rootChildNames = rootChildren(in: snapshot).map(\.name)
        let readableNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Readable" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedURL.path }))

        XCTAssertEqual(Set(rootChildNames), Set(["Locked", "Readable", "visible.txt"]))
        XCTAssertEqual(children(of: readableNode, in: snapshot).map(\.name), ["nested.txt"])
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
    }

    func testPackageLeafExcludesHiddenContentsWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let visibleFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let hiddenFileURL = packageURL.appending(path: "Contents/Resources/.secret")

        try FileManager.default.createDirectory(at: visibleFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 256).write(to: hiddenFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(includeHiddenFiles: false)
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 128)
    }

    func testExcludesBasenameDirectoryLikeNodeModules() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let nodeModulesFileURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: "left-pad/index.js")

        try FileManager.default.createDirectory(at: nodeModulesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 16).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 128).write(to: nodeModulesFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 16)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testExcludesFilesByGlob() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 32)
            .write(to: rootURL.appending(path: "notes.txt"))
        try Data(repeating: 0x2, count: 256)
            .write(to: rootURL.appending(path: "debug.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["notes.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesDirectoryOnlyPatternsWithoutExcludingSameNamedFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 256).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 32).write(to: rootURL.appending(path: "build"))

        var options = ScanOptions()
        options.exclusionPatterns = ["build/"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let nestedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "nested" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["build", "nested"])
        XCTAssertTrue(children(of: nestedNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesPathGlobPatternsRelativeToScanRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let libraryCacheFileURL = rootURL
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: "ignored.bin")
        let topLevelCacheFileURL = rootURL
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "kept.bin")

        try FileManager.default.createDirectory(at: libraryCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topLevelCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: libraryCacheFileURL)
        try Data(repeating: 0x2, count: 64).write(to: topLevelCacheFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["Library/Caches/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let cachesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Caches" }))
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(children(of: cachesNode, in: snapshot).map(\.name), ["kept.bin"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testExcludesDoubleStarPathGlobPatterns() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "project/build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        let keptFileURL = rootURL
            .appending(path: "project/Sources", directoryHint: .isDirectory)
            .appending(path: "main.swift")

        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 128).write(to: keptFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["**/build/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let projectNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "project" }))

        XCTAssertEqual(children(of: projectNode, in: snapshot).map(\.name), ["Sources"])
        XCTAssertEqual(projectNode.descendantFileCount, 1)
        XCTAssertEqual(projectNode.logicalSize, 128)
    }

    func testExcludesDSStoreEvenWhenHiddenFilesAreIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 24)
            .write(to: rootURL.appending(path: "visible.txt"))
        try Data(repeating: 0x2, count: 512)
            .write(to: rootURL.appending(path: ".DS_Store"))

        var options = ScanOptions(includeHiddenFiles: true)
        options.exclusionPatterns = [".DS_Store"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 24)
    }

    func testIncludesResidentCloudStorageFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "GoogleDrive-example", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let cloudStorageNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "CloudStorage" }))
        let providerNode = try XCTUnwrap(children(of: cloudStorageNode, in: snapshot).first(where: { $0.name == "GoogleDrive-example" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testIncludesResidentICloudDriveFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let iCloudDriveNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Mobile Documents" }))
        let providerNode = try XCTUnwrap(children(of: iCloudDriveNode, in: snapshot).first(where: { $0.name == "com~apple~CloudDocs" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testExplicitCloudStorageFolderScanIsAllowedByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: cloudStorageURL),
            options: ScanOptions()
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["Dropbox"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 512)
    }

    func testVolumeScanWithExclusionsDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 128)
            .write(to: rootURL.appending(path: "visible.txt"))

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        XCTAssertFalse(rootChildren(in: snapshot).contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testExcludedFilesDoNotContributeToParentSizeTotals() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataURL = rootURL.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 10)
            .write(to: dataURL.appending(path: "keep.bin"))
        try Data(repeating: 0x2, count: 90)
            .write(to: dataURL.appending(path: "ignored.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let dataNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Data" }))

        XCTAssertEqual(children(of: dataNode, in: snapshot).map(\.name), ["keep.bin"])
        XCTAssertEqual(dataNode.descendantFileCount, 1)
        XCTAssertEqual(dataNode.logicalSize, 10)
        XCTAssertEqual(snapshot.root.logicalSize, 10)
    }

    func testExcludedFilesDoNotContributeThroughPackageSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let keptFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let excludedFileURL = packageURL.appending(path: "Contents/Resources/debug.log")

        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludedFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: keptFileURL)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
    }

    func testExcludedPackageContentsStillEmitSummaryProgress() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let nestedURL = packageURL.appending(path: "Cache", directoryHint: .isDirectory)
        let excludedFileURL = nestedURL.appending(path: "debug.log")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let engine = ScanEngine()
        var summaryProgress: [ScanMetrics] = []
        var lastProgress: ScanMetrics?
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .executionMode:
                break
            case .progress(let metrics):
                lastProgress = metrics
                if metrics.atomicSummaryVisitedItems > 0 {
                    summaryProgress.append(metrics)
                }
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
        XCTAssertTrue(summaryProgress.contains { $0.currentPath.contains("/Sample.app") })
        XCTAssertTrue(summaryProgress.contains { $0.atomicSummaryVisitedItems >= 1 })
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(lastProgress).completedSummaryAdditionalVisitedItemCount,
            2,
            "Committed summary work must retain visited directory and excluded-entry units."
        )
    }

    func testPackageSummaryProgressTracksVisitedAndEstimatedRemainingWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Progress.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data([UInt8(index % 256)]).write(
                to: packageURL.appending(path: String(format: "payload-%04d.dat", index))
            )
        }

        let engine = ScanEngine(atomicSummaryProgressEmissionInterval: 0)
        var progressMetrics: [ScanMetrics] = []
        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressMetrics.append(metrics)
            }
        }

        let summaryMetrics = progressMetrics.filter { $0.atomicSummaryVisitedItems > 0 }
        XCTAssertGreaterThanOrEqual(summaryMetrics.count, 2)
        XCTAssertEqual(summaryMetrics.map(\.atomicSummaryVisitedItems).max(), 300)
        XCTAssertTrue(summaryMetrics.contains { $0.atomicSummaryEstimatedRemainingItems > 0 })
        XCTAssertTrue(summaryMetrics.contains { $0.activeAtomicSummaryCount == 1 })
        XCTAssertTrue(progressMetrics.contains { $0.pendingPackageSummaryCount == 1 })
        for pair in zip(progressMetrics, progressMetrics.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.progressFraction, pair.0.progressFraction)
        }
        let completedMetrics = try XCTUnwrap(progressMetrics.last)
        XCTAssertEqual(completedMetrics.progressFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(completedMetrics.pendingPackageSummaryCount, 0)
        XCTAssertEqual(completedMetrics.completedPackageSummaryCount, 1)
        XCTAssertEqual(completedMetrics.completedPackageSummaryVisitedItemCount, 300)
        XCTAssertEqual(completedMetrics.completedSummaryAdditionalVisitedItemCount, 300)
        XCTAssertEqual(completedMetrics.atomicSummaryVisitedItems, 0)
    }

    func testPackageRootParticipatesInSummaryWorkAccounting() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let packageURL = rootURL.appending(path: "Progress.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data([UInt8(index % 256)]).write(
                to: packageURL.appending(path: String(format: "payload-%04d.dat", index))
            )
        }

        let engine = ScanEngine(atomicSummaryProgressEmissionInterval: 0)
        var progressMetrics: [ScanMetrics] = []
        for try await event in engine.scan(target: ScanTarget(url: packageURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressMetrics.append(metrics)
            }
        }

        XCTAssertTrue(progressMetrics.contains { $0.pendingPackageSummaryCount == 1 })
        XCTAssertTrue(progressMetrics.contains {
            $0.activePackageSummaryCount == 1 && $0.atomicSummaryVisitedItems > 0
        })
        let completedMetrics = try XCTUnwrap(progressMetrics.last)
        XCTAssertEqual(completedMetrics.pendingPackageSummaryCount, 0)
        XCTAssertEqual(completedMetrics.completedPackageSummaryCount, 1)
        XCTAssertEqual(completedMetrics.completedPackageSummaryVisitedItemCount, 300)
    }

    func testReusedEntryAutoSummaryPublishesInFlightWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cacheURL = rootURL.appending(path: "projects/cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data([UInt8(index % 256)]).write(
                to: cacheURL.appending(path: String(format: "payload-%04d.dat", index))
            )
        }

        var options = ScanOptions()
        options.autoSummarizeMinDepthForSummarization = 2
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        let engine = ScanEngine(atomicSummaryProgressEmissionInterval: 0)
        var progressMetrics: [ScanMetrics] = []
        var snapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressMetrics.append(metrics)
            case .finished(let result):
                snapshot = result
            case .executionMode, .warning:
                break
            }
        }

        let active = progressMetrics.filter {
            $0.activeAutoSummaryRepresentedItemCount == 300
                && $0.atomicSummaryVisitedItems > 0
        }
        XCTAssertGreaterThanOrEqual(active.count, 2)
        XCTAssertEqual(active.map(\.atomicSummaryVisitedItems).max(), 300)
        XCTAssertTrue(active.contains { $0.atomicSummaryEstimatedRemainingItems > 0 })
        XCTAssertTrue(progressMetrics.contains {
            $0.pendingAutoSummaryRepresentedItemCount == 300
        })
        XCTAssertEqual(
            try XCTUnwrap(snapshot).treeStore.node(id: cacheURL.path)?.descendantFileCount,
            300
        )
    }

    func testExcludedFilesDoNotContributeThroughAutoSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<10 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "keep.tmp"))
            try Data(repeating: 0x7F, count: 4_096)
                .write(to: shardURL.appending(path: "ignored.log"))
        }

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 10)
        XCTAssertEqual(cacheNode.logicalSize, 10 * 32)
    }

    func testCancellingScanStopsPackageLeafSummaryWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let packageContentsURL = rootURL
            .appending(path: "Large.app", directoryHint: .isDirectory)
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageContentsURL, withIntermediateDirectories: true)

        for index in 0..<8_000 {
            let fileURL = packageContentsURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await scanTask.value

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testCancellingConcurrentPackageProgressDoesNotDeadlock() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for packageIndex in 0..<8 {
            let resourcesURL = rootURL
                .appending(path: "Package-\(packageIndex).app", directoryHint: .isDirectory)
                .appending(path: "Contents/Resources", directoryHint: .isDirectory)
            for branchIndex in 0..<4 {
                let branchURL = resourcesURL.appending(
                    path: "Branch-\(branchIndex)",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: branchURL,
                    withIntermediateDirectories: true
                )
                for fileIndex in 0..<128 {
                    try Data([UInt8(fileIndex % 256)]).write(
                        to: branchURL.appending(path: "payload-\(fileIndex).tmp")
                    )
                }
            }
        }

        for _ in 0..<8 {
            let lifecycle = AtomicSummaryWorkerLifecycleProbe()
            let engine = ScanEngine(
                atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver(
                    didStart: { _, _ in lifecycle.didStart() },
                    didFinish: { _, _ in lifecycle.didFinish() },
                    didShutdown: { lifecycle.didShutdown() }
                ),
                atomicSummaryProgressEmissionInterval: 0
            )
            let scanTask = Task {
                var didFinish = false
                do {
                    for try await event in engine.scan(
                        target: ScanTarget(url: rootURL),
                        options: ScanOptions()
                    ) {
                        if case .finished = event {
                            didFinish = true
                        }
                    }
                } catch is CancellationError {
                    return false
                }
                return didFinish
            }

            let workerDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while lifecycle.peakActiveWorkerCount < 2, ContinuousClock.now < workerDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertGreaterThanOrEqual(lifecycle.peakActiveWorkerCount, 2)

            scanTask.cancel()
            let didFinish = try await withTimeout(.seconds(2)) {
                try await scanTask.value
            }
            let shutdownDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while (!lifecycle.didObserveShutdown || lifecycle.activeWorkerCount > 0),
                  ContinuousClock.now < shutdownDeadline {
                await Task.yield()
            }

            XCTAssertFalse(didFinish)
            XCTAssertEqual(lifecycle.activeWorkerCount, 0)
            XCTAssertTrue(lifecycle.didObserveShutdown)
        }
    }

    func testCancellingScanStopsWideDirectoryEnumerationWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        for index in 0..<10_000 {
            let fileURL = rootURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let probe = BlockingDirectoryContentsProbe(blockedURL: rootURL)
        let engine = ScanEngine(directoryContents: { url, _, _, _ in
            try probe.contents(for: url)
        })
        let blockedScanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return didFinish
        }
        defer {
            probe.release()
            blockedScanTask.cancel()
        }

        try await probe.waitUntilBlocked()
        blockedScanTask.cancel()

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        probe.release()
        let blockedScanFinished = await blockedScanTask.value

        XCTAssertTrue(followUpFinished)
        XCTAssertFalse(blockedScanFinished)
    }

    func testEnumeratedDirectoryContentsChecksCancellationBeforeMaterializingAllURLs() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cancellation = DirectoryEnumerationCancellation()
        let enumerator = SlowDirectoryObjectEnumerator(rootURL: rootURL, totalCount: 10_000)
        let enumerationTask = Task {
            try ScanEngine.enumeratedDirectoryContents(
                url: rootURL,
                keys: nil,
                options: [],
                cancellationCheck: { try cancellation.check() },
                makeEnumerator: { _, _, _ in enumerator }
            )
        }

        try await enumerator.waitUntilProduced(64)
        cancellation.cancel()

        do {
            _ = try await withTimeout(.seconds(1)) {
                try await enumerationTask.value
            }
            XCTFail("Expected directory enumeration to stop after cancellation.")
        } catch is CancellationError {
            XCTAssertLessThan(enumerator.producedCount, enumerator.totalCount)
        }
    }

    func testCancellingScanStopsInjectedDirectoryEnumerationBeforeMaterialization() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probe = CancellableDirectoryContentsProbe(totalCount: 10_000)
        let engine = ScanEngine(directoryContents: { url, _, _, cancellationCheck in
            guard url == rootURL else { return [] }
            return try probe.contents(for: url, cancellationCheck: cancellationCheck)
        })
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await probe.waitUntilProduced(64)
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(1)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)
        XCTAssertLessThan(probe.producedCount, probe.totalCount)
    }

    func testSymbolicLinksAreNotTraversed() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let nestedFile = realDirectory.appending(path: "payload.txt")
        let symlinkURL = rootURL.appending(path: "Alias")

        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let aliasNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alias" }))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertFalse(containsChildren(aliasNode, in: snapshot))
        XCTAssertEqual(aliasNode.itemKind, "Alias")
        XCTAssertEqual(aliasNode.descendantFileCount, 0)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testHardLinkedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")

        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(children.map(\.logicalSize).reduce(0, +), 8_192)
        XCTAssertEqual(allocatedSizes.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(snapshot.root.allocatedSize, allocatedSizes.reduce(0, +))
        XCTAssertTrue(children.allSatisfy { $0.fileIdentity != nil })
        XCTAssertEqual(children.map(\.linkCount), [2, 2])
        XCTAssertEqual(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count, 1)
        XCTAssertTrue(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })
    }

    func testAPFSClonedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let clonedURL = rootURL.appending(path: "cloned.bin")

        try Data(repeating: 0xC3, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)

        let metadataLoader = ScanMetadataLoader()
        let originalMetadata = try metadataLoader.metadata(for: originalURL)
        let clonedMetadata = try metadataLoader.metadata(for: clonedURL)
        XCTAssertEqual(originalMetadata.linkCount, 1)
        XCTAssertEqual(clonedMetadata.linkCount, 1)
        XCTAssertNotEqual(originalMetadata.fileIdentity, clonedMetadata.fileIdentity)
        XCTAssertGreaterThan(originalMetadata.allocatedSize, 0)
        XCTAssertEqual(clonedMetadata.allocatedSize, originalMetadata.allocatedSize)
        XCTAssertNotNil(originalMetadata.cloneIdentity)
        XCTAssertEqual(clonedMetadata.cloneIdentity, originalMetadata.cloneIdentity)
        XCTAssertTrue(originalMetadata.mayShareDataBlocks)
        XCTAssertTrue(clonedMetadata.mayShareDataBlocks)

        let bulkResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
        XCTAssertEqual(bulkResult.entries.count, 2)
        for entry in bulkResult.entries {
            XCTAssertEqual(entry.metadata?.cloneIdentity, originalMetadata.cloneIdentity)
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(children.map(\.logicalSize).reduce(0, +), 8 * 1_024 * 1_024)
        XCTAssertEqual(allocatedSizes.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(snapshot.root.allocatedSize, originalMetadata.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count, 1)
        XCTAssertTrue(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })

        let owner = try XCTUnwrap(children.first(where: { $0.allocatedSize > 0 }))
        let snapshotWithoutOwner = try XCTUnwrap(snapshot.removingNode(id: owner.id))
        let remainingClone = try XCTUnwrap(rootChildren(in: snapshotWithoutOwner).first)
        XCTAssertEqual(remainingClone.allocatedSize, remainingClone.unduplicatedAllocatedSize)
        XCTAssertEqual(snapshotWithoutOwner.root.allocatedSize, remainingClone.allocatedSize)
    }

    func testAPFSClonePreservesUniqueResourceForkAllocation() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "a-original.bin")
        let clonedURL = rootURL.appending(path: "z-clone.bin")

        try Data(repeating: 0xC3, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)
        try setExtendedAttribute(
            named: "com.apple.ResourceFork",
            data: Data(repeating: 0x5A, count: 256 * 1_024),
            at: clonedURL
        )

        let metadataLoader = ScanMetadataLoader()
        let originalMetadata = try metadataLoader.metadata(for: originalURL)
        let clonedMetadata = try metadataLoader.metadata(for: clonedURL)
        XCTAssertEqual(clonedMetadata.cloneIdentity, originalMetadata.cloneIdentity)
        XCTAssertGreaterThan(clonedMetadata.allocatedSize, clonedMetadata.dataAllocatedSize)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let cloneNode = try XCTUnwrap(
            rootChildren(in: snapshot).first(where: { $0.url == clonedURL })
        )
        let expectedCloneAllocation = clonedMetadata.allocatedSize - clonedMetadata.dataAllocatedSize
        let expectedTotal = originalMetadata.allocatedSize + expectedCloneAllocation

        XCTAssertEqual(cloneNode.allocatedSize, expectedCloneAllocation)
        XCTAssertGreaterThan(cloneNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, expectedTotal)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, expectedTotal)
    }

    func testModifiedAPFSCloneRetainsAllocatedStorage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let clonedURL = rootURL.appending(path: "cloned.bin")

        try Data(repeating: 0x5D, count: 4 * 1_024 * 1_024).write(to: originalURL)
        try cloneFileOrSkip(at: originalURL, to: clonedURL)
        let clonedFile = try FileHandle(forWritingTo: clonedURL)
        defer { try? clonedFile.close() }
        try clonedFile.seek(toOffset: 2 * 1_024 * 1_024)
        try clonedFile.write(contentsOf: Data(repeating: 0xA7, count: 4_096))
        try clonedFile.synchronize()

        let metadataLoader = ScanMetadataLoader()
        let originalMetadata = try metadataLoader.metadata(for: originalURL)
        let clonedMetadata = try metadataLoader.metadata(for: clonedURL)
        XCTAssertNil(originalMetadata.cloneIdentity)
        XCTAssertNil(clonedMetadata.cloneIdentity)
        XCTAssertTrue(originalMetadata.mayShareDataBlocks)
        XCTAssertTrue(clonedMetadata.mayShareDataBlocks)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertTrue(children.allSatisfy { $0.allocatedSize > 0 })
        XCTAssertTrue(children.allSatisfy(\.mayShareDataBlocks))
        XCTAssertEqual(snapshot.root.allocatedSize, children.map(\.allocatedSize).reduce(0, +))
    }

    func testParallelTraversalAssignsHardLinkStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaLinkURL = alphaDirectoryURL.appending(path: "linked.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4B, count: 4_096).write(to: betaOriginalURL)
        try FileManager.default.linkItem(at: betaOriginalURL, to: alphaLinkURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaLinkURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 2
        options.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try XCTUnwrap(children(of: alphaNode, in: snapshot).first)
        let betaFile = try XCTUnwrap(children(of: betaNode, in: snapshot).first)

        XCTAssertGreaterThan(alphaFile.allocatedSize, 0)
        XCTAssertEqual(betaFile.allocatedSize, 0)
        XCTAssertEqual(alphaNode.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(betaNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
    }

    func testParallelTraversalAssignsAPFSCloneStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaCloneURL = alphaDirectoryURL.appending(path: "cloned.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x81, count: 4 * 1_024 * 1_024).write(to: betaOriginalURL)
        try cloneFileOrSkip(at: betaOriginalURL, to: alphaCloneURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaCloneURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 2
        options.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try XCTUnwrap(children(of: alphaNode, in: snapshot).first)
        let betaFile = try XCTUnwrap(children(of: betaNode, in: snapshot).first)

        XCTAssertGreaterThan(alphaFile.allocatedSize, 0)
        XCTAssertEqual(betaFile.allocatedSize, 0)
        XCTAssertEqual(alphaNode.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(betaNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
    }

    func testScanTargetNormalizesSyntheticRootAliases() {
        let nofollowTarget = ScanTarget(url: URL(filePath: "/.nofollow/Users/example", directoryHint: .isDirectory))
        let resolveTarget = ScanTarget(url: URL(filePath: "/.resolve/System/Volumes/Data", directoryHint: .isDirectory))
        let rootAliasTarget = ScanTarget(url: URL(filePath: "/.nofollow", directoryHint: .isDirectory))

        XCTAssertEqual(nofollowTarget.url.path, "/Users/example")
        XCTAssertEqual(resolveTarget.url.path, "/System/Volumes/Data")
        XCTAssertEqual(rootAliasTarget.url.path, "/")
        XCTAssertEqual(rootAliasTarget.kind, .volume)
    }

    func testScanTargetResolvesSymlinkRoots() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let symlinkURL = rootURL.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let target = ScanTarget(url: symlinkURL)

        XCTAssertEqual(target.url.path, realDirectory.path)
        XCTAssertEqual(target.id, realDirectory.path)
    }

    func testStartupVolumeScanExcludesSyntheticAndDuplicateNamespaces() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.nofollow", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.resolve", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/System/Library", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanDirectoryEntryFilter.includes(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testVolumeSnapshotAddsSystemAndUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        let target = ScanTarget(url: rootURL, kind: .volume)
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: target, options: ScanOptions()) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let syntheticNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))

        XCTAssertEqual(syntheticNode.name, "System & Unattributed")
        XCTAssertTrue(syntheticNode.isAccessible)
        XCTAssertTrue(snapshot.root.isAccessible)
        XCTAssertFalse(syntheticNode.supportsFileActions)
        XCTAssertEqual(syntheticNode.logicalSize, 0)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.totalAllocatedSize, rootChildren(in: snapshot).filter { !$0.isSynthetic }.reduce(0) { $0 + $1.allocatedSize })
    }

    func testRemovingVolumeNodeTransfersItsAllocationToUnattributedStorage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: ScanOptions(),
            engine: ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        )
        let originalUsedSize = snapshot.root.allocatedSize
        let originalRemainder = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))
        let fileNode = try XCTUnwrap(snapshot.treeStore.node(id: fileURL.path))

        let updated = try XCTUnwrap(snapshot.removingNode(id: fileURL.path))
        let updatedRemainder = try XCTUnwrap(rootChildren(in: updated).first(where: \.isSynthetic))

        XCTAssertEqual(updated.root.allocatedSize, originalUsedSize)
        XCTAssertEqual(updatedRemainder.allocatedSize, originalRemainder.allocatedSize + fileNode.allocatedSize)
        XCTAssertEqual(updatedRemainder.logicalSize, 0)
    }

    func testCapacityReconciliationPolicyExcludesAllAPFSVolumes() {
        XCTAssertFalse(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: " APFS "
            )
        )
        XCTAssertFalse(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: "apfs"
            )
        )
        XCTAssertTrue(
            ScanEngine.shouldReconcileVolumeCapacity(
                fileSystemType: "hfs"
            )
        )
    }

    func testStartupVolumeFirmlinksSkipDescriptorIdentityVerification() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/Applications", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/usr/local", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.verifiesDirectoryIdentity(
                at: URL(filePath: "/Applications", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testAPFSVolumeSnapshotKeepsScannedAllocatedTotal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x5A, count: 1_024).write(to: rootURL.appending(path: "payload.bin"))

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "apfs" })
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: ScanOptions(),
            engine: engine
        )
        let children = rootChildren(in: snapshot)

        XCTAssertFalse(children.contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.allocatedSize, children.reduce(0) { $0 + $1.allocatedSize })
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testDirectoryChildrenAreOrderedDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for (index, name) in ["zeta.txt", "file-10.txt", "file-2.txt", "alpha.txt"].enumerated() {
            try Data(repeating: UInt8(index), count: 16).write(to: rootURL.appending(path: name))
        }
        try Data(repeating: 0x42, count: 16_384).write(to: rootURL.appending(path: "large.bin"))

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertEqual(
            rootChildren(in: snapshot).map(\.name),
            ["large.bin", "alpha.txt", "file-2.txt", "file-10.txt", "zeta.txt"]
        )
    }

    func testParallelDirectoryClassificationMatchesSerialClassification() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "file-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: (index % 7) + 1).write(to: fileURL)
        }

        for index in 0..<16 {
            let directoryURL = rootURL.appending(path: String(format: "folder-%03d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 9).write(to: directoryURL.appending(path: "payload.txt"))
        }

        try Data(repeating: 0xA, count: 64).write(to: rootURL.appending(path: "excluded.log"))

        var serialOptions = ScanOptions()
        serialOptions.exclusionPatterns = ["*.log"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.exclusionPatterns = ["*.log"]
        parallelOptions.directoryTraversalWorkerLimit = 1
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertFalse(rootChildren(in: parallelSnapshot).contains(where: { $0.name == "excluded.log" }))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.isAccessible, serialSnapshot.root.isAccessible)
        XCTAssertEqual(parallelSnapshot.root.isSelfAccessible, serialSnapshot.root.isSelfAccessible)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
    }

    func testParallelDirectoryTraversalAndClassificationMatchSerialScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "root-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: 8 + (index % 11)).write(to: fileURL)
        }

        for directoryIndex in 0..<8 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<160 {
                let fileURL = directoryURL.appending(path: String(format: "payload-%03d.bin", fileIndex))
                try Data(repeating: UInt8((directoryIndex + fileIndex) % 256), count: 4 + (fileIndex % 5)).write(to: fileURL)
            }

            try Data(repeating: 0xD, count: 32).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
            XCTAssertEqual(parallelChild.isAccessible, serialChild.isAccessible)
            XCTAssertEqual(parallelChild.isSelfAccessible, serialChild.isSelfAccessible)
        }
    }

    func testParallelDirectoryTraversalMatchesSerialTraversal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<12 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<6 {
                let fileURL = directoryURL.appending(path: String(format: "direct-%02d.dat", fileIndex))
                try Data(repeating: UInt8(directoryIndex + fileIndex), count: 32 + directoryIndex + fileIndex).write(to: fileURL)
            }

            for nestedIndex in 0..<4 {
                let nestedURL = directoryURL.appending(path: String(format: "nested-%02d", nestedIndex), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

                for fileIndex in 0..<3 {
                    let fileURL = nestedURL.appending(path: String(format: "payload-%02d.bin", fileIndex))
                    try Data(repeating: UInt8(nestedIndex + fileIndex), count: 17 + nestedIndex + fileIndex).write(to: fileURL)
                }
            }

            try Data(repeating: 0xC, count: 128).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
        }
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })
    }

    func testProgressFractionIsMonotonicAndCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<3 {
            let directoryURL = rootURL.appending(path: "Folder-\(directoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<4 {
                let fileURL = directoryURL.appending(path: "File-\(fileIndex).txt")
                try Data(repeating: UInt8(fileIndex), count: 1_024).write(to: fileURL)
            }
        }

        let engine = ScanEngine()
        var progressFractions: [Double] = []

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            }
        }

        XCTAssertFalse(progressFractions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressFractions.last), 1, accuracy: 0.0001)

        for pair in zip(progressFractions, progressFractions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
        }
    }

    func testInFlightAtomicSummaryWorkFoldsIntoTraversalProgress() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 1
        metrics.completedTraversalWeight = 0.2
        metrics.atomicSummaryCompletedTraversalWeight = 0.3

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.5 * 0.95, accuracy: 0.0001)
    }

    func testKnownPendingSummariesUseObservedDescendantWorkInCountCap() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 10_000
        metrics.discoveredItems = 4
        metrics.completedItems = 2
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.9
        metrics.pendingPackageSummaryCount = 2
        metrics.completedPackageSummaryCount = 1
        metrics.completedPackageSummaryVisitedItemCount = 10_000
        metrics.completedSummaryAdditionalVisitedItemCount = 10_000

        metrics.recalculateProgress()

        let expectedCountFraction = 10_003.0 / 30_003.0
        XCTAssertEqual(metrics.progressFraction, expectedCountFraction * 0.95, accuracy: 0.0001)
    }

    func testUnobservedPendingSummaryRetainsConservativeRemainingWork() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 1
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.9
        metrics.pendingPackageSummaryCount = 1

        metrics.recalculateProgress()

        let expectedCountFraction = 1.0 / 65.0
        XCTAssertEqual(metrics.progressFraction, expectedCountFraction * 0.95, accuracy: 0.0001)
    }

    func testSummaryOnlyWorkParticipatesInCountCapWithoutOrdinaryEnumeration() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 1
        metrics.completedTraversalWeight = 0.9
        metrics.pendingPackageSummaryCount = 1
        metrics.atomicSummaryVisitedItems = 100
        metrics.atomicSummaryEstimatedRemainingItems = 900
        metrics.activeAtomicSummaryCount = 1
        metrics.activePackageSummaryCount = 1
        metrics.activePackageSummaryVisitedItems = 100
        metrics.activePackageSummaryEstimatedRemainingItems = 900

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.1 * 0.95, accuracy: 0.0001)
    }

    func testSummaryVisitedWorkUsesSameUnitsAcrossOverlayCommitTransition() {
        var active = ScanMetrics()
        active.discoveredItems = 4
        active.completedItems = 1
        active.enumeratedDirectoryCount = 1
        active.completedTraversalWeight = 0.5
        active.atomicSummaryCompletedTraversalWeight = 0.4
        active.atomicSummaryVisitedItems = 1_000
        active.activeAtomicSummaryCount = 1
        active.activePackageSummaryCount = 1
        active.activePackageSummaryVisitedItems = 1_000
        active.pendingPackageSummaryCount = 1
        active.recalculateProgress()

        var committed = ScanMetrics()
        committed.discoveredItems = 4
        committed.completedItems = 2
        committed.enumeratedDirectoryCount = 1
        committed.completedTraversalWeight = 0.9
        committed.completedSummaryAdditionalVisitedItemCount = 1_000
        committed.completedPackageSummaryCount = 1
        committed.completedPackageSummaryVisitedItemCount = 1_000
        committed.recalculateProgress()

        XCTAssertEqual(active.progressFraction, 0.9 * 0.95, accuracy: 0.0001)
        XCTAssertEqual(committed.progressFraction, active.progressFraction, accuracy: 0.0001)
    }

    func testCountCapStillBindsPlainTraversalWeight() {
        var metrics = ScanMetrics()
        // Same skewed tree as below: the cap must still bind plain traversal weight.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.40)
    }

    func testInFlightAtomicSummaryWorkParticipatesInCountCap() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 10
        metrics.completedItems = 2
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.9
        metrics.atomicSummaryVisitedItems = 1_000
        metrics.atomicSummaryEstimatedRemainingItems = 9_000
        metrics.activeAtomicSummaryCount = 1
        metrics.activePackageSummaryCount = 1
        metrics.activePackageSummaryVisitedItems = 1_000
        metrics.activePackageSummaryEstimatedRemainingItems = 9_000
        metrics.pendingPackageSummaryCount = 1

        metrics.recalculateProgress()

        let expectedCountFraction = 1_003.0 / 10_009.0
        XCTAssertEqual(metrics.progressFraction, expectedCountFraction * 0.95, accuracy: 0.0001)
    }

    func testActiveAutoSummaryTransfersRepresentedChildrenOutOfOrdinaryWork() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 1_001
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.99
        metrics.pendingAutoSummaryRepresentedItemCount = 1_000
        metrics.atomicSummaryVisitedItems = 900
        metrics.atomicSummaryEstimatedRemainingItems = 100
        metrics.activeAtomicSummaryCount = 1
        metrics.activeAutoSummaryRepresentedItemCount = 1_000

        metrics.recalculateProgress()

        let expectedCountFraction = 901.0 / 1_001.0
        XCTAssertEqual(metrics.progressFraction, expectedCountFraction * 0.95, accuracy: 0.0001)
    }

    func testMixedSummaryPopulationsAddDisjointRemainingWork() {
        var metrics = ScanMetrics()
        metrics.discoveredItems = 103
        metrics.enumeratedDirectoryCount = 1
        metrics.completedTraversalWeight = 0.9
        metrics.pendingPackageSummaryCount = 2
        metrics.pendingAutoSummaryRepresentedItemCount = 100
        metrics.atomicSummaryVisitedItems = 150
        metrics.atomicSummaryEstimatedRemainingItems = 950
        metrics.activeAtomicSummaryCount = 2
        metrics.activePackageSummaryCount = 1
        metrics.activePackageSummaryVisitedItems = 100
        metrics.activePackageSummaryEstimatedRemainingItems = 900
        metrics.activeAutoSummaryRepresentedItemCount = 100

        metrics.recalculateProgress()

        // Active work has 950 units remaining. The second, not-yet-registered
        // package independently contributes the active package's 1,000-unit estimate.
        let expectedCountFraction = 151.0 / 2_101.0
        XCTAssertEqual(metrics.progressFraction, expectedCountFraction * 0.95, accuracy: 0.0001)
    }

    func testFinalizationProgressIsEmittedDuringAssembly() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<700 {
            let directoryURL = rootURL.appending(path: "Folder-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let engine = ScanEngine()
        var finalizingProgress: [ScanMetrics] = []
        var didFinish = false

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            switch event {
            case .progress(let metrics) where metrics.isFinalizing:
                finalizingProgress.append(metrics)
            case .finished:
                didFinish = true
            case .executionMode, .progress, .warning:
                break
            }
        }

        XCTAssertTrue(didFinish)
        XCTAssertGreaterThanOrEqual(finalizingProgress.count, 2)

        for pair in zip(finalizingProgress, finalizingProgress.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.progressFraction, pair.0.progressFraction)
        }
    }

    func testEmptyDirectoryScanProducesEmptyRootNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertTrue(snapshot.root.isDirectory)
        XCTAssertEqual(snapshot.root.url.path, rootURL.path)
        XCTAssertTrue(rootChildren(in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.aggregateStats.directoryCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 0)
    }

    func testEmptySubdirectoryIsRetainedInTree() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let emptyDirectoryURL = rootURL.appending(path: "Empty", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.txt")

        try FileManager.default.createDirectory(at: emptyDirectoryURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let emptyNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Empty" }))
        XCTAssertTrue(emptyNode.isDirectory)
        XCTAssertTrue(children(of: emptyNode, in: snapshot).isEmpty)
        XCTAssertEqual(emptyNode.descendantFileCount, 0)
    }

    func testByteEstimatePreventsPrematureFinalizingProgress() {
        var metrics = ScanMetrics()
        metrics.estimatedTotalBytes = 10_000
        metrics.discoveredItems = 6
        metrics.completedItems = 5
        metrics.filesVisited = 500
        metrics.bytesDiscovered = 1_200

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.5)
        XCTAssertFalse(metrics.isFinalizing)
    }

    func testTraversalWeightDrivesProgressWithoutByteEstimate() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 10
        metrics.completedTraversalWeight = 0.5

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.5 * 0.95, accuracy: 0.0001)
    }

    func testDirectoryScanProgressStaysLowWhenLittleWeightIsCompleted() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 5_000
        metrics.discoveredItems = 5_200
        metrics.completedItems = 5_000
        metrics.bytesDiscovered = 50_000_000_000
        metrics.completedTraversalWeight = 0.02

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.05)
    }

    func testFrontierExtrapolationCapsProgressInSkewedTrees() {
        var metrics = ScanMetrics()
        // 2,000 flat files completed; one giant unexplored sibling directory remains.
        // The weight model alone would report ~99% here.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.35)
    }

    func testItemCountCapAppliesWhenFrontierDrainsButFilesRemain() {
        var metrics = ScanMetrics()
        // 1,000 sibling files completed, then one directory was enumerated and yielded
        // 5,000 flat files (no subdirectories), draining the frontier to zero. Most of the
        // discovered files are still unprocessed, but the weight model alone reports ~94%
        // because the 1,000 completed files held nearly all of the root's split weight.
        metrics.filesVisited = 1_000
        metrics.discoveredItems = 6_001
        metrics.completedItems = 1_000
        metrics.enumeratedDirectoryCount = 2
        metrics.pendingDirectoryCount = 0
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 1_000.0 / 1_008.0

        metrics.recalculateProgress()

        // The item-count cap, (completed + enumerated) / discovered ≈ 0.167, must hold the
        // bar near the true ~17% rather than letting the weight estimate jump to ~94%.
        XCTAssertLessThan(metrics.progressFraction, 0.30)
    }

    func testVolumeByteEstimateBlendsWithTraversalWeight() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.estimatedTotalBytes = 1_000
        metrics.bytesDiscovered = 500
        metrics.completedTraversalWeight = 0.3

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, ((0.3 + 0.5) / 2) * 0.95, accuracy: 0.0001)
    }

    func testFinalizationProgressMapsAboveTraversalSpan() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.completedTraversalWeight = 1
        metrics.recalculateProgress()

        metrics.isFinalizing = true
        metrics.finalizationFraction = 0.5
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.97, accuracy: 0.0001)

        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.99, accuracy: 0.0001)

        metrics.recalculateProgress(isComplete: true)
        XCTAssertEqual(metrics.progressFraction, 1, accuracy: 0.0001)
    }

    func testDirectoryBelowThresholdNotAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory with small files — well below the default 5,000-file threshold
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 100 small files — below the default 5,000 threshold
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)  // 64 bytes each
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        // The cache directory should NOT be auto-summarized (only 100 files, below threshold)
        // This test verifies the mechanism doesn't trigger at low file counts
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with only 100 files should not be auto-summarized")
        XCTAssertTrue(cacheNode.isDirectory)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
    }

    func testAutoSummarizedDirectoryShowsFileCount() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a regular file for comparison
        let fileURL = rootURL.appending(path: "document.txt")
        try Data("Hello, World!".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let fileNode = try XCTUnwrap(rootChildren(in: snapshot).first)
        XCTAssertFalse(fileNode.isAutoSummarized)
        XCTAssertEqual(fileNode.itemKind, "File")
        XCTAssertNil(fileNode.secondaryStatusText)
    }

    func testAutoSummarizeCanBeDisabledViaOptions() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a deep directory structure
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create many small files
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)
        }

        // Scan with autoSummarize disabled
        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        // Even with many files, the directory should NOT be auto-summarized
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 100)
    }

    func testCoreSimulatorUsesOrdinaryAutoSummaryCriteria() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let coreSimulatorURL = rootURL.appending(
            path: "Library/Developer/CoreSimulator",
            directoryHint: .isDirectory
        )
        let appDataURL = coreSimulatorURL
            .appending(path: "Devices/00000000-0000-0000-0000-000000000001/data/Containers/Data/Application")
            .appending(path: "ExampleData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            try Data(repeating: UInt8(index), count: 128)
                .write(to: appDataURL.appending(path: "payload-\(index).bin"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 1
        options.autoSummarizeMinDepthForSummarization = 2
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let developerNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Developer" }))
        let coreSimulatorNode = try XCTUnwrap(children(of: developerNode, in: snapshot).first(where: { $0.name == "CoreSimulator" }))

        XCTAssertFalse(coreSimulatorNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(coreSimulatorNode, in: snapshot))
        XCTAssertEqual(coreSimulatorNode.descendantFileCount, 12)
    }

    func testDirectoryIsAutoSummarizedWithLowThresholds() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2: rootURL/projects/cache/
        // Depth 0 = rootURL, depth 1 = projects, depth 2 = cache
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 20 small files — enough to trigger with low thresholds
        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)  // 32 bytes each
        }

        // Use low thresholds: min 10 files, max 256 bytes average, min depth 2
        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized, "Directory should be auto-summarized with low thresholds")
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot), "Auto-summarized directory should have no children")
        XCTAssertEqual(cacheNode.descendantFileCount, 20, "Should report correct file count")
        XCTAssertEqual(cacheNode.itemKind, "Summarized")
        XCTAssertEqual(cacheNode.secondaryStatusText, "Summarized (20 files)")
    }

    func testDeepTinyFileDirectoryIsAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
    }

    #if DEBUG
    func testSuccessfulAtomicProbeResumesTraversalState() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<12 {
            let shardURL = rootURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "payload.bin"))
        }

        let diagnostics = ScanDiagnostics(environment: [
            "RADIX_SCAN_DIAGNOSTICS_LIMIT": "20",
            "RADIX_SCAN_DIAGNOSTICS_SLOW_MS": "0"
        ])
        let metadataLoader = ScanMetadataLoader(diagnostics: diagnostics)
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )).entries
        let pool = AtomicDirectorySummaryPool(workerLimit: 4, progressEmissionInterval: 0)
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            diagnostics: diagnostics,
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

        let summary = try await summarizer.summaryDecisionIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: false,
            isNodeDependencyLayout: false,
            minFileCount: 10,
            maxAverageFileSize: 256,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &metrics,
            continuation: progressContinuation,
            emissionState: &emissionState
        ).summary
        await pool.finish()
        _ = progressStream

        XCTAssertEqual(summary?.descendantFileCount, 12)
        XCTAssertEqual(summary?.logicalSize, 384)
        let report = diagnostics.makeReport(targetPath: rootURL.path, elapsedSeconds: 0)
        XCTAssertTrue(report.contains("atomic.summary.pool"))
        let cursorOpenLine = try XCTUnwrap(
            report.split(separator: "\n").first { $0.contains("bulk.cursor.open: ") }
        )
        XCTAssertTrue(cursorOpenLine.contains("count=13"))
    }
    #endif

    func testAtomicProbeCursorCapAcrossDepths() throws {
        let temporaryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let metadataLoader = ScanMetadataLoader()
        let pool = AtomicDirectorySummaryPool(workerLimit: 1)
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            summaryPool: pool
        )

        for depth in [32, 64, 128, 256] {
            let rootURL = temporaryURL.appending(
                path: "depth-\(depth)",
                directoryHint: .isDirectory
            )
            var deepestURL = rootURL
            for _ in 0..<depth {
                deepestURL.append(path: "d", directoryHint: .isDirectory)
            }
            try FileManager.default.createDirectory(
                at: deepestURL,
                withIntermediateDirectories: true
            )
            try Data([0x11]).write(to: deepestURL.appending(path: "payload.bin"))

            let rootMetadata = try metadataLoader.metadata(for: rootURL)
            let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            )).entries
            let (_, continuation) = makeAtomicSummaryProgressReporter()
            defer { continuation.finish() }
            var metrics = ScanMetrics()
            var emissionState = ScanEmissionState()

            let outcome = try summarizer.descendantAtomicProbeProfile(
                at: rootURL,
                rootEntries: rootEntries,
                rootMetadata: rootMetadata,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: true,
                isNodeDependencyLayout: true,
                minFileCount: 1,
                maxAverageFileSize: 256,
                exclusionMatcher: ScanExclusionMatcher(patterns: [], rootURL: rootURL),
                cancellationCheck: {},
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )

            let resumeState = try XCTUnwrap(outcome.resumeState)
            defer { resumeState.invalidateCursors() }
            XCTAssertEqual(outcome.visitedItemCount, depth + 1, "depth \(depth)")
            XCTAssertEqual(outcome.profile.observedDirectoryCount, depth, "depth \(depth)")
            XCTAssertEqual(resumeState.workItems.count, depth + 1, "depth \(depth)")
            XCTAssertEqual(
                resumeState.workItems.count { $0.cursor != nil },
                min(depth, 64),
                "depth \(depth)"
            )
            XCTAssertFalse(resumeState.workItems.contains { $0.needsCursor }, "depth \(depth)")
        }
    }

    func testResumedAtomicProbeMatchesFullSummarySemantics() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var shardURLs: [URL] = []
        for index in 0..<14 {
            let shardURL = rootURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            shardURLs.append(shardURL)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "payload.bin"))
        }
        let originalURL = shardURLs[0].appending(path: "original.bin")
        let linkedURL = shardURLs[13].appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 64).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)
        try Data(repeating: 0xEE, count: 4_096).write(to: shardURLs[1].appending(path: "ignored.tmp"))
        try Data(repeating: 0xDD, count: 2_048).write(to: shardURLs[2].appending(path: ".hidden.bin"))
        try FileManager.default.createSymbolicLink(
            at: shardURLs[3].appending(path: "cycle"),
            withDestinationURL: rootURL
        )

        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: false,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )).entries
        let pool = AtomicDirectorySummaryPool(workerLimit: 4, progressEmissionInterval: 0)
        let summarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            summaryPool: pool
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: ["*.tmp"],
            rootURL: rootURL
        )
        var progressContinuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let progressStream = AsyncThrowingStream<ScanProgressEvent, Error> { continuation in
            progressContinuation = continuation
        }
        defer { progressContinuation.finish() }
        var referenceMetrics = ScanMetrics()
        var resumedMetrics = ScanMetrics()
        var resumedEmissionState = ScanEmissionState()

        let reference = try await summarizer.summarize(
            at: rootURL,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            ownerNodeID: rootURL.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &referenceMetrics,
            continuation: progressContinuation
        )
        let resumed = try await summarizer.summaryDecisionIfNeeded(
            url: rootURL,
            childEntries: rootEntries,
            metadata: rootMetadata,
            includeHiddenFiles: false,
            treatPackagesAsDirectories: false,
            isNodeDependencyLayout: false,
            minFileCount: 10,
            maxAverageFileSize: 256,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: {},
            metrics: &resumedMetrics,
            continuation: progressContinuation,
            emissionState: &resumedEmissionState
        ).summary
        await pool.finish()
        _ = progressStream

        XCTAssertEqual(resumed?.descendantFileCount, reference?.descendantFileCount)
        XCTAssertEqual(resumed?.logicalSize, reference?.logicalSize)
        XCTAssertEqual(resumed?.allocatedSize, reference?.allocatedSize)
        XCTAssertEqual(resumed?.isAccessible, reference?.isAccessible)
        XCTAssertEqual(resumed?.warnings.count, reference?.warnings.count)
        let hardLinkIdentity = try XCTUnwrap(metadataLoader.metadata(for: originalURL).fileIdentity)
        XCTAssertEqual(
            resumed?.sharedAllocationAccumulator.winner(for: hardLinkIdentity)?.path,
            reference?.sharedAllocationAccumulator.winner(for: hardLinkIdentity)?.path
        )
        XCTAssertEqual(
            resumed?.sharedAllocationAccumulator.duplicateAllocatedSizeByOwner,
            reference?.sharedAllocationAccumulator.duplicateAllocatedSizeByOwner
        )
        XCTAssertEqual(resumed?.sharedAllocationAccumulator.identityCount, 1)
    }

    func testNodeModulesPnpmStoreAutoSummarizesAtShallowDepth() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/left-pad@1.3.0/node_modules/left-pad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: packageURL.appending(path: "file-\(index).js"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testScopedNodePackageContainerAutoSummarizesAtShallowDepth() async throws {
        let nodeModulesURL = try makeTemporaryDirectory().appending(path: "node_modules", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: nodeModulesURL.deletingLastPathComponent()) }

        let packageURL = nodeModulesURL
            .appending(path: "@radix-ui/colors/dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 24)
                .write(to: packageURL.appending(path: "token-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: nodeModulesURL),
            options: options
        )

        let scopeNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "@radix-ui" }))
        XCTAssertTrue(scopeNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(scopeNode, in: snapshot))
        XCTAssertEqual(scopeNode.descendantFileCount, 20)
    }

    func testNestedNodeModulesForestAutoSummarizesThroughSparseParent() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nodeModulesURL = rootURL
            .appending(path: "workspace/packages/app/node_modules", directoryHint: .isDirectory)
        let packageURL = nodeModulesURL
            .appending(path: "vite/dist/client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 40)
                .write(to: packageURL.appending(path: "chunk-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let workspaceNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "workspace" }))
        let packagesNode = try XCTUnwrap(children(of: workspaceNode, in: snapshot).first(where: { $0.name == "packages" }))
        let appNode = try XCTUnwrap(children(of: packagesNode, in: snapshot).first(where: { $0.name == "app" }))
        let nodeModulesNode = try XCTUnwrap(children(of: appNode, in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testSparseAncestorDefersAutoSummarizationToDenseDescendant() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        let denseURL = cacheURL.appending(path: "dense", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: denseURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: denseURL.appending(path: "payload-\(index).tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        let denseNode = try XCTUnwrap(children(of: cacheNode, in: snapshot).first(where: { $0.name == "dense" }))

        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(denseNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(denseNode, in: snapshot))
        XCTAssertEqual(denseNode.descendantFileCount, 20)
    }

    func testAutoSummarizedDirectoryIncludesPackageLeafContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        let packageBinaryURL = cacheURL
            .appending(path: "Tool.app", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Tool")
        try FileManager.default.createDirectory(at: packageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: packageBinaryURL)

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 13)
        XCTAssertGreaterThanOrEqual(cacheNode.logicalSize, (12 * 32) + 2_048)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 13)

        let rebuiltStore = FileTreeStore(
            rootID: snapshot.treeStore.rootID,
            nodesByID: snapshot.treeStore.nodesByID,
            childIDsByID: snapshot.treeStore.childIDsByID
        )
        let scannedStats = snapshot.aggregateStats
        let rebuiltStats = rebuiltStore.aggregateStats
        XCTAssertEqual(scannedStats.fileCount, rebuiltStats.fileCount)
        XCTAssertEqual(scannedStats.directoryCount, rebuiltStats.directoryCount)
        XCTAssertEqual(scannedStats.accessibleItemCount, rebuiltStats.accessibleItemCount)
        XCTAssertEqual(scannedStats.inaccessibleItemCount, rebuiltStats.inaccessibleItemCount)
        XCTAssertEqual(scannedStats.totalAllocatedSize, rebuiltStats.totalAllocatedSize)
        XCTAssertEqual(scannedStats.totalLogicalSize, rebuiltStats.totalLogicalSize)
    }

    func testAutoSummarizedDirectoryCountsAsSingleVisitedDirectory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var finalMetrics = ScanMetrics()

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .progress(let metrics) = event {
                finalMetrics = metrics
            }
        }

        XCTAssertEqual(finalMetrics.directoriesVisited, 3)
        XCTAssertEqual(finalMetrics.filesVisited, 20)
    }

    func testAutoSummarizedDirectoryReleasesChildDirectoryDiscoveryCounts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var progressSnapshots: [ScanMetrics] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .executionMode:
                break
            case .progress(let metrics):
                progressSnapshots.append(metrics)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let finalMetrics = try XCTUnwrap(progressSnapshots.last)
        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(finalMetrics.enumeratedDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.discoveredDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.pendingDirectoryCount, 0)
        XCTAssertEqual(finalMetrics.progressFraction, 1, accuracy: 0.0001)
    }

    func testDirectoryNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2 with 20 LARGE files
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).dat")
            try Data(repeating: UInt8(i % 256), count: 100_000).write(to: fileURL)  // 100 KB each
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 4_096  // 4 KB max average
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with large files should not be auto-summarized")
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 20)
    }

    func testRejectedAutoSummaryProbeReusesCompleteListingsWithoutChangingResults() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cacheURL = rootURL.appending(
            path: "projects/cache",
            directoryHint: .isDirectory
        )
        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: shardURL.appending(path: "payload.bin"))
            try Data([0xFF]).write(to: shardURL.appending(path: "ignored.tmp"))
        }

        var options = ScanOptions()
        options.exclusionPatterns = ["*.tmp"]
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        #if DEBUG
        let profile = AutoSummaryEventProbe()
        let enabledEngine = ScanEngine(autoSummaryProfileReporter: profile.record)
        #else
        let enabledEngine = ScanEngine()
        #endif
        let enabledSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: enabledEngine
        )
        options.autoSummarizeDirectories = false
        let disabledSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        #if DEBUG
        XCTAssertGreaterThan(profile.rejectedProbeCount, 0)
        XCTAssertGreaterThan(profile.reusedDirectoryCount, 0)
        XCTAssertGreaterThan(profile.reusedEntryCount, 0)
        #endif
        let expectedNodeIDs = disabledSnapshot.treeStore.indexedNodeIDs()
        XCTAssertEqual(enabledSnapshot.treeStore.indexedNodeIDs(), expectedNodeIDs)
        for nodeID in expectedNodeIDs {
            XCTAssertEqual(
                enabledSnapshot.treeStore.node(id: nodeID),
                disabledSnapshot.treeStore.node(id: nodeID),
                nodeID
            )
            XCTAssertEqual(
                enabledSnapshot.treeStore.children(of: nodeID).map(\.id),
                disabledSnapshot.treeStore.children(of: nodeID).map(\.id),
                nodeID
            )
        }
        XCTAssertEqual(
            enabledSnapshot.aggregateStats.totalAllocatedSize,
            disabledSnapshot.aggregateStats.totalAllocatedSize
        )
        XCTAssertEqual(
            enabledSnapshot.aggregateStats.totalLogicalSize,
            disabledSnapshot.aggregateStats.totalLogicalSize
        )
        XCTAssertEqual(enabledSnapshot.aggregateStats.fileCount, disabledSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(enabledSnapshot.aggregateStats.directoryCount, disabledSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(
            enabledSnapshot.aggregateStats.accessibleItemCount,
            disabledSnapshot.aggregateStats.accessibleItemCount
        )
        XCTAssertEqual(
            enabledSnapshot.aggregateStats.inaccessibleItemCount,
            disabledSnapshot.aggregateStats.inaccessibleItemCount
        )
    }

    #if DEBUG
    func testExhaustedAutoSummaryProbeSuppressesRedundantDescendantProbes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cacheURL = rootURL.appending(path: "projects/cache", directoryHint: .isDirectory)
        for index in 0..<3 {
            let nestedURL = cacheURL.appending(
                path: "branch-\(index)/nested",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: nestedURL.appending(path: "payload.bin"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2
        let profile = AutoSummaryEventProbe()

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: ScanEngine(autoSummaryProfileReporter: profile.record)
        )

        XCTAssertEqual(profile.probeCount, 1)
        XCTAssertEqual(profile.rejectedProbeCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 3)
        XCTAssertTrue(snapshot.treeStore.indexedNodeIDs().contains { $0.hasSuffix("payload.bin") })
    }
    #endif

    func testNodeDependencyLayoutNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/large-payload@1.0.0/node_modules/large-payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: packageURL.appending(path: "asset-\(index).dat"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertFalse(nodeModulesNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(nodeModulesNode, in: snapshot))
    }

    func testAutoSummarizedDirectoryExcludesHiddenFilesWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        for i in 0..<3 {
            let hiddenFileURL = cacheURL.appending(path: ".hidden_\(i).tmp")
            try Data(repeating: 0x7F, count: 32).write(to: hiddenFileURL)
        }

        var options = ScanOptions(includeHiddenFiles: false)
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
        XCTAssertEqual(cacheNode.logicalSize, 12 * 32)
    }
}

private final class BlockingLiveChildOpen: @unchecked Sendable {
    let didReachChildOpen = DispatchSemaphore(value: 0)
    private let allowChildOpen = DispatchSemaphore(value: 0)
    private let releaseLock = NSLock()
    private var isReleased = false

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        let live = ScanDirectoryDescriptorPool.SystemCalls.live
        return ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: live.openRoot,
            openChild: { [didReachChildOpen, allowChildOpen] parentDescriptor, name in
                didReachChildOpen.signal()
                allowChildOpen.wait()
                return live.openChild(parentDescriptor, name)
            },
            fileIdentity: live.fileIdentity,
            close: live.close
        )
    }

    func release() {
        releaseLock.lock()
        guard !isReleased else {
            releaseLock.unlock()
            return
        }
        isReleased = true
        releaseLock.unlock()
        allowChildOpen.signal()
    }
}

private func makeAtomicSummaryProgressReporter() -> (
    AtomicSummaryProgressReporter,
    AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
) {
    var continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
    _ = AsyncThrowingStream<ScanProgressEvent, Error> {
        continuation = $0
    }
    return (
        AtomicSummaryProgressReporter(metrics: ScanMetrics(), continuation: continuation),
        continuation
    )
}

private func rejectingVolumeBoundaryPolicy(
    for rootURL: URL,
    metadataLoader: ScanMetadataLoader
) throws -> ScanEngine.ScanVolumeBoundaryPolicy {
    let actualDeviceID = try XCTUnwrap(
        metadataLoader.fileSystemIdentity(at: rootURL).fileSystemDeviceID
    )
    return ScanEngine.ScanVolumeBoundaryPolicy.resolve(
        rootPath: rootURL.path,
        rootDeviceID: actualDeviceID ^ 1,
        mountedFileSystems: []
    )
}

private func warningSemantics(_ warnings: [ScanWarning]) -> Set<String> {
    Set(warnings.map { "\($0.path)|\($0.category.rawValue)|\($0.message)" })
}

private func finishedSnapshot(
    target: ScanTarget,
    options: ScanOptions,
    engine: ScanEngine = ScanEngine()
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    XCTFail("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func rootChildren(in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: snapshot.root.id)
}

private func children(of node: FileNodeRecord, in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: node.id)
}

private func containsChildren(_ node: FileNodeRecord, in snapshot: ScanSnapshot) -> Bool {
    snapshot.treeStore.containsChildren(id: node.id)
}

private func cloneFileOrSkip(at sourceURL: URL, to destinationURL: URL) throws {
    let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
        destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
            guard let sourcePath, let destinationPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return clonefile(sourcePath, destinationPath, 0)
        }
    }
    guard result == 0 else {
        let errorCode = errno
        if errorCode == ENOTSUP || errorCode == EXDEV {
            throw XCTSkip("APFS file cloning is unavailable in the test environment")
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
    }
}

private enum AsyncTestTimeout: Error {
    case timedOut
}

private final class DirectoryEnumerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = isCancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class AtomicFoundationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterCheckCount: Int
    private var checkCount = 0

    init(cancelAfterCheckCount: Int) {
        self.cancelAfterCheckCount = cancelAfterCheckCount
    }

    func check() throws {
        lock.lock()
        checkCount += 1
        let isCancelled = checkCount >= cancelAfterCheckCount
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class BlockingAtomicSummaryWorkerProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeOwners: Set<String> = []
    private var seenOwners: Set<String> = []
    private var activeWorkers = 0
    private var peakWorkers = 0
    private var maximumDistinctOwners = 0
    private var isReleased = false

    var activeWorkerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeWorkers
    }

    var peakActiveWorkerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return peakWorkers
    }

    var activeOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeOwners.count
    }

    var seenOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return seenOwners.count
    }

    var maximumDistinctActiveOwnerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumDistinctOwners
    }

    func didStart(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        condition.lock()
        activeWorkers += 1
        peakWorkers = max(peakWorkers, activeWorkers)
        activeOwners.insert(ownerNodeID)
        seenOwners.insert(ownerNodeID)
        maximumDistinctOwners = max(maximumDistinctOwners, activeOwners.count)
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func didFinish(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        condition.lock()
        activeWorkers = max(activeWorkers - 1, 0)
        activeOwners.remove(ownerNodeID)
        condition.broadcast()
        condition.unlock()
    }

    func waitForDistinctActiveOwners(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while activeOwners.count < count, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return activeOwners.count >= count
    }

    func releaseAll() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class AtomicSummaryWorkerLifecycleProbe: @unchecked Sendable {
    enum Event: Equatable {
        case started
        case finished
        case shutdown
    }

    private let lock = NSLock()
    private var activeCount = 0
    private var peakActiveCount = 0
    private var events: [Event] = []

    var activeWorkerCount: Int {
        lock.withLock { activeCount }
    }

    var peakActiveWorkerCount: Int {
        lock.withLock { peakActiveCount }
    }

    var didObserveShutdown: Bool {
        lock.withLock { events.contains(.shutdown) }
    }

    var shutdownCount: Int {
        lock.withLock { events.count(where: { $0 == .shutdown }) }
    }

    var lastEvent: Event? {
        lock.withLock { events.last }
    }

    func didStart() {
        lock.withLock {
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            events.append(.started)
        }
    }

    func didFinish() {
        lock.withLock {
            activeCount = max(activeCount - 1, 0)
            events.append(.finished)
        }
    }

    func didShutdown() {
        lock.withLock {
            events.append(.shutdown)
        }
    }
}

private final class CancellationAfterChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingChecks: Int

    init(_ remainingChecks: Int) {
        self.remainingChecks = remainingChecks
    }

    func check() throws {
        lock.lock()
        remainingChecks -= 1
        let shouldCancel = remainingChecks == 0
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }
}

private final class AtomicSummaryProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}

#if DEBUG
private final class AutoSummaryEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private var rejectedProbes = 0
    private var reusedDirectories = 0
    private var reusedEntries = 0

    var probeCount: Int {
        lock.withLock { probes }
    }

    var rejectedProbeCount: Int {
        lock.withLock { rejectedProbes }
    }

    var reusedDirectoryCount: Int {
        lock.withLock { reusedDirectories }
    }

    var reusedEntryCount: Int {
        lock.withLock { reusedEntries }
    }

    func record(_ event: ScanAutoSummaryProfileEvent) {
        lock.withLock {
            switch event {
            case .probeCompleted(_, let wasAccepted):
                probes += 1
                if !wasAccepted {
                    rejectedProbes += 1
                }
            case .reusedDirectoryListing(let entryCount):
                reusedDirectories += 1
                reusedEntries += entryCount
            case .directorySummarized:
                break
            }
        }
    }
}
#endif

private final class SlowDirectoryObjectEnumerator: ScanEngine.DirectoryObjectEnumerating, @unchecked Sendable {
    let totalCount: Int
    private let rootURL: URL
    private let lock = NSLock()
    private var nextIndex = 0

    init(rootURL: URL, totalCount: Int) {
        self.rootURL = rootURL
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func nextObject() -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < totalCount else { return nil }
        let childURL = rootURL.appending(path: "payload-\(nextIndex).tmp")
        nextIndex += 1
        Thread.sleep(forTimeInterval: 0.0005)
        return childURL
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory object enumeration.", file: file, line: line)
    }
}

private final class CancellableDirectoryContentsProbe: @unchecked Sendable {
    let totalCount: Int
    private let lock = NSLock()
    private var produced = 0

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return produced
    }

    func contents(
        for url: URL,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(totalCount)

        for index in 0..<totalCount {
            if index.isMultiple(of: 8) {
                try cancellationCheck()
            }
            recordProducedChild()
            Thread.sleep(forTimeInterval: 0.0005)
            urls.append(url.appending(path: "payload-\(index).tmp"))
        }

        return urls
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents production.", file: file, line: line)
    }

    private func recordProducedChild() {
        lock.lock()
        produced += 1
        lock.unlock()
    }
}

private final class BlockingDirectoryContentsProbe: @unchecked Sendable {
    private let blockedURL: URL
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    init(blockedURL: URL) {
        self.blockedURL = blockedURL
    }

    func contents(for url: URL) throws -> [URL] {
        guard url == blockedURL else { return [] }

        condition.lock()
        defer { condition.unlock() }
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        return []
    }

    func waitUntilBlocked(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if blocked {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents blocking.", file: file, line: line)
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private var blocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: duration)
            throw AsyncTestTimeout.timedOut
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeout.timedOut
        }
        group.cancelAll()
        return result
    }
}
