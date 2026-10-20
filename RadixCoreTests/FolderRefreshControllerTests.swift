import Foundation
import Testing

@testable import RadixCore

@MainActor
struct FolderRefreshControllerTests {
    @Test
    func matcherPreparationKeepsMainActorResponsiveAndBuffersInitialEvents() async throws {
        let watcher = BufferedRefreshWatcher(initialEvents: [changedFile(downloads + "/new.zip")])
        let factory = RefreshMatcherFactory(blockFirstBuild: true)
        let clock = ManualTestClock()
        var requests: [String] = []
        let controller = FolderRefreshController(
            watcher: watcher,
            now: { clock.now },
            sleep: { try await clock.sleep(for: $0) },
            makeExclusionMatcher: { patterns, rootPath in
                factory.make(patterns: patterns, rootPath: rootPath, streamStarted: watcher.requestCount > 0)
            },
            directoryExists: { _ in true },
            requestRefresh: { requests.append($0); return true }
        )
        defer {
            factory.release()
            controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        }
        let snapshot = makeFolderRefreshSnapshot(checkpoint: nil)
        controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { factory.receipts.count == 1 }
        #expect(factory.isBlocked)
        #expect(!factory.timedOut)
        #expect(factory.receipts.first?.wasMainThread == false)
        #expect(factory.receipts.first?.streamStarted == true)
        #expect(watcher.startedOnMainThread == [false])
        #expect(watcher.checkpoints == [nil])
        var mainActorPulse = false
        Task { @MainActor in mainActorPulse = true }
        try await waitUntil { mainActorPulse }
        #expect(factory.isBlocked)
        controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        factory.release()
        try await waitUntil { clock.pendingSleeps == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { requests == [downloads] }
        #expect(factory.receipts.count == 1)
    }

    @Test
    func reusesSessionMatcherAcrossBatchesNavigationAndTreeReplacement() async throws {
        let factory = RefreshMatcherFactory()
        let harness = FolderRefreshHarness(makeExclusionMatcher: { patterns, rootPath in
            factory.make(patterns: patterns, rootPath: rootPath)
        })
        let options = ScanOptions(exclusionPatterns: ["build/", "*.log"], exclusionRootPath: home)
        let snapshot = makeFolderRefreshSnapshot(options: options)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([
            changedFile(downloads + "/BUILD/item"), changedFile(downloads + "/TRACE.LOG")
        ])
        #expect(harness.requests.isEmpty)
        #expect(harness.clock.pendingSleeps == 0)
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        harness.controller.update(
            snapshot: makeFolderRefreshSnapshot(id: snapshot.id, options: options, hasNewDownload: true),
            focusedNodeID: downloads, canRefresh: true
        )
        try await harness.watcher.emitAndWaitUntilProcessed([])
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/visible.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        #expect(harness.watcher.requests.count == 1)
        #expect(factory.receipts.count == 1)
        #expect(factory.receipts.first?.patterns == ["build/", "*.log"])
        #expect(factory.receipts.first?.rootPath == home)
        #expect(factory.receipts.first?.wasMainThread == false)
    }

    @Test(arguments: [false, true])
    func cancelledPreparationCannotDeliverIntoReplacementOrSameIdentitySession(sameIdentity: Bool) async throws {
        let watcher = BufferedRefreshWatcher(initialEvents: [changedFile(downloads + "/old.zip")])
        let factory = RefreshMatcherFactory(blockFirstBuild: true)
        let clock = ManualTestClock()
        var requests: [String] = []
        let controller = FolderRefreshController(
            watcher: watcher,
            now: { clock.now },
            sleep: { try await clock.sleep(for: $0) },
            makeExclusionMatcher: { patterns, rootPath in factory.make(patterns: patterns, rootPath: rootPath) },
            directoryExists: { _ in true },
            requestRefresh: { requests.append($0); return true }
        )
        defer {
            factory.release()
            controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        }
        let snapshot = makeFolderRefreshSnapshot()
        controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { factory.receipts.count == 1 }
        #expect(factory.isBlocked)
        controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        let replacement = sameIdentity ? snapshot : makeFolderRefreshSnapshot(
            options: ScanOptions(exclusionPatterns: ["*.log"])
        )
        controller.update(snapshot: replacement, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { factory.receipts.count == 2 && watcher.requestCount == 2 }
        factory.release()
        try await waitUntil { factory.finishedBuilds == 2 && watcher.cancelledSessions == [0] }
        watcher.emit([], to: 1)
        clock.advance(by: .seconds(10))
        #expect(requests.isEmpty)
        #expect(clock.pendingSleeps == 0)
        watcher.emit([changedFile(downloads + "/current.zip")], to: 1)
        try await waitUntil { clock.pendingSleeps == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { requests == [downloads] }
        #expect(factory.receipts.count == 2)
    }

    @Test
    func idleWatchSessionDoesNotRetainController() async throws {
        let watcher = BufferedRefreshWatcher(initialEvents: [])
        let factory = RefreshMatcherFactory()
        var controller: FolderRefreshController? = FolderRefreshController(
            watcher: watcher,
            makeExclusionMatcher: { patterns, rootPath in factory.make(patterns: patterns, rootPath: rootPath) },
            directoryExists: { _ in true },
            requestRefresh: { _ in Issue.record("An idle session must not request refresh."); return false }
        )
        weak var releasedController = controller
        controller?.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { factory.finishedBuilds == 1 }
        controller = nil
        try await waitUntil { releasedController == nil && watcher.cancelledSessions == [0] }
    }

    @Test
    func missingFocusedDirectoryRefreshesItsNearestExistingAncestor() async throws {
        let harness = FolderRefreshHarness(directoryExists: { $0 != self.downloads })
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([
            FileSystemEventRecord(path: downloads, eventID: 43, flags: [.itemRemoved, .itemIsDirectory])
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [home] }
        harness.controller.refreshFinished(nodeID: home, result: .updated)
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests == [home])
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func missingScanRootKeepsChangesPendingUntilItExists() async throws {
        let harness = FolderRefreshHarness(directoryExists: { _ in false })
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/pending.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(10))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests.isEmpty)
        harness.directoryExists = { _ in true }
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func laterContentsEventDoesNotDowngradePendingSubtreeChange() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([
            FileSystemEventRecord(path: home, eventID: 43, flags: [.mustScanSubdirectories]),
            changedFile(home + "/notes.txt"),
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, documents] }
    }

    @Test(arguments: [false, true])
    func fileChangesInParentOnlyRefreshTheParent(focusParent: Bool) async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(
            snapshot: makeFolderRefreshSnapshot(), focusedNodeID: focusParent ? home : downloads, canRefresh: true
        )
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(home + "/notes.txt")])
        try await harness.watcher.emitAndWaitUntilProcessed([])
        harness.clock.advance(by: .seconds(30))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests == (focusParent ? [home] : []))
    }

    @Test
    func continuousWritesRefreshWithinFiveSeconds() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        let firstEventAt = harness.clock.now
        for _ in 0..<30 {
            try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/growing.part")])
            // Let each timer register, then cross its deadline in 100 ms steps.
            try await harness.watcher.emitAndWaitUntilProcessed([])
            for _ in 0..<9 {
                harness.clock.advance(by: .milliseconds(100))
                try await harness.watcher.emitAndWaitUntilProcessed([])
            }
        }
        #expect(harness.requests.first == downloads)
        #expect(harness.requestTimes.first.map { firstEventAt.duration(to: $0) <= .seconds(5) } == true)
    }

    @Test
    func rejectedStartRetriesWhenScannerBecomesReadyWithoutAnotherEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.allowsRequests = false
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/pending.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }

        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        harness.allowsRequests = true
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
    }

    @Test(arguments: [false, true])
    func manualRefreshAcknowledgesOnlyChangesKnownAtStart(hasNewChange: Bool) async throws {
        let harness = FolderRefreshHarness()
        let baseline = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/before.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }

        harness.controller.refreshStarted(nodeID: downloads)
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: false)
        try await waitUntil("manual refresh cancels automatic timer") { harness.clock.pendingSleeps == 0 }
        if hasNewChange {
            try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/during.zip")])
        }
        let updated = makeFolderRefreshSnapshot(id: baseline.id, hasNewDownload: true)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        // Any erroneous follow-up timer must register before time advances.
        try await harness.watcher.emitAndWaitUntilProcessed([])
        if hasNewChange {
            try await waitUntil { harness.clock.pendingSleeps == 1 }
        } else {
            #expect(harness.clock.pendingSleeps == 0)
        }
        harness.clock.advance(by: .seconds(10))
        if hasNewChange {
            try await waitUntil { harness.requests == [downloads] }
        } else {
            try await harness.watcher.emitAndWaitUntilProcessed([])
            #expect(harness.clock.pendingSleeps == 0)
        }
        #expect(harness.requests == (hasNewChange ? [downloads] : []))
    }

    @Test
    func watchesWholeScanAndCatchesUpOnNavigationAfterAnInPlaceRefresh() async throws {
        let harness = FolderRefreshHarness()
        let baseline = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: baseline, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        #expect(harness.watcher.requests.first?.targetURL == baseline.target.url)
        #expect(harness.watcher.requests.first?.checkpoint == baseline.incrementalCheckpoint)

        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/new.zip"), changedFile(documents + "/report.pdf")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }

        // Publishing a new tree with the same scan identity must retain both
        // the watcher and the unrefreshed Documents changes.
        let updated = makeFolderRefreshSnapshot(id: baseline.id, hasNewDownload: true)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.watcher.requests.count == 1)
        #expect(harness.clock.pendingSleeps == 0)

        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: updated, focusedNodeID: documents, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, documents] }
        harness.controller.refreshFinished(nodeID: documents, result: .updated)
        harness.controller.update(snapshot: updated, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func batchesEventsDuringRefreshAndEnforcesMinimumInterval() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/archive.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests.count == 1 }

        try await harness.watcher.emitAndWaitUntilProcessed((0..<100).map { changedFile(downloads + "/\($0).dat") })
        // Changes received during the refresh can only schedule another
        // timer after the in-flight refresh is acknowledged.
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests == [downloads])
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(4_999))
        #expect(harness.clock.pendingSleeps == 1)
        #expect(harness.requests.count == 1)
        harness.clock.advance(by: .milliseconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func expensiveRefreshRestsForTwiceItsDurationBeforeFollowingUp() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.clock.advance(by: .seconds(20))
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/second.zip")])
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(39_999))
        #expect(harness.clock.pendingSleeps == 1)
        #expect(harness.requests == [downloads])
        harness.clock.advance(by: .milliseconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test
    func trailingDebounceIsUnaffectedByChangesOutsideFocus() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/a.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .milliseconds(500))
        #expect(harness.clock.pendingSleeps == 1)
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/b.zip")])
        try await waitUntil("relevant event replaces debounce timer") {
            harness.sleepRequests == 2 && harness.clock.pendingSleeps == 1
        }
        harness.clock.advance(by: .milliseconds(500))
        #expect(harness.clock.pendingSleeps == 1)
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(documents + "/report.pdf")])
        #expect(harness.requests.isEmpty)
        harness.clock.advance(by: .milliseconds(500))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func pausesForInteractionsAndResumesWithoutAnotherFilesystemEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/a.zip")])
        harness.clock.advance(by: .seconds(10))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func repeatedContextUpdatesKeepTimerAndCompletionCanPrecedeGateResume() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        for _ in 0..<100 {
            harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        }
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.sleepRequests == 1)
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/second.zip")])
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
        harness.clock.advance(by: .seconds(5))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests == [downloads])
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test
    func cancelledRefreshRetriesWhenTheWorkspaceReopensWithoutANewEvent() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/new.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: false)
        harness.controller.refreshFinished(nodeID: downloads, result: .cancelled)
        harness.clock.advance(by: .seconds(5))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests == [downloads])
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test(arguments: [false, true])
    func explicitStopSuppressesKnownWorkUntilANewEvent(nestedChange: Bool) async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot()
        let changedDirectory = downloads + (nestedChange ? "/nested" : "")
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(changedDirectory + "/first.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        // Include changes received while the refresh was running: Stop should
        // not immediately launch those already pending writes as another scan.
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(changedDirectory + "/second.zip")])
        harness.controller.pauseCurrentRefresh()
        harness.controller.refreshFinished(nodeID: downloads, result: .cancelled)
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests == [downloads])
        #expect(harness.clock.pendingSleeps == 0)
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(changedDirectory + "/third.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads, downloads] }
    }

    @Test(arguments: [false, true], [false, true])
    func failureWaitsForANewRelevantEventRatherThanRetryingOnNavigation(
        nestedChange: Bool,
        missingFocusedDirectory: Bool
    ) async throws {
        let harness = FolderRefreshHarness(directoryExists: { !missingFocusedDirectory || $0 != self.downloads })
        let refreshedNodeID = missingFocusedDirectory ? home : downloads
        let snapshot = makeFolderRefreshSnapshot()
        let changedDirectory = downloads + (nestedChange ? "/nested" : "")
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(changedDirectory + "/a.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [refreshedNodeID] }
        harness.controller.refreshFinished(nodeID: refreshedNodeID, result: .failed)
        try await harness.watcher.emitAndWaitUntilProcessed([])
        harness.clock.advance(by: .seconds(10))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        try #require(harness.requests == [refreshedNodeID])
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests.count == 1)
        #expect(harness.clock.pendingSleeps == 0)
        harness.directoryExists = { _ in true }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(changedDirectory + "/b.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [refreshedNodeID, downloads] }
    }

    @Test
    func respectsExclusionsHiddenFilesAndPathBoundaries() async throws {
        let harness = FolderRefreshHarness()
        let options = ScanOptions(exclusionPatterns: ["build/", "*.log"])
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(options: options), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([
            changedFile(downloads + "/.secret/item"),
            changedFile(downloads + "/build/item"),
            changedFile(downloads + "/trace.log"),
            changedFile(home + "-other/Downloads/file"),
            FileSystemEventRecord(path: downloads + "/read.txt", eventID: 43, flags: [.itemIsFile])
        ])
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests.isEmpty)
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/visible.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test(arguments: [FileSystemEventFlags.itemCreated, .itemRemoved])
    func directoryOnlyExclusionsKeepSymbolicLinkChanges(mutation: FileSystemEventFlags) async throws {
        let harness = FolderRefreshHarness()
        let options = ScanOptions(exclusionPatterns: ["build/"])
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(options: options), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([
            FileSystemEventRecord(path: downloads + "/build", eventID: 43, flags: mutation.union(.itemIsSymbolicLink))
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test
    func volumeOverviewIsManualButItsSubfoldersRefreshAutomatically() async throws {
        let harness = FolderRefreshHarness()
        let snapshot = makeFolderRefreshSnapshot(kind: .volume)
        harness.controller.update(snapshot: snapshot, focusedNodeID: home, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/new.zip")])
        harness.clock.advance(by: .seconds(10))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.clock.pendingSleeps == 0)
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.requests == [downloads] }
    }

    @Test(arguments: [false, true])
    func savedAndIncompleteScansNeverWatch(isImported: Bool) async throws {
        let factory = RefreshMatcherFactory()
        let harness = FolderRefreshHarness(makeExclusionMatcher: { patterns, rootPath in
            factory.make(patterns: patterns, rootPath: rootPath)
        })
        let snapshot = isImported
            ? makeFolderRefreshSnapshot(source: .imported(ImportedSnapshotContext(
                sourceURL: URL(filePath: "/saved.radixscan"), pathMode: .absolute, liveActionCapability: .pathValidation
            )))
            : makeFolderRefreshSnapshot(isComplete: false)
        harness.controller.update(snapshot: snapshot, focusedNodeID: home, canRefresh: true)
        // Give an incorrectly started observer an opportunity to subscribe;
        // each eligibility guard is exercised without replacing its context.
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.watcher.requests.isEmpty)
        #expect(factory.receipts.isEmpty)
        harness.controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        #expect(factory.receipts.isEmpty)
    }

    @Test
    func folderTargetRootCanRefresh() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: home, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(documents + "/new.pdf")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [home] }
    }

    @Test(arguments: [false, true])
    func overflowAndDroppedHistoryRemainDirtyForOtherFolders(isDroppedHistory: Bool) async throws {
        let harness = FolderRefreshHarness(maximumPendingPaths: 2)
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed(isDroppedHistory ? [
            FileSystemEventRecord(path: home, eventID: 44, flags: [.kernelDropped])
        ] : [
            changedFile(home + "/Other1/a"),
            changedFile(home + "/Other2/b"),
            changedFile(home + "/Other3/c")
        ])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.clock.advance(by: .seconds(1))
        try await waitUntil { harness.requests == [downloads] }
        harness.controller.refreshFinished(nodeID: downloads, result: .updated)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
        harness.clock.advance(by: .seconds(5))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        try await waitUntil { harness.requests == [downloads, documents] }
        harness.controller.refreshFinished(nodeID: documents, result: .updated)
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test
    func changingScansCancelsOldWatcherAndPendingRefresh() async throws {
        let harness = FolderRefreshHarness()
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        try await harness.watcher.emitAndWaitUntilProcessed([changedFile(downloads + "/old.zip")])
        try await waitUntil { harness.clock.pendingSleeps == 1 }
        harness.controller.update(snapshot: makeFolderRefreshSnapshot(), focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 2 && harness.watcher.cancellations == 1 }
        harness.clock.advance(by: .seconds(10))
        try await harness.watcher.emitAndWaitUntilProcessed([])
        #expect(harness.requests.isEmpty)
        harness.controller.update(snapshot: nil, focusedNodeID: nil, canRefresh: false)
        try await waitUntil { harness.watcher.cancellations == 2 }
    }

    @Test
    func watcherStartupFailureDoesNotManufactureARefresh() async throws {
        let harness = FolderRefreshHarness()
        harness.watcher.failAtStartup = true
        let snapshot = makeFolderRefreshSnapshot()
        harness.controller.update(snapshot: snapshot, focusedNodeID: downloads, canRefresh: true)
        try await waitUntil { harness.watcher.requests.count == 1 }
        harness.clock.advance(by: .seconds(10))
        harness.controller.update(snapshot: snapshot, focusedNodeID: documents, canRefresh: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.requests.isEmpty)
        #expect(harness.watcher.requests.count == 1)
    }

    private var home: String { "/refresh/home" }
    private var downloads: String { home + "/Downloads" }
    private var documents: String { home + "/Documents" }

    private func changedFile(_ path: String) -> FileSystemEventRecord {
        FileSystemEventRecord(path: path, eventID: 43, flags: [.itemModified, .itemIsFile])
    }

    private func makeFolderRefreshSnapshot(
        id: UUID = UUID(),
        kind: ScanTargetKind = .folder,
        isComplete: Bool = true,
        source: ScanSnapshotSource = .live,
        options: ScanOptions = ScanOptions(),
        hasNewDownload: Bool = false,
        checkpoint: ScanIncrementalCheckpoint? = ScanIncrementalCheckpoint(volumeUUID: "test-volume", eventID: 42)
    ) -> ScanSnapshot {
        let file = makeTestFileNode(id: downloads + "/new.zip", name: "new.zip", size: 100)
        let downloadChildren = hasNewDownload ? [file] : []
        let downloadNode = makeTestDirectoryNode(id: downloads, name: "Downloads", children: downloadChildren)
        let documentNode = makeTestDirectoryNode(id: documents, name: "Documents", children: [])
        let root = makeTestDirectoryNode(id: home, name: "home", children: [downloadNode, documentNode])
        return ScanSnapshot(
            id: id,
            target: ScanTarget(url: URL(filePath: home, directoryHint: .isDirectory), kind: kind),
            treeStore: FileTreeStore(root: root, childrenByID: [home: [downloadNode, documentNode], downloads: downloadChildren]),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            scanWarnings: [],
            isComplete: isComplete,
            scanOptions: options,
            source: source,
            incrementalCheckpoint: checkpoint
        )
    }
}

