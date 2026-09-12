import CoreServices
import Foundation
import Testing

@testable import RadixCore

struct IncrementalScanServiceTests {
    @Test
    func testFSEventFlagMappingPreservesCloneEvents() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCloned
        )

        #expect(FileSystemEventFlags(fseventRawValue: rawFlags) == [.itemCreated, .itemIsFile, .itemCloned])
    }

    @Test
    func testFSEventFlagMappingPreservesHardLinkEvents() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                | kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink
        )

        #expect(
            FileSystemEventFlags(fseventRawValue: rawFlags) == [
                .itemCreated, .itemIsFile, .itemIsHardLink, .itemIsLastHardLink,
            ])
    }

    @Test
    func testDarwinHistoryProviderCapturesCheckpointForLocalDirectory() throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let checkpoint = try DarwinFileSystemEventHistoryProvider()
            .currentCheckpoint(for: rootURL)

        #expect(checkpoint.eventID > 0)
        #expect(!(checkpoint.volumeUUID.isEmpty))
    }

    @Test
    func testDarwinHistoryProviderIncludesFileCreatedAfterCheckpoint() async throws {
        let rootURL = try makeIncrementalFSEventDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let provider = DarwinFileSystemEventHistoryProvider()
        let since = try provider.currentCheckpoint(for: rootURL)
        let createdURL = rootURL.appending(path: "created.dat")

        try Data([0x1]).write(to: createdURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var latestCheckpoint = since

        while ContinuousClock.now < deadline {
            latestCheckpoint = try provider.currentCheckpoint(for: rootURL)
            if latestCheckpoint.eventID > since.eventID {
                let history = try await provider.history(
                    for: rootURL,
                    since: since,
                    through: latestCheckpoint
                )
                if history.events.contains(where: { event in
                    event.path == createdURL.path
                        && event.flags.contains(.itemCreated)
                        && event.flags.contains(.itemIsFile)
                }) {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        Issue.record(
            "FSEvents did not report \(createdURL.path) between event IDs \(since.eventID) and \(latestCheckpoint.eventID)"
        )
    }

    @Test
    func testShallowRelistClassificationBudgetAccountsForConcurrentRelists() {
        var options = ScanOptions()
        options.directoryTraversalWorkerLimit = 4
        options.directoryClassificationWorkerLimit = 8

        let limit = ScanEngine.shallowRelistClassificationWorkerLimit(
            for: options,
            relistWorkerLimit: 4
        )

        #expect(limit >= 1)
        #expect(limit < 8)
    }

    @Test
    func testFullScanReportsFullExecutionMode() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = IncrementalScanService(
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(10)],
                events: []
            )
        )
        let result = try await incrementalScanResult(
            from: service.scan(
                target: ScanTarget(url: rootURL),
                options: ScanOptions()
            )
        )

        #expect(result.executionModes == [.full])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 10)
    }

    @MainActor
    @Test
    func testFullScanCapturesCheckpointOffMainThread() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let history = IncrementalHistoryStub(
            checkpoints: [checkpoint(10)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: history)

        _ = try await incrementalScanResult(
            from: service.scan(
                target: ScanTarget(url: rootURL),
                options: ScanOptions()
            )
        )

        #expect(history.checkpointMainThreadObservations == [false])
    }

    @Test
    func testMissingCheckpointReportsFullFallbackReason() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )
        let service = IncrementalScanService(
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(20)],
                events: []
            )
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        #expect(result.executionModes == [.fullFallback(.checkpointUnavailable)])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
    }

    @Test
    func testChangedOptionsReportFullFallbackReason() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: ScanOptions())
        )
        let changedOptions = ScanOptions(includeHiddenFiles: true)

        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: changedOptions,
                from: baseline
            )
        )

        #expect(result.executionModes == [.fullFallback(.changedScanOptions)])
        #expect(result.snapshot.scanOptions == changedOptions)
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
    }

    @Test
    func testUnavailableEventHistoryReportsFullFallbackReason() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: [],
            beforeReturningHistory: {
                throw FileSystemEventHistoryError.streamStartFailed
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        #expect(result.executionModes == [.fullFallback(.eventHistoryUnavailable)])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 30)
    }

    @Test
    func testCancelledEventHistoryDoesNotStartFullFallback() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: [],
            beforeReturningHistory: {
                throw CancellationError()
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        var executionModes: [ScanExecutionMode] = []
        for try await event in service.rescan(
            target: target,
            options: options,
            from: baseline
        ) {
            if case .executionMode(let mode) = event {
                executionModes.append(mode)
            }
        }

        #expect(executionModes.isEmpty)
    }

    @Test
    func testPlannerFallbackPreservesExactReason() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: [
                FileSystemEventRecord(
                    path: rootURL.path,
                    eventID: 15,
                    flags: [.userDropped]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        #expect(result.executionModes == [.fullFallback(.userDroppedEvents)])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 30)
    }

    @Test
    func testRootShallowRelistAppliesMixedMembershipChanges() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let modifiedURL = rootURL.appending(path: "modified.dat")
        let removedURL = rootURL.appending(path: "removed.dat")
        let createdURL = rootURL.appending(path: "created.dat")
        let createdDirectoryURL = rootURL.appending(
            path: "Created",
            directoryHint: .isDirectory
        )
        try Data([0x1]).write(to: modifiedURL)
        try Data([0x2]).write(to: removedURL)

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: modifiedURL.path,
                    eventID: 14,
                    flags: [.itemModified, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: removedURL.path,
                    eventID: 15,
                    flags: [.itemRemoved, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: createdURL.path,
                    eventID: 16,
                    flags: [.itemCreated, .itemIsFile]
                ),
                FileSystemEventRecord(
                    path: createdDirectoryURL.path,
                    eventID: 17,
                    flags: [.itemCreated, .itemIsDirectory]
                ),
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try Data(repeating: 0x3, count: 8_192).write(to: modifiedURL)
        try FileManager.default.removeItem(at: removedURL)
        try Data([0x4]).write(to: createdURL)
        try FileManager.default.createDirectory(
            at: createdDirectoryURL,
            withIntermediateDirectories: false
        )
        try Data([0x5]).write(to: createdDirectoryURL.appending(path: "nested.dat"))

        let incrementalResult = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let incremental = incrementalResult.snapshot
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        #expect(incremental.incrementalCheckpoint?.eventID == 20)
        #expect(incrementalResult.progressMetrics.last?.directoriesVisited == 1)
        #expect(incrementalResult.progressMetrics.last?.progressFraction ?? 0 > 0)
    }

    @Test
    func testBatchedShallowRelistsMatchFullScanAcrossDirectories() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let directoryURLs = (0..<3).map { index in
            rootURL.appending(path: "Directory-\(index)", directoryHint: .isDirectory)
        }
        for directoryURL in directoryURLs {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            try Data([0x1]).write(to: directoryURL.appending(path: "existing.dat"))
        }
        let changedURLs = directoryURLs.map { $0.appending(path: "changed.dat") }
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: changedURLs.enumerated().map { index, url in
                FileSystemEventRecord(
                    path: url.path,
                    eventID: UInt64(14 + index),
                    flags: [.itemCreated, .itemIsFile]
                )
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        for changedURL in changedURLs {
            try Data(repeating: 0x6, count: 4_096).write(to: changedURL)
        }
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        #expect(incremental.incrementalCheckpoint?.eventID == 20)
    }

    @Test
    func testShallowRelistPreservesAutoSummaryThresholdSemantics() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let parentURL = rootURL.appending(path: "Parent", directoryHint: .isDirectory)
        let candidateURL = parentURL.appending(path: "Candidate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: candidateURL.appending(path: "before.dat"))
        let createdURL = candidateURL.appending(path: "after.dat")

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: createdURL.path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 2
        options.autoSummarizeMaxAverageFileSize = 1_000_000
        options.autoSummarizeMinDepthForSummarization = 2
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        #expect(baseline.treeStore.node(id: candidateURL.path)?.isAutoSummarized == false)

        try Data([0x2]).write(to: createdURL)
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
        #expect(incremental.treeStore.node(id: candidateURL.path)?.isAutoSummarized == true)
        #expect(incremental.incrementalCheckpoint?.eventID == 20)
    }

    @Test
    func testFullScanCapturesCheckpointAndIncrementalRescanRelistsChangedDirectory() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let untouchedURL = rootURL.appending(path: "Untouched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouchedURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: changedURL.appending(path: "before.dat"))
        try Data([0x2]).write(to: untouchedURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: changedURL.appending(path: "after.dat").path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        #expect(baseline.incrementalCheckpoint?.eventID == 10)

        let untouchedBefore = try #require(baseline.treeStore.node(id: untouchedURL.path))
        try Data([0x3]).write(to: changedURL.appending(path: "after.dat"))
        let rescanned = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
        #expect(rescanned.root.descendantFileCount == 3)
        #expect(rescanned.treeStore.node(id: changedURL.path)?.descendantFileCount == 2)
        #expect(rescanned.treeStore.node(id: untouchedURL.path) == untouchedBefore)
        #expect(provider.historyRequestCount == 1)
    }

    @Test
    func testIncrementalRescanMatchesFullScanForHardLinksAcrossSubtrees() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let ownerDirectoryURL = rootURL.appending(path: "A-Owner", directoryHint: .isDirectory)
        let changedDirectoryURL = rootURL.appending(path: "Z-Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ownerDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changedDirectoryURL, withIntermediateDirectories: true)

        let ownerURL = ownerDirectoryURL.appending(path: "shared.dat")
        let changedLinkURL = changedDirectoryURL.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 16_384).write(to: ownerURL)
        try FileManager.default.linkItem(at: ownerURL, to: changedLinkURL)

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: [
                FileSystemEventRecord(
                    path: changedDirectoryURL.appending(path: "new.dat").path,
                    eventID: 15,
                    flags: [.itemCreated, .itemIsFile]
                )
            ]
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try Data([0x1]).write(to: changedDirectoryURL.appending(path: "new.dat"))
        let incremental = try await finishedIncrementalSnapshot(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        try assertEquivalent(incremental, full)
    }

    @Test
    func testMultipleSubtreeRescansReportCumulativeItemCounts() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let directoryURLs = ["First", "Second"].map {
            rootURL.appending(path: $0, directoryHint: .isDirectory)
        }
        for directoryURL in directoryURLs {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            for index in 0..<4 {
                try Data([UInt8(index)]).write(
                    to: directoryURL.appending(path: "file-\(index).dat")
                )
            }
        }

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: directoryURLs.enumerated().map { index, url in
                FileSystemEventRecord(
                    path: url.path,
                    eventID: UInt64(14 + index),
                    flags: [.itemModified, .itemIsDirectory]
                )
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let fileCounts = result.progressMetrics.map(\.filesVisited)
        let directoryCounts = result.progressMetrics.map(\.directoriesVisited)

        #expect(result.executionModes == [.incremental])
        #expect(fileCounts == fileCounts.sorted())
        #expect(directoryCounts == directoryCounts.sorted())
        #expect(fileCounts.last ?? 0 >= 8)
        #expect(directoryCounts.last ?? 0 >= 2)
    }

    @Test
    func testNoChangeRescanAdvancesCheckpointWithoutChangingTree() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "stable.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(30), checkpoint(40)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: ScanOptions())
        )
        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: ScanOptions(),
                from: baseline
            )
        )
        let rescanned = result.snapshot

        #expect(result.executionModes == [.incrementalNoChanges])
        #expect(rescanned.incrementalCheckpoint?.eventID == 40)
        #expect(rescanned.treeStore.contentID == baseline.treeStore.contentID)
        #expect(rescanned.id != baseline.id)
    }

    @Test
    func testSubtreeDisappearingAfterHistoryPlanningFallsBackToFullScan() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: true)
        try Data([0x1]).write(to: changedURL.appending(path: "payload.dat"))

        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: [
                FileSystemEventRecord(
                    path: changedURL.path,
                    eventID: 15,
                    flags: [.itemModified, .itemIsDirectory]
                )
            ],
            beforeReturningHistory: {
                try FileManager.default.removeItem(at: changedURL)
            }
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let rescanned = result.snapshot

        #expect(result.executionModes == [.incremental, .fullFallback(.subtreeRescanFailed)])
        #expect(rescanned.treeStore.node(id: changedURL.path) == nil)
        #expect(rescanned.incrementalCheckpoint?.eventID == 30)
        #expect(provider.historyRequestCount == 1)
    }

    private func checkpoint(_ eventID: UInt64) -> ScanIncrementalCheckpoint {
        ScanIncrementalCheckpoint(volumeUUID: "test-volume", eventID: eventID)
    }

    private func assertEquivalent(
        _ incremental: ScanSnapshot,
        _ full: ScanSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let incrementalNodeIDs = incremental.treeStore.indexedNodeIDs()
        let fullNodeIDs = full.treeStore.indexedNodeIDs()
        #expect(incrementalNodeIDs == fullNodeIDs, sourceLocation: sourceLocation)
        for nodeID in fullNodeIDs {
            #expect(
                try #require(incremental.treeStore.node(id: nodeID)) == (try #require(full.treeStore.node(id: nodeID))),
                Comment(rawValue: nodeID), sourceLocation: sourceLocation)
            #expect(
                incremental.treeStore.childIDs(of: nodeID) == full.treeStore.childIDs(of: nodeID),
                Comment(rawValue: nodeID), sourceLocation: sourceLocation)
        }
        #expect(incremental.aggregateStats.fileCount == full.aggregateStats.fileCount, sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.directoryCount == full.aggregateStats.directoryCount,
            sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.accessibleItemCount == full.aggregateStats.accessibleItemCount,
            sourceLocation: sourceLocation)
        #expect(
            incremental.aggregateStats.inaccessibleItemCount == full.aggregateStats.inaccessibleItemCount,
            sourceLocation: sourceLocation)
        #expect(
            incremental.scanWarnings.map { "\($0.category.rawValue)|\($0.path)|\($0.message)" }.sorted()
                == full.scanWarnings.map { "\($0.category.rawValue)|\($0.path)|\($0.message)" }.sorted(),
            sourceLocation: sourceLocation)
    }
}

