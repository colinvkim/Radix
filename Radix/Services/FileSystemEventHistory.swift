import CoreServices
import Darwin
import Dispatch
import Foundation

nonisolated protocol FileSystemEventHistoryProviding: Sendable {
    /// Captures a boundary before scanning begins. A snapshot built after this
    /// call can safely replay changes after the returned event ID.
    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint

    /// Returns events in `(since.eventID, through.eventID]`. Events newer than
    /// `through` are deliberately left for the next incremental rescan.
    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory
}

nonisolated struct DarwinFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    private let latency: CFTimeInterval

    init(latency: CFTimeInterval = 0.05) {
        self.latency = max(latency, 0)
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        let volume = try Self.volumeContext(for: targetURL)
        let eventID = FSEventsGetCurrentEventId()
        guard eventID > 0 else {
            throw FileSystemEventHistoryError.eventIDUnavailable(targetURL.path)
        }
        return ScanIncrementalCheckpoint(
            volumeUUID: volume.uuid,
            eventID: eventID
        )
    }

    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory {
        try Task.checkCancellation()
        let volume = try Self.volumeContext(for: targetURL)
        guard since.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame,
              through.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame else {
            throw FileSystemEventHistoryError.volumeChanged
        }
        guard through.eventID >= since.eventID else {
            throw FileSystemEventHistoryError.eventIDRolledBack
        }
        guard since.eventID > 0 else {
            throw FileSystemEventHistoryError.invalidCheckpointRange
        }
        guard through.eventID > since.eventID else {
            return FileSystemEventHistory(since: since, through: through, events: [])
        }

        let collector = FSEventHistoryCollector(
            since: since,
            through: through,
            volumeRootURL: volume.rootURL
        )
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [volume.relativeTargetPath] as CFArray
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagFullHistory
        )
        guard let stream = FSEventStreamCreateRelativeToDevice(
            nil,
            radixFSEventHistoryCallback,
            &context,
            volume.deviceID,
            paths,
            since.eventID,
            latency,
            createFlags
        ) else {
            throw FileSystemEventHistoryError.streamCreationFailed
        }

        let queue = DispatchQueue(label: "dev.colinkim.radix.fsevents.history")
        let lifetime = FSEventStreamLifetime(stream: stream, queue: queue)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            lifetime.stop()
            throw FileSystemEventHistoryError.streamStartFailed
        }

        return try await withTaskCancellationHandler {
            defer { lifetime.stop() }
            return try await collector.value()
        } onCancel: {
            collector.cancel()
            lifetime.stop()
        }
    }

    private struct VolumeContext {
        let deviceID: dev_t
        let uuid: String
        let rootURL: URL
        let relativeTargetPath: String
    }

    private static func volumeContext(for targetURL: URL) throws -> VolumeContext {
        let targetURL = targetURL.standardizedFileURL
        var targetStat = stat()
        let statResult = targetURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &targetStat)
        }
        guard statResult == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable(targetURL.path)
        }
        guard targetStat.st_mode & S_IFMT == S_IFDIR else {
            throw FileSystemEventHistoryError.targetIsNotDirectory(targetURL.path)
        }

        var fileSystemStats = statfs()
        let statFSResult = targetURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystemStats)
        }
        guard statFSResult == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable(targetURL.path)
        }
        guard fileSystemStats.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileSystemEventHistoryError.nonLocalVolume(targetURL.path)
        }

        guard let volumeUUID = FSEventsCopyUUIDForDevice(targetStat.st_dev),
              let volumeUUIDString = CFUUIDCreateString(nil, volumeUUID) as String? else {
            throw FileSystemEventHistoryError.volumeUUIDUnavailable(targetURL.path)
        }
        let resourceValues = try targetURL.resourceValues(forKeys: [.volumeURLKey])
        guard let rootURL = resourceValues.volume?.standardizedFileURL else {
            throw FileSystemEventHistoryError.volumeUUIDUnavailable(targetURL.path)
        }

        let rootPath = rootURL.path
        let targetPath = targetURL.path
        let relativeTargetPath: String
        if targetPath == rootPath {
            relativeTargetPath = ""
        } else {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard targetPath.hasPrefix(prefix) else {
                throw FileSystemEventHistoryError.volumeUUIDUnavailable(targetURL.path)
            }
            relativeTargetPath = String(targetPath.dropFirst(prefix.count))
        }

        return VolumeContext(
            deviceID: targetStat.st_dev,
            uuid: volumeUUIDString,
            rootURL: rootURL,
            relativeTargetPath: relativeTargetPath
        )
    }
}

private nonisolated let radixFSEventHistoryCallback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let callbackInfo else { return }
    let collector = Unmanaged<FSEventHistoryCollector>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    collector.receive(
        eventCount: eventCount,
        relativePaths: paths,
        rawFlags: eventFlags,
        eventIDs: eventIDs
    )
}

