import CoreServices
import Foundation
import Testing

@testable import RadixCore

struct FileSystemChangeWatcherTests {
    @Test
    func startupDiskWatchesAndNormalizesFirmlinkedDataPaths() {
        #expect(DarwinFileSystemChangeWatcher.pathsToWatch(for: URL(filePath: "/")) == ["/", "/System/Volumes/Data"])
        let buffer = FSEventChangeBuffer(targetURL: URL(filePath: "/"), sinceEventID: 10)
        let event = buffer.record(
            path: "/System/Volumes/Data/Users/test/Downloads/new.zip",
            rawFlags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
            eventID: 11
        )

        #expect(event?.path == "/Users/test/Downloads/new.zip")
        #expect(event?.flags == [.itemCreated, .itemIsFile])
        #expect(DarwinFileSystemChangeWatcher.pathsToWatch(for: URL(filePath: "/Users/test/Downloads")) == ["/Users/test/Downloads"])
        let folderBuffer = FSEventChangeBuffer(targetURL: URL(filePath: "/Users/test/Downloads"), sinceEventID: 10)
        #expect(folderBuffer.record(
            path: "/System/Volumes/Data/Users/test/Downloads/new.zip",
            rawFlags: UInt32(kFSEventStreamEventFlagItemCreated),
            eventID: 11
        )?.path == "/Users/test/Downloads/new.zip")
    }

    @Test
    func preservesPrivateNamespaceForExistingFileEvents() throws {
        let root = URL(filePath: "/private/tmp/radix-watcher-private-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "new.dat")
        // Use an existing file so Foundation's alias rewrite would be exercised.
        try Data([1]).write(to: file)
        let flags = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)

        for targetPath in ["/private", "/"] {
            let buffer = FSEventChangeBuffer(targetURL: URL(filePath: targetPath), sinceEventID: 10)
            #expect(buffer.record(path: file.path, rawFlags: flags, eventID: 11)?.path == file.path)
        }
    }

    @Test
    func resolvedSymlinkRootEventsRemainInTheWatchedNamespace() throws {
        let root = try makeWatcherTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "directory", directoryHint: .isDirectory)
        let alias = root.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let buffer = FSEventChangeBuffer(targetURL: alias, sinceEventID: 10)
        let event = buffer.record(
            path: directory.resolvingSymlinksInPath().appending(path: "new.dat").path,
            rawFlags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
            eventID: 11
        )

        #expect(event?.path == alias.appending(path: "new.dat").path)
    }

    @Test
    func historyBoundaryAndSentinelDoNotSuppressSubsequentLiveEvents() {
        let buffer = FSEventChangeBuffer(targetURL: URL(filePath: "/Users/test/Downloads"), sinceEventID: 10)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)

        #expect(buffer.record(path: "/Users/test/Downloads/file", rawFlags: modified, eventID: 10) == nil)
        #expect(buffer.record(path: "/Users/test/Downloads", rawFlags: UInt32(kFSEventStreamEventFlagHistoryDone), eventID: 11) == nil)
        #expect(buffer.record(path: "/Users/test/Downloads/file", rawFlags: modified, eventID: 12)?.eventID == 12)
        #expect(buffer.record(path: "/Users/test/Downloads-other/file", rawFlags: modified, eventID: 13) == nil)
    }

    @Test
    func zeroIDRootChangeAndBroaderDroppedEventsRemainVisible() {
        let buffer = FSEventChangeBuffer(targetURL: URL(filePath: "/Users/test/Downloads"), sinceEventID: 10)
        let rootChanged = buffer.record(
            path: "/Users/test/Downloads",
            rawFlags: UInt32(kFSEventStreamEventFlagRootChanged),
            eventID: 0
        )
        let dropped = buffer.record(
            path: "/",
            rawFlags: UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs),
            eventID: 11
        )

        #expect(rootChanged?.flags == .rootChanged)
        #expect(rootChanged?.eventID == 0)
        #expect(dropped?.path == "/Users/test/Downloads")
        #expect(dropped?.flags == [.kernelDropped, .mustScanSubdirectories])
    }

    @Test
    func mailboxOverflowPreservesUncertaintyAndResumesNormalDelivery() async {
        let buffer = FSEventChangeBuffer(targetURL: URL(filePath: "/scan"), sinceEventID: 10, eventLimit: 2)
        buffer.receive([
            FileSystemEventRecord(path: "/scan/a", eventID: 11, flags: .itemModified),
            FileSystemEventRecord(path: "/scan/b", eventID: 12, flags: .itemModified),
        ])
        buffer.receive([FileSystemEventRecord(path: "/scan/c", eventID: 13, flags: .itemModified)])
        buffer.receive([FileSystemEventRecord(path: "/scan/d", eventID: 14, flags: .itemModified)])

        let overflow = await buffer.next()
        #expect(overflow == [FileSystemEventRecord(path: "/scan", eventID: 14, flags: [.mustScanSubdirectories, .userDropped])])

        let subsequent = FileSystemEventRecord(path: "/scan/e", eventID: 15, flags: .itemModified)
        buffer.receive([subsequent])
        #expect(await buffer.next() == [subsequent])
        buffer.cancel()
        #expect(await buffer.next() == nil)
    }

    @Test
    func mailboxCancellationDiscardsPendingChanges() async {
        let buffer = FSEventChangeBuffer(targetURL: URL(filePath: "/scan"), sinceEventID: 10)
        buffer.receive([FileSystemEventRecord(path: "/scan/file", eventID: 11, flags: .itemModified)])
        buffer.cancel()
        #expect(await buffer.next() == nil)
    }

    @Test
    func invalidVolumeCheckpointFailsBeforeWatching() async throws {
        let root = try makeWatcherTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = ScanIncrementalCheckpoint(volumeUUID: "a-different-volume", eventID: 1)

        do {
            for try await _ in DarwinFileSystemChangeWatcher().changes(for: root, since: checkpoint) {}
            Issue.record("Watcher accepted a checkpoint from a different volume")
        } catch FileSystemEventHistoryError.volumeChanged {
            // The scan's journal identity must match before replay begins.
        }
    }

    @Test
    func watcherReplaysCheckpointAndKeepsDeliveringLiveEvents() async throws {
        let root = try makeWatcherTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try DarwinFileSystemEventHistoryProvider().currentCheckpoint(for: root)
        let historicalFile = root.appending(path: "before-watching.dat")
        let liveFile = root.appending(path: "while-watching.dat")
        try Data([1]).write(to: historicalFile)
        let stream = DarwinFileSystemChangeWatcher(latency: 0.01).changes(for: root, since: checkpoint)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var foundHistoricalFile = false
                for try await batch in stream {
                    if batch.contains(where: { $0.path == historicalFile.path && $0.flags.contains(.itemCreated) }) {
                        if !foundHistoricalFile {
                            foundHistoricalFile = true
                            try Data([2]).write(to: liveFile)
                        }
                    }
                    if foundHistoricalFile,
                       batch.contains(where: { $0.path == liveFile.path && $0.flags.contains(.itemCreated) }) {
                        return
                    }
                }
                throw WatcherTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw WatcherTestError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @Test
    @MainActor
    func cancellingActiveLiveIterationStopsWaiting() async throws {
        let root = try makeWatcherTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "before-cancellation.dat")
        let stream = DarwinFileSystemChangeWatcher(latency: 0.01).changes(for: root, since: nil)
        var receivedFile = false
        var finished = false
        let consumer = Task {
            defer { finished = true }
            do {
                for try await batch in stream {
                    if batch.contains(where: { $0.path == file.path && $0.flags.contains(.itemCreated) }) {
                        receivedFile = true
                    }
                }
            } catch is CancellationError {
                // Both normal end-of-stream and cancellation are valid endings.
            }
        }
        defer { consumer.cancel() }
        try Data([1]).write(to: file)
        try await waitUntil("live iteration received a file event") { receivedFile || finished }
        if finished {
            try await consumer.value
            throw WatcherTestError.streamEnded
        }
        consumer.cancel()
        try await waitUntil("cancelled live iteration completes") { finished }
        try await consumer.value
    }
}

private enum WatcherTestError: Error {
    case timedOut
    case streamEnded
}

private func makeWatcherTestDirectory() throws -> URL {
    let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let root = packageRoot.appending(path: ".build/radix-watcher-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