private final class IncrementalHistoryStub: FileSystemEventHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints: [ScanIncrementalCheckpoint]
    private let events: [FileSystemEventRecord]
    private let beforeReturningHistory: @Sendable () throws -> Void
    private var historyRequests = 0
    private var checkpointThreadObservations: [Bool] = []

    init(
        checkpoints: [ScanIncrementalCheckpoint],
        events: [FileSystemEventRecord],
        beforeReturningHistory: @escaping @Sendable () throws -> Void = {}
    ) {
        self.checkpoints = checkpoints
        self.events = events
        self.beforeReturningHistory = beforeReturningHistory
    }

    var historyRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return historyRequests
    }

    var checkpointMainThreadObservations: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return checkpointThreadObservations
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        _ = targetURL
        lock.lock()
        defer { lock.unlock() }
        checkpointThreadObservations.append(Thread.isMainThread)
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
        lock.withLock {
            historyRequests += 1
        }
        try beforeReturningHistory()
        return FileSystemEventHistory(since: since, through: through, events: events)
    }
}

private func makeIncrementalTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "radix-incremental-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeIncrementalFSEventDirectory() throws -> URL {
    let packageRootURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url =
        packageRootURL
        .appending(path: ".build/radix-fsevents-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func finishedIncrementalSnapshot(
    from stream: AsyncThrowingStream<ScanProgressEvent, Error>
) async throws -> ScanSnapshot {
    try await incrementalScanResult(from: stream).snapshot
}

private struct IncrementalScanResult {
    let snapshot: ScanSnapshot
    let executionModes: [ScanExecutionMode]
    let progressMetrics: [ScanMetrics]
}

private func incrementalScanResult(
    from stream: AsyncThrowingStream<ScanProgressEvent, Error>
) async throws -> IncrementalScanResult {
    var executionModes: [ScanExecutionMode] = []
    var progressMetrics: [ScanMetrics] = []
    for try await event in stream {
        switch event {
        case .executionMode(let mode):
            executionModes.append(mode)
        case .finished(let snapshot):
            return IncrementalScanResult(
                snapshot: snapshot,
                executionModes: executionModes,
                progressMetrics: progressMetrics
            )
        case .progress(let metrics):
            progressMetrics.append(metrics)
        case .warning:
            break
        }
    }
    Issue.record("Expected a finished incremental scan snapshot")
    throw CancellationError()
}