@MainActor
private final class FolderRefreshHarness {
    let watcher = TestFileSystemChangeWatcher()
    let clock = ManualTestClock()
    var requests: [String] = []
    var requestTimes: [ContinuousClock.Instant] = []
    var allowsRequests = true
    var sleepRequests = 0
    private let maximumPendingPaths: Int
    private let makeExclusionMatcher: @Sendable ([String], String) -> ScanExclusionMatcher
    var directoryExists: @MainActor (String) -> Bool
    lazy var controller = FolderRefreshController(
        watcher: watcher,
        maximumPendingPaths: maximumPendingPaths,
        now: { [clock] in clock.now },
        sleep: { [weak self, clock] in
            self?.sleepRequests += 1
            try await clock.sleep(for: $0)
        },
        makeExclusionMatcher: makeExclusionMatcher,
        directoryExists: { [weak self] in self?.directoryExists($0) == true },
        requestRefresh: { [weak self] nodeID in
            guard let self else { return false }
            requests.append(nodeID)
            requestTimes.append(clock.now)
            return allowsRequests
        }
    )

    init(
        maximumPendingPaths: Int = 4_096,
        makeExclusionMatcher: @escaping @Sendable ([String], String) -> ScanExclusionMatcher = {
            ScanExclusionMatcher(patterns: $0, rootPath: $1)
        },
        directoryExists: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.maximumPendingPaths = maximumPendingPaths
        self.makeExclusionMatcher = makeExclusionMatcher
        self.directoryExists = directoryExists
    }
}