private nonisolated final class FSEventHistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let since: ScanIncrementalCheckpoint
    private let through: ScanIncrementalCheckpoint
    private let volumeRootURL: URL
    private var events: [FileSystemEventRecord] = []
    private var continuation: CheckedContinuation<FileSystemEventHistory, Error>?
    private var completion: Result<FileSystemEventHistory, Error>?

    init(
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint,
        volumeRootURL: URL
    ) {
        self.since = since
        self.through = through
        self.volumeRootURL = volumeRootURL
    }

    func value() async throws -> FileSystemEventHistory {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(with: completion)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func receive(
        eventCount: Int,
        relativePaths: UnsafePointer<UnsafePointer<CChar>>,
        rawFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        var sawHistoryDone = false
        var received: [FileSystemEventRecord] = []
        received.reserveCapacity(eventCount)

        for index in 0..<eventCount {
            let rawFlag = rawFlags[index]
            if rawFlag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                sawHistoryDone = true
                continue
            }

            let eventID = eventIDs[index]
            let mappedFlags = FileSystemEventFlags(fseventRawValue: rawFlag)
            // RootChanged carries event ID zero and must never be filtered out.
            guard mappedFlags.contains(.rootChanged) ||
                    (eventID > since.eventID && eventID <= through.eventID) else {
                continue
            }

            let relativePath = String(cString: relativePaths[index])
            let absoluteURL = relativePath.isEmpty
                ? volumeRootURL
                : volumeRootURL.appending(path: relativePath)
            received.append(FileSystemEventRecord(
                path: absoluteURL.path,
                eventID: eventID,
                flags: mappedFlags
            ))
        }

        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        events.append(contentsOf: received)
        let history = sawHistoryDone
            ? FileSystemEventHistory(since: since, through: through, events: events)
            : nil
        lock.unlock()

        if let history {
            finish(.success(history))
        }
    }

    private func finish(_ result: Result<FileSystemEventHistory, Error>) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        completion = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

nonisolated extension FileSystemEventFlags {
    init(fseventRawValue rawValue: FSEventStreamEventFlags) {
        var mappedFlags: FileSystemEventFlags = []
        func copy(_ source: Int, to destination: FileSystemEventFlags) {
            if rawValue & UInt32(source) != 0 {
                mappedFlags.insert(destination)
            }
        }

        copy(kFSEventStreamEventFlagMustScanSubDirs, to: .mustScanSubdirectories)
        copy(kFSEventStreamEventFlagUserDropped, to: .userDropped)
        copy(kFSEventStreamEventFlagKernelDropped, to: .kernelDropped)
        copy(kFSEventStreamEventFlagEventIdsWrapped, to: .eventIDsWrapped)
        copy(kFSEventStreamEventFlagRootChanged, to: .rootChanged)
        copy(kFSEventStreamEventFlagMount, to: .volumeMounted)
        copy(kFSEventStreamEventFlagUnmount, to: .volumeUnmounted)
        copy(kFSEventStreamEventFlagItemCreated, to: .itemCreated)
        copy(kFSEventStreamEventFlagItemRemoved, to: .itemRemoved)
        copy(kFSEventStreamEventFlagItemRenamed, to: .itemRenamed)
        copy(kFSEventStreamEventFlagItemModified, to: .itemModified)
        copy(kFSEventStreamEventFlagItemInodeMetaMod, to: .itemMetadataModified)
        copy(kFSEventStreamEventFlagItemFinderInfoMod, to: .itemMetadataModified)
        copy(kFSEventStreamEventFlagItemChangeOwner, to: .itemMetadataModified)
        copy(kFSEventStreamEventFlagItemXattrMod, to: .itemMetadataModified)
        copy(kFSEventStreamEventFlagItemIsFile, to: .itemIsFile)
        copy(kFSEventStreamEventFlagItemIsDir, to: .itemIsDirectory)
        copy(kFSEventStreamEventFlagItemIsSymlink, to: .itemIsSymbolicLink)
        copy(kFSEventStreamEventFlagItemIsHardlink, to: .itemIsHardLink)
        copy(kFSEventStreamEventFlagItemIsLastHardlink, to: .itemIsLastHardLink)
        copy(kFSEventStreamEventFlagItemCloned, to: .itemCloned)
        self = mappedFlags
    }
}

private nonisolated final class FSEventStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue

    init(stream: FSEventStreamRef, queue: DispatchQueue) {
        self.stream = stream
        self.queue = queue
    }

    func stop() {
        lock.lock()
        guard let stream else {
            lock.unlock()
            return
        }
        self.stream = nil
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        _ = queue
    }
}
