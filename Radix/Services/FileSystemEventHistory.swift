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
    private let historyTimeout: TimeInterval

    init(latency: CFTimeInterval = 0.05, historyTimeout: TimeInterval = 10) {
        self.latency = max(latency, 0)
        self.historyTimeout = max(historyTimeout, 0)
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
            volume: volume
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
            return try await collector.value(timeout: historyTimeout)
        } onCancel: {
            collector.cancel()
            lifetime.stop()
        }
    }

    struct VolumeContext: Sendable {
        let deviceID: dev_t
        let uuid: String
        let rootPath: String
        let relativeTargetPath: String
        let scanTargetPath: String

        func scanPath(for relativePath: String) -> String {
            let suffix: String
            if relativePath == relativeTargetPath {
                return scanTargetPath
            } else if relativeTargetPath.isEmpty {
                suffix = relativePath
            } else if relativePath.hasPrefix(relativeTargetPath + "/") {
                suffix = String(relativePath.dropFirst(relativeTargetPath.count + 1))
            } else {
                if relativePath.isEmpty { return rootPath }
                return rootPath == "/" ? "/" + relativePath : rootPath + "/" + relativePath
            }
            return scanTargetPath == "/" ? "/" + suffix : scanTargetPath + "/" + suffix
        }
    }

    static func volumeContext(for targetURL: URL) throws -> VolumeContext {
        let targetPath = targetURL.path
        let descriptor = targetURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ENOTDIR {
                throw FileSystemEventHistoryError.targetIsNotDirectory(targetPath)
            }
            throw FileSystemEventHistoryError.targetUnavailable(targetPath)
        }
        defer { close(descriptor) }

        var targetStat = stat()
        var fileSystemStats = statfs()
        guard fstat(descriptor, &targetStat) == 0,
              fstatfs(descriptor, &fileSystemStats) == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable(targetPath)
        }
        guard fileSystemStats.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileSystemEventHistoryError.nonLocalVolume(targetPath)
        }

        let physicalTargetPath = try physicalPath(for: descriptor, targetPath: targetPath)
        let mountPath = withUnsafeBytes(of: fileSystemStats.f_mntonname) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        let mountDescriptor = mountPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard mountDescriptor >= 0 else {
            throw FileSystemEventHistoryError.targetUnavailable(targetPath)
        }
        defer { close(mountDescriptor) }
        var mountStat = stat()
        guard fstat(mountDescriptor, &mountStat) == 0,
              mountStat.st_dev == targetStat.st_dev else {
            throw FileSystemEventHistoryError.targetUnavailable(targetPath)
        }
        let rootPath = try physicalPath(for: mountDescriptor, targetPath: targetPath)
        let relativeTargetPath: String
        if physicalTargetPath == rootPath {
            relativeTargetPath = ""
        } else {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard physicalTargetPath.hasPrefix(prefix) else {
                throw FileSystemEventHistoryError.targetUnavailable(targetPath)
            }
            relativeTargetPath = String(physicalTargetPath.dropFirst(prefix.count))
        }

        guard let volumeUUID = FSEventsCopyUUIDForDevice(targetStat.st_dev),
              let volumeUUIDString = CFUUIDCreateString(nil, volumeUUID) as String? else {
            throw FileSystemEventHistoryError.volumeUUIDUnavailable(targetPath)
        }
        return VolumeContext(
            deviceID: targetStat.st_dev,
            uuid: volumeUUIDString,
            rootPath: rootPath,
            relativeTargetPath: relativeTargetPath,
            scanTargetPath: targetPath
        )
    }

    private static func physicalPath(for descriptor: Int32, targetPath: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH_NOFIRMLINK, &buffer) == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable(targetPath)
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
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

nonisolated final class FSEventHistoryCollector: @unchecked Sendable {
    struct TimeoutError: Error {}

    private let lock = NSLock()
    private let since: ScanIncrementalCheckpoint
    private let through: ScanIncrementalCheckpoint
    private let volume: DarwinFileSystemEventHistoryProvider.VolumeContext
    private var events: [FileSystemEventRecord] = []
    private var continuation: CheckedContinuation<FileSystemEventHistory, Error>?
    private var completion: Result<FileSystemEventHistory, Error>?

    init(
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint,
        volume: DarwinFileSystemEventHistoryProvider.VolumeContext
    ) {
        self.since = since
        self.through = through
        self.volume = volume
    }

    func value(timeout: TimeInterval) async throws -> FileSystemEventHistory {
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
            received.append(FileSystemEventRecord(
                path: volume.scanPath(for: relativePath),
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

nonisolated final class FSEventStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue

    init(stream: FSEventStreamRef, queue: DispatchQueue) {
        self.stream = stream
        self.queue = queue
    }

    deinit {
        stop()
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