nonisolated private final class RefreshMatcherFactory: @unchecked Sendable {
    struct Receipt: Sendable {
        let patterns: [String]
        let rootPath: String
        let wasMainThread: Bool
        let streamStarted: Bool
    }

    private let condition = NSCondition()
    private let blockFirstBuild: Bool
    private var storedReceipts: [Receipt] = []
    private var released = false
    private var blocked = false
    private var didTimeOut = false
    private var completed = 0

    init(blockFirstBuild: Bool = false) {
        self.blockFirstBuild = blockFirstBuild
    }

    var receipts: [Receipt] { condition.withLock { storedReceipts } }
    var isBlocked: Bool { condition.withLock { blocked } }
    var timedOut: Bool { condition.withLock { didTimeOut } }
    var finishedBuilds: Int { condition.withLock { completed } }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func make(patterns: [String], rootPath: String, streamStarted: Bool = true) -> ScanExclusionMatcher {
        condition.lock()
        storedReceipts.append(Receipt(
            patterns: patterns, rootPath: rootPath,
            wasMainThread: Thread.isMainThread, streamStarted: streamStarted
        ))
        if blockFirstBuild, storedReceipts.count == 1 {
            blocked = true
            let deadline = Date().addingTimeInterval(15)
            while !released {
                if !condition.wait(until: deadline) {
                    didTimeOut = true
                    break
                }
            }
            blocked = false
        }
        completed += 1
        condition.unlock()
        return ScanExclusionMatcher(
            patterns: patterns, rootPath: rootPath, volumeSupportsCaseSensitiveNames: false
        )
    }
}

