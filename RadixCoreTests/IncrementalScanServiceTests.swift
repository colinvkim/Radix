import CoreServices
import Darwin
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var latestCheckpoint = since

        while true {
            try Task.checkCancellation()
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
            // Poll before checking the deadline: parallel fixtures can delay a wakeup
            // even after the OS has delivered the event.
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        Issue.record(
            "FSEvents did not report \(createdURL.path) between event IDs \(since.eventID) and \(latestCheckpoint.eventID)"
        )
    }

    @Test(arguments: ["/tmp/example", "/private/tmp/example", "/System/Volumes/Data/private/tmp/example", "/alias"])
    func testHistoryPathsProjectIntoCapturedScanNamespace(scanPath: String) {
        let volume = DarwinFileSystemEventHistoryProvider.VolumeContext(
            deviceID: 1,
            uuid: "volume",
            rootPath: "/System/Volumes/Data",
            relativeTargetPath: "private/tmp/example",
            scanTargetPath: scanPath
        )

        #expect(volume.scanPath(for: "private/tmp/example") == scanPath)
        #expect(volume.scanPath(for: "private/tmp/example/removed/é.dat") == scanPath + "/removed/é.dat")
        #expect(volume.scanPath(for: "private/tmp/example-other/file") == "/System/Volumes/Data/private/tmp/example-other/file")
        #expect(volume.scanPath(for: "private/tmp") == "/System/Volumes/Data/private/tmp")
        #expect(volume.scanPath(for: "") == "/System/Volumes/Data")
    }

    @Test
    func testHistoryVolumeRootProjectionPreservesScanRoot() {
        let volume = DarwinFileSystemEventHistoryProvider.VolumeContext(
            deviceID: 1,
            uuid: "volume",
            rootPath: "/System/Volumes/Data/Volumes/Recovery",
            relativeTargetPath: "",
            scanTargetPath: "/Volumes/Recovery"
        )
        #expect(volume.scanPath(for: "") == "/Volumes/Recovery")
        #expect(volume.scanPath(for: "folder/deleted") == "/Volumes/Recovery/folder/deleted")
        let root = DarwinFileSystemEventHistoryProvider.VolumeContext(
            deviceID: 1,
            uuid: "volume",
            rootPath: "/",
            relativeTargetPath: "",
            scanTargetPath: "/"
        )
        #expect(root.scanPath(for: "") == "/")
        #expect(root.scanPath(for: "folder/file") == "/folder/file")
    }

    @Test
    func testHistoryCollectorPreservesUncertaintyAndUnmatchedPaths() async throws {
        let collector = makeHistoryCollector()
        try receiveHistoryEvents([
            ("private/tmp/example/before", kFSEventStreamEventFlagItemModified, 10),
            ("private/tmp/example/removed", kFSEventStreamEventFlagItemRenamed, 11),
            ("private/tmp/example/later", kFSEventStreamEventFlagItemCreated, 21),
            ("private/tmp/example", kFSEventStreamEventFlagRootChanged, 0),
            ("private/tmp", kFSEventStreamEventFlagUserDropped, 12),
            ("private/tmp/example-other/file", kFSEventStreamEventFlagItemModified, 13),
            ("", kFSEventStreamEventFlagHistoryDone, 20),
        ], on: collector)
        let history = try await collector.value(timeout: 0)

        #expect(history.events == [
            FileSystemEventRecord(path: "/tmp/example/removed", eventID: 11, flags: .itemRenamed),
            FileSystemEventRecord(path: "/tmp/example", eventID: 0, flags: .rootChanged),
            FileSystemEventRecord(path: "/System/Volumes/Data/private/tmp", eventID: 12, flags: .userDropped),
            FileSystemEventRecord(path: "/System/Volumes/Data/private/tmp/example-other/file", eventID: 13, flags: .itemModified),
        ])
        let target = ScanTarget(url: URL(filePath: "/tmp/example", directoryHint: .isDirectory))
        let tree = FileTreeStore(root: FileNodeRecord(
            id: target.id,
            url: target.url,
            name: "example",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        ))
        for (event, reason) in zip(history.events.suffix(3), [
            IncrementalRescanFallbackReason.watchedRootChanged, .userDroppedEvents, .eventOutsideTarget,
        ]) {
            let isolatedHistory = FileSystemEventHistory(since: history.since, through: history.through, events: [event])
            let plan = IncrementalRescanPlanner().plan(history: isolatedHistory, target: target, treeStore: tree)
            #expect(plan == .fullScan(reason: reason))
        }
    }

    @Test
    func testHistoryCollectorTimesOutWithoutReturningPartialEventsOrReviving() async throws {
        let collector = makeHistoryCollector()
        try receiveHistoryEvents([
            ("private/tmp/example/created.dat", kFSEventStreamEventFlagItemCreated, 11),
        ], on: collector)
        await #expect(throws: FSEventHistoryCollector.TimeoutError.self) {
            try await collector.value(timeout: 0.01)
        }
        try receiveHistoryEvents([
            ("", kFSEventStreamEventFlagHistoryDone, 20),
        ], on: collector)
        collector.cancel()

        await #expect(throws: FSEventHistoryCollector.TimeoutError.self) {
            try await collector.value(timeout: 0)
        }
    }

    @Test
    func testHistoryCollectorPreservesCancellationBeforeZeroDeadline() async {
        let collector = makeHistoryCollector()
        collector.cancel()

        await #expect(throws: CancellationError.self) {
            try await collector.value(timeout: 0)
        }
    }

    @Test
    func testHistoryCollectorCancellationRemainsDistinctFromLongDeadline() async {
        let collector = makeHistoryCollector()
        let cancellation = Task {
            await Task.yield()
            collector.cancel()
        }
        defer { cancellation.cancel() }

        await #expect(throws: CancellationError.self) {
            try await collector.value(timeout: 60)
        }
    }

    @Test(arguments: ["/tmp", "/private/tmp", "/System/Volumes/Data/private/tmp", "symlink"])
    func testDarwinHistoryProviderPreservesRenameEndpointsInTemporaryAlias(parentPath: String) async throws {
        let fixture = URL(filePath: "/tmp/radix-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let rootURL: URL
        if parentPath == "symlink" {
            let physical = fixture.appending(path: "physical", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
            rootURL = fixture.appending(path: "alias", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: rootURL, withDestinationURL: physical)
        } else {
            rootURL = URL(filePath: parentPath, directoryHint: .isDirectory).appending(path: fixture.lastPathComponent)
        }
        let source = rootURL.appending(path: "before.dat")
        let destination = rootURL.appending(path: "after.dat")
        try Data([1]).write(to: source)
        let provider = DarwinFileSystemEventHistoryProvider()
        try await Task.sleep(for: .seconds(1))
        let since = try provider.currentCheckpoint(for: rootURL)
        try FileManager.default.moveItem(at: source, to: destination)
        let history = try await incrementalHistoryContaining(
            [source.path, destination.path],
            provider: provider,
            rootURL: rootURL,
            since: since
        )

        #expect(history.events.contains { $0.path == source.path && $0.flags.contains(.itemRenamed) })
        #expect(history.events.contains { $0.path == destination.path && $0.flags.contains(.itemRenamed) })
    }

    @Test
    func testTemporaryAliasRescanReflectsFileGrowth() async throws {
        let rootURL = URL(filePath: "/tmp/radix-rescan-\(UUID().uuidString)", directoryHint: .isDirectory)
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let unchangedURL = rootURL.appending(path: "Untouched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unchangedURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let payloadURL = changedURL.appending(path: "payload.bin")
        try Data(repeating: 1, count: 8_192).write(to: payloadURL)
        try Data(repeating: 2, count: 4_096).write(to: unchangedURL.appending(path: "kept.bin"))
        try await Task.sleep(for: .seconds(1))
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let provider = DarwinFileSystemEventHistoryProvider()
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let baseline = try await finishedIncrementalSnapshot(from: service.scan(target: target, options: options))
        #expect(baseline.aggregateStats.totalLogicalSize == 12_288)
        let since = try #require(baseline.incrementalCheckpoint)
        try Data(repeating: 3, count: 16_384).write(to: payloadURL)
        _ = try await incrementalHistoryContaining(
            [payloadURL.path],
            provider: provider,
            rootURL: target.url,
            since: since
        )
        let result = try await incrementalScanResult(from: service.rescan(target: target, options: options, from: baseline))
        let fresh = try await finishedIncrementalSnapshot(from: ScanEngine().scan(target: target, options: options))

        #expect(!result.executionModes.contains(.incrementalNoChanges))
        #expect(result.snapshot.aggregateStats.totalLogicalSize == 20_480)
        #expect(result.snapshot.treeStore.node(id: payloadURL.path)?.logicalSize == 16_384)
        try assertEquivalent(result.snapshot, fresh)
    }

    @Test(arguments: [(relists: 1, expectedMaximum: 8), (relists: 4, expectedMaximum: 4), (relists: 32, expectedMaximum: 1)])
    func testShallowRelistClassificationBudgetAccountsForConcurrentRelists(budget: (relists: Int, expectedMaximum: Int)) {
        var options = ScanOptions()
        options.directoryTraversalWorkerLimit = 4
        options.directoryClassificationWorkerLimit = 8

        let limit = ScanEngine.shallowRelistClassificationWorkerLimit(
            for: options,
            relistWorkerLimit: budget.relists
        )

        #expect(limit >= 1)
        #expect(limit <= budget.expectedMaximum)
        if budget.relists == 1 {
            #expect(limit == 8)
        }
    }

    @Test
    func testIncompleteRootRelistPreservesExplicitFolderBehavior() async throws {
        let target = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .folder)
        let systemURL = URL(filePath: "/System", directoryHint: .isDirectory)
        let volumesURL = URL(filePath: "/System/Volumes", directoryHint: .isDirectory)
        let missingURL = URL(filePath: "/radix-missing-\(UUID().uuidString)")
        let visits = IncrementalDirectoryVisits()
        let engine = ScanEngine(directoryContents: { url, _, _, cancellationCheck in
            try cancellationCheck()
            let visit = visits.record(url)
            switch url.path {
            case "/":
                return visit == 2 ? [systemURL, missingURL] : [systemURL]
            case "/System":
                return [volumesURL]
            default:
                return []
            }
        })
        let service = IncrementalScanService(
            engine: engine,
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
                events: []
            )
        )
        let options = ScanOptions(includeHiddenFiles: true, autoSummarizeDirectories: false)
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        #expect(baseline.treeStore.node(id: volumesURL.path) != nil)
        #expect(baseline.volumeCapacity == nil)

        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: [target.url.path]
            )
        )

        #expect(result.executionModes == [.incremental])
        #expect(visits.count(for: target.url) == 3)
        #expect(result.snapshot.target == target)
        #expect(result.snapshot.volumeCapacity == nil)
        #expect(result.snapshot.treeStore.node(id: volumesURL.path) != nil)
        #expect(result.snapshot.treeStore.indexedNodeIDs() == ["/", "/System", "/System/Volumes"])
        #expect(result.snapshot.root.allocatedSize == 0)
    }

    @Test(arguments: [false, true])
    func testStartupVolumeRescanBypassesIncrementalRecovery(forcedRelist: Bool) async throws {
        let target = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory))
        let systemURL = URL(filePath: "/System", directoryHint: .isDirectory)
        let volumesURL = URL(filePath: "/System/Volumes", directoryHint: .isDirectory)
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: []
        )
        let service = IncrementalScanService(
            engine: ScanEngine(directoryContents: { url, _, _, cancellationCheck in
                try cancellationCheck()
                switch url.path {
                case "/": return [systemURL]
                case "/System": return [volumesURL]
                default: return []
                }
            }),
            eventHistoryProvider: provider
        )
        let options = ScanOptions(includeHiddenFiles: true, autoSummarizeDirectories: false)
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: forcedRelist ? [systemURL.path] : []
            )
        )

        #expect(target.kind == .volume)
        #expect(result.executionModes == [.fullFallback(.volumeTarget)])
        #expect(provider.historyRequestCount == 0)
        #expect(result.snapshot.treeStore.node(id: systemURL.path) != nil)
        #expect(result.snapshot.treeStore.node(id: volumesURL.path) == nil)
        #expect(result.snapshot.aggregateStats.fileCount == 0)
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

    private enum IneligibleBaseline: CaseIterable {
        case incomplete
        case imported
        case changedPath
        case changedKind
        case replacedRoot

        var reason: IncrementalRescanFallbackReason {
            switch self {
            case .incomplete: .incompleteBaseline
            case .imported: .readOnlyBaseline
            case .changedPath, .changedKind: .changedTarget
            case .replacedRoot: .targetIdentityChanged
            }
        }
    }

    @Test(arguments: IneligibleBaseline.allCases)
    private func testIneligibleBaselineStartsFreshScanWithoutReadingHistory(scenario: IneligibleBaseline) async throws {
        let fixtureURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let rootURL = fixtureURL.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        try Data([1]).write(to: rootURL.appending(path: "stable.dat"))
        let provider = IncrementalHistoryStub(checkpoints: [checkpoint(10), checkpoint(20)], events: [])
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let options = ScanOptions()
        var target = ScanTarget(url: rootURL)
        let original = try await finishedIncrementalSnapshot(from: service.scan(target: target, options: options))
        var baselineTarget = target
        var expectedLogicalSize: Int64 = 1

        switch scenario {
        case .incomplete, .imported:
            break
        case .changedPath:
            let otherURL = fixtureURL.appending(path: "other", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: false)
            try Data([2, 3]).write(to: otherURL.appending(path: "fresh.dat"))
            target = ScanTarget(url: otherURL)
            expectedLogicalSize = 2
        case .changedKind:
            baselineTarget = ScanTarget(url: rootURL, kind: .volume)
        case .replacedRoot:
            try FileManager.default.moveItem(at: rootURL, to: fixtureURL.appending(path: "original"))
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
            try Data([2, 3]).write(to: rootURL.appending(path: "fresh.dat"))
            expectedLogicalSize = 2
        }

        let baseline = ScanSnapshot(
            target: baselineTarget,
            treeStore: original.treeStore,
            startedAt: original.startedAt,
            finishedAt: scenario == .incomplete ? nil : original.finishedAt,
            scanWarnings: original.scanWarnings,
            isComplete: scenario != .incomplete,
            scanOptions: original.scanOptions,
            source: scenario == .imported
                ? .imported(ImportedSnapshotContext(sourceURL: fixtureURL, pathMode: .absolute, liveActionCapability: .disabled))
                : .live,
            incrementalCheckpoint: original.incrementalCheckpoint
        )
        let result = try await incrementalScanResult(from: service.rescan(target: target, options: options, from: baseline))

        #expect(result.executionModes == [.fullFallback(scenario.reason)])
        #expect(provider.historyRequestCount == 0)
        #expect(result.snapshot.target == target)
        #expect(result.snapshot.aggregateStats.totalLogicalSize == expectedLogicalSize)
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
    }

    @Test
    func testUnavailableTargetReportsIdentityFallbackBeforeFullScanFails() async throws {
        let fixtureURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let rootURL = fixtureURL.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let provider = IncrementalHistoryStub(checkpoints: [checkpoint(10), checkpoint(20)], events: [])
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(from: service.scan(target: target, options: options))
        try FileManager.default.moveItem(at: rootURL, to: fixtureURL.appending(path: "original"))
        let missingTarget = ScanTarget(url: URL(filePath: rootURL.path, directoryHint: .isDirectory))
        var modes: [ScanExecutionMode] = []
        var failure: (any Error)?
        do {
            for try await event in service.rescan(target: missingTarget, options: options, from: baseline) {
                if case .executionMode(let mode) = event { modes.append(mode) }
            }
        } catch {
            failure = error
        }

        #expect(modes == [.fullFallback(.targetIdentityUnavailable)])
        #expect(provider.historyRequestCount == 0)
        #expect(failure != nil)
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

    @Test(arguments: [false, true])
    func testIncompleteChildMetadataRecoversLocally(localizedFailure: Bool) async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let otherChangedURL = rootURL.appending(path: "OtherChanged", directoryHint: .isDirectory)
        let untouchedURL = rootURL.appending(path: "Untouched", directoryHint: .isDirectory)
        for url in [changedURL, otherChangedURL, untouchedURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data([0x1]).write(to: url.appending(path: "payload.dat"))
        }
        let leafURL = changedURL.appending(path: "payload.dat")
        let otherLeafURL = otherChangedURL.appending(path: "payload.dat")
        let removedURL = changedURL.appending(path: "removed.dat")
        try Data([0x2]).write(to: removedURL)
        let target = ScanTarget(url: rootURL)
        let excludedURL = changedURL.appending(path: "excluded.dat")
        try Data([0x5]).write(to: excludedURL)
        let options = ScanOptions(exclusionPatterns: ["Changed/excluded.dat"])
        let baseline = try await finishedIncrementalSnapshot(
            from: IncrementalScanService(
                engine: ScanEngine(enumeratedDirectoryContents: ScanEngine.defaultDirectoryContents),
                eventHistoryProvider: IncrementalHistoryStub(checkpoints: [checkpoint(10)], events: [])
            ).scan(target: target, options: options)
        )
        try Data(repeating: 0x3, count: 8_192).write(to: leafURL)
        try Data(repeating: 0x4, count: 4_096).write(to: otherLeafURL)
        try FileManager.default.removeItem(at: removedURL)
        let visits = IncrementalDirectoryVisits()
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, checkCancellation in
            try checkCancellation()
            let visit = visits.record(url)
            if url == changedURL, visit == 1 {
                if localizedFailure {
                    return ScanEngine.DirectoryEnumerationResult(
                        urls: [leafURL],
                        localizedFailures: [
                            ScanEngine.DirectoryEnumerationFailure(
                                url: removedURL,
                                error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                                isDirectoryHint: false
                            )
                        ]
                    )
                }
                return ScanEngine.DirectoryEnumerationResult(urls: [leafURL, removedURL])
            }
            return try ScanEngine.defaultDirectoryContents(
                url: url,
                keys: keys,
                options: options,
                cancellationCheck: checkCancellation
            )
        })
        let service = IncrementalScanService(
            engine: engine,
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(20), checkpoint(30)],
                events: [leafURL, otherLeafURL].enumerated().map { index, url in
                    FileSystemEventRecord(
                        path: url.path,
                        eventID: UInt64(15 + index),
                        flags: [.itemModified, .itemIsFile]
                    )
                }
            )
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine(enumeratedDirectoryContents: ScanEngine.defaultDirectoryContents)
                .scan(target: target, options: options)
        )

        #expect(result.executionModes == [.incremental])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
        #expect(result.snapshot.treeStore.node(id: leafURL.path)?.logicalSize == 8_192)
        #expect(result.snapshot.treeStore.node(id: otherLeafURL.path)?.logicalSize == 4_096)
        #expect(result.snapshot.treeStore.node(id: removedURL.path) == nil)
        #expect(result.snapshot.treeStore.node(id: excludedURL.path) == nil)
        #expect(visits.count(for: changedURL) == 2)
        #expect(visits.count(for: untouchedURL) == 0)
        #expect(visits.count(for: rootURL) == 0)
        try assertEquivalent(result.snapshot, full)
    }

    @Test
    func testIncompleteBulkListingRecoversLocallyWithPartialCoverage() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let untouchedURL = rootURL.appending(path: "Untouched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: untouchedURL, withIntermediateDirectories: false)
        let leafURLs = (0..<3).map { changedURL.appending(path: "payload-\($0).dat") }
        for url in leafURLs {
            try Data([0x1]).write(to: url)
        }
        let untouchedLeafURL = untouchedURL.appending(path: "payload.dat")
        try Data([0x2]).write(to: untouchedLeafURL)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: IncrementalScanService(
                eventHistoryProvider: IncrementalHistoryStub(checkpoints: [checkpoint(10)], events: [])
            ).scan(target: target, options: options)
        )
        try Data(repeating: 0x3, count: 8_192).write(to: leafURLs[0])
        try Data(repeating: 0x4, count: 4_096).write(to: untouchedLeafURL)
        let service = IncrementalScanService(
            engine: ScanEngine(forcedBulkFailure: .init(batchCount: 1, errorCode: EIO)),
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(20), checkpoint(30)],
                events: [
                    FileSystemEventRecord(
                        path: leafURLs[0].path,
                        eventID: 15,
                        flags: [.itemModified, .itemIsFile]
                    )
                ]
            )
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )
        let changed = try #require(result.snapshot.treeStore.node(id: changedURL.path))

        #expect(result.executionModes == [.incremental])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
        #expect(changed.descendantFileCount == 3)
        #expect(!changed.isSelfAccessible)
        #expect(result.snapshot.treeStore.node(id: leafURLs[0].path)?.logicalSize == 8_192)
        for url in leafURLs {
            #expect(result.snapshot.treeStore.node(id: url.path) != nil)
        }
        #expect(Set(result.snapshot.scanWarnings.map(\.path)) == [changedURL.path])
        #expect(
            result.snapshot.treeStore.node(id: untouchedLeafURL.path)
                == baseline.treeStore.node(id: untouchedLeafURL.path)
        )
    }

    @Test(arguments: [1, 2])
    func testCancellationDuringIncompleteRelistDoesNotFallBack(cancelOnVisit: Int) async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: false)
        let leafURL = changedURL.appending(path: "payload.dat")
        try Data([0x1]).write(to: leafURL)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: IncrementalScanService(
                eventHistoryProvider: IncrementalHistoryStub(checkpoints: [checkpoint(10)], events: [])
            ).scan(target: target, options: options)
        )
        let visits = IncrementalDirectoryVisits()
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, checkCancellation in
            try checkCancellation()
            if url == changedURL {
                let visit = visits.record(url)
                if visit == cancelOnVisit { throw CancellationError() }
                if visit == 1 {
                    return ScanEngine.DirectoryEnumerationResult(
                        urls: [],
                        localizedFailures: [
                            ScanEngine.DirectoryEnumerationFailure(
                                url: leafURL,
                                error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                                isDirectoryHint: false
                            )
                        ]
                    )
                }
            }
            return try ScanEngine.defaultDirectoryContents(
                url: url,
                keys: keys,
                options: options,
                cancellationCheck: checkCancellation
            )
        })
        let service = IncrementalScanService(
            engine: engine,
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(20), checkpoint(30)],
                events: [
                    FileSystemEventRecord(
                        path: leafURL.path,
                        eventID: 15,
                        flags: [.itemModified, .itemIsFile]
                    )
                ]
            )
        )
        var executionModes: [ScanExecutionMode] = []
        var finishedCount = 0

        for try await event in service.rescan(target: target, options: options, from: baseline) {
            if case .executionMode(let mode) = event { executionModes.append(mode) }
            if case .finished = event { finishedCount += 1 }
        }

        #expect(executionModes == [.incremental])
        #expect(finishedCount == 0)
        #expect(visits.count(for: changedURL) == cancelOnVisit)
    }

    @Test
    func testIncompleteRelistRejectsChangedRecoveryRoot() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let changedURL = rootURL.appending(path: "Changed", directoryHint: .isDirectory)
        let retiredURL = rootURL.appending(path: "Retired", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: false)
        let oldLeafURL = changedURL.appending(path: "old.dat")
        let newLeafURL = changedURL.appending(path: "new.dat")
        try Data([0x1]).write(to: oldLeafURL)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: IncrementalScanService(
                eventHistoryProvider: IncrementalHistoryStub(checkpoints: [checkpoint(10)], events: [])
            ).scan(target: target, options: options)
        )
        let visits = IncrementalDirectoryVisits()
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, checkCancellation in
            try checkCancellation()
            if url == changedURL, visits.record(url) == 1 {
                try FileManager.default.moveItem(at: changedURL, to: retiredURL)
                try FileManager.default.createDirectory(at: changedURL, withIntermediateDirectories: false)
                try Data([0x2]).write(to: newLeafURL)
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [],
                    localizedFailures: [
                        ScanEngine.DirectoryEnumerationFailure(
                            url: oldLeafURL,
                            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                            isDirectoryHint: false
                        )
                    ]
                )
            }
            return try ScanEngine.defaultDirectoryContents(
                url: url,
                keys: keys,
                options: options,
                cancellationCheck: checkCancellation
            )
        })
        let service = IncrementalScanService(
            engine: engine,
            eventHistoryProvider: IncrementalHistoryStub(
                checkpoints: [checkpoint(20), checkpoint(30)],
                events: [
                    FileSystemEventRecord(
                        path: oldLeafURL.path,
                        eventID: 15,
                        flags: [.itemModified, .itemIsFile]
                    )
                ]
            )
        )

        let result = try await incrementalScanResult(
            from: service.rescan(target: target, options: options, from: baseline)
        )

        #expect(result.executionModes == [.incremental, .fullFallback(.directoryRelistFailed)])
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 30)
        #expect(result.snapshot.treeStore.node(id: oldLeafURL.path) == nil)
        #expect(result.snapshot.treeStore.node(id: newLeafURL.path)?.logicalSize == 1)
        #expect(
            result.snapshot.treeStore.node(id: changedURL.path)?.fileIdentity
                != baseline.treeStore.node(id: changedURL.path)?.fileIdentity
        )
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
    func testForcedSourceParentRelistCapturesMoveBeforeEventsArrive() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let sourceParent = rootURL.appending(path: "Source", directoryHint: .isDirectory)
        let stableParent = rootURL.appending(path: "Stable", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: stableParent, withIntermediateDirectories: false)
        let sourceURL = sourceParent.appending(path: "moved.dat")
        try Data(repeating: 0x5A, count: 16_384).write(to: sourceURL)
        try Data([0x1]).write(to: stableParent.appending(path: "stable.dat"))
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )
        let stableBefore = baseline.treeStore.node(id: stableParent.path)

        try FileManager.default.moveItem(
            at: sourceURL,
            to: destinationURL.appending(path: sourceURL.lastPathComponent)
        )
        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: [sourceParent.path]
            )
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        #expect(result.executionModes == [.incremental])
        #expect(result.snapshot.treeStore.node(id: sourceURL.path) == nil)
        #expect(result.snapshot.root.descendantFileCount == 1)
        #expect(result.snapshot.treeStore.node(id: stableParent.path) == stableBefore)
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 20)
        #expect(provider.historyRequestCount == 1)
        try assertEquivalent(result.snapshot, full)
    }

    @Test
    func testForcedRelistFallsBackWhenSourceParentIdentityChanges() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let sourceParent = rootURL.appending(path: "Source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        try Data([0x1]).write(to: sourceParent.appending(path: "old.dat"))
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try FileManager.default.moveItem(at: sourceParent, to: destinationURL.appending(path: "Source"))
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        let replacementURL = sourceParent.appending(path: "new.dat")
        try Data([0x2]).write(to: replacementURL)
        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: [sourceParent.path]
            )
        )

        #expect(result.executionModes == [.incremental, .fullFallback(.directoryRelistFailed)])
        #expect(result.snapshot.treeStore.node(id: sourceParent.appending(path: "old.dat").path) == nil)
        #expect(result.snapshot.treeStore.node(id: replacementURL.path) != nil)
        #expect(result.snapshot.incrementalCheckpoint?.eventID == 30)
    }

    @Test
    func testForcedRelistFallsBackForExistingSharedAllocationWithoutEvents() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let sourceParent = rootURL.appending(path: "Source", directoryHint: .isDirectory)
        let otherParent = rootURL.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: otherParent, withIntermediateDirectories: false)
        let sourceURL = sourceParent.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 16_384).write(to: sourceURL)
        try FileManager.default.linkItem(at: sourceURL, to: otherParent.appending(path: "shared.dat"))
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL.appending(path: "shared.dat"))
        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: [sourceParent.path]
            )
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        #expect(result.executionModes == [.fullFallback(.sharedAllocationTopologyChanged)])
        try assertEquivalent(result.snapshot, full)
    }

    @Test
    func testForcedRelistFallsBackForNewSharedAllocationWithoutEvents() async throws {
        let rootURL = try makeIncrementalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceParent = rootURL.appending(path: "Source", directoryHint: .isDirectory)
        let otherParent = rootURL.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: otherParent, withIntermediateDirectories: false)
        let ownerURL = otherParent.appending(path: "shared.dat")
        try Data(repeating: 0x5A, count: 16_384).write(to: ownerURL)
        let provider = IncrementalHistoryStub(
            checkpoints: [checkpoint(10), checkpoint(20), checkpoint(30)],
            events: []
        )
        let service = IncrementalScanService(eventHistoryProvider: provider)
        let target = ScanTarget(url: rootURL)
        let options = ScanOptions()
        let baseline = try await finishedIncrementalSnapshot(
            from: service.scan(target: target, options: options)
        )

        try FileManager.default.linkItem(at: ownerURL, to: sourceParent.appending(path: "shared.dat"))
        let result = try await incrementalScanResult(
            from: service.rescan(
                target: target,
                options: options,
                from: baseline,
                relistingDirectoryPaths: [sourceParent.path]
            )
        )
        let full = try await finishedIncrementalSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        )

        #expect(result.executionModes == [.incremental, .fullFallback(.sharedAllocationTopologyChanged)])
        try assertEquivalent(result.snapshot, full)
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

    private func makeHistoryCollector() -> FSEventHistoryCollector {
        FSEventHistoryCollector(
            since: checkpoint(10),
            through: checkpoint(20),
            volume: DarwinFileSystemEventHistoryProvider.VolumeContext(
                deviceID: 1,
                uuid: "test-volume",
                rootPath: "/System/Volumes/Data",
                relativeTargetPath: "private/tmp/example",
                scanTargetPath: "/tmp/example"
            )
        )
    }

    private func receiveHistoryEvents(
        _ rawEvents: [(String, Int, UInt64)],
        on collector: FSEventHistoryCollector
    ) throws {
        let ownedPaths = try rawEvents.map { try #require(strdup($0.0)) }
        defer { ownedPaths.forEach { free($0) } }
        let paths = ownedPaths.map { UnsafePointer($0) }
        let flags = rawEvents.map { UInt32($0.1) }
        let ids = rawEvents.map(\.2)
        paths.withUnsafeBufferPointer { paths in
            flags.withUnsafeBufferPointer { flags in
                ids.withUnsafeBufferPointer { ids in
                    collector.receive(
                        eventCount: rawEvents.count,
                        relativePaths: paths.baseAddress!,
                        rawFlags: flags.baseAddress!,
                        eventIDs: ids.baseAddress!
                    )
                }
            }
        }
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

private final class IncrementalDirectoryVisits: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ url: URL) -> Int {
        lock.withLock {
            counts[url.path, default: 0] += 1
            return counts[url.path, default: 0]
        }
    }

    func count(for url: URL) -> Int {
        lock.withLock { counts[url.path, default: 0] }
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

private func incrementalHistoryContaining(
    _ paths: Set<String>,
    provider: DarwinFileSystemEventHistoryProvider,
    rootURL: URL,
    since: ScanIncrementalCheckpoint
) async throws -> FileSystemEventHistory {
    try await withThrowingTaskGroup(of: FileSystemEventHistory.self) { group in
        group.addTask {
            while true {
                try Task.checkCancellation()
                let through = try provider.currentCheckpoint(for: rootURL)
                if through.eventID > since.eventID {
                    let history = try await provider.history(for: rootURL, since: since, through: through)
                    if paths.isSubset(of: Set(history.events.map(\.path))) {
                        return history
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            throw IncrementalHistoryTimeout()
        }
        defer { group.cancelAll() }
        guard let history = try await group.next() else { throw CancellationError() }
        return history
    }
}

private struct IncrementalHistoryTimeout: Error {}