nonisolated private final class BufferedRefreshWatcher: FileSystemChangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let initialEvents: [FileSystemEventRecord]
    private var continuations: [AsyncThrowingStream<[FileSystemEventRecord], Error>.Continuation] = []
    private var storedCheckpoints: [ScanIncrementalCheckpoint?] = []
    private var mainThreadReceipts: [Bool] = []
    private var cancelled: [Int] = []

    init(initialEvents: [FileSystemEventRecord]) {
        self.initialEvents = initialEvents
    }

    var requestCount: Int { lock.withLock { continuations.count } }
    var startedOnMainThread: [Bool] { lock.withLock { mainThreadReceipts } }
    var checkpoints: [ScanIncrementalCheckpoint?] { lock.withLock { storedCheckpoints } }
    var cancelledSessions: [Int] { lock.withLock { cancelled } }

    func changes(for targetURL: URL, since checkpoint: ScanIncrementalCheckpoint?)
        -> AsyncThrowingStream<[FileSystemEventRecord], Error> {
        let pair = AsyncThrowingStream<[FileSystemEventRecord], Error>.makeStream()
        let index = lock.withLock {
            let index = continuations.count
            continuations.append(pair.continuation)
            storedCheckpoints.append(checkpoint)
            mainThreadReceipts.append(Thread.isMainThread)
            return index
        }
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            self.lock.withLock { self.cancelled.append(index) }
        }
        if index == 0 { pair.continuation.yield(initialEvents) }
        return pair.stream
    }

    func emit(_ events: [FileSystemEventRecord], to index: Int) {
        let continuation = lock.withLock { continuations[index] }
        continuation.yield(events)
    }
}
