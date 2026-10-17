//
//  FileSystemChangeWatcher.swift
//  Radix
//

import CoreServices
import Dispatch
import Foundation

nonisolated protocol FileSystemChangeWatching: Sendable {
    /// Replays changes after the scan's boundary, then continues observing.
    /// Cancellation or releasing the stream stops its underlying observer.
    func changes(
        for targetURL: URL,
        since checkpoint: ScanIncrementalCheckpoint?
    ) -> AsyncThrowingStream<[FileSystemEventRecord], Error>
}

nonisolated struct DarwinFileSystemChangeWatcher: FileSystemChangeWatching {
    private let latency: CFTimeInterval

    init(latency: CFTimeInterval = 0.6) {
        self.latency = max(latency, 0)
    }

    func changes(
        for targetURL: URL,
        since checkpoint: ScanIncrementalCheckpoint?
    ) -> AsyncThrowingStream<[FileSystemEventRecord], Error> {
        do {
            let targetURL = targetURL.standardizedFileURL
            let volume = try DarwinFileSystemEventHistoryProvider.volumeContext(for: targetURL)
            let currentEventID = FSEventsGetCurrentEventId()
            guard currentEventID > 0 else {
                throw FileSystemEventHistoryError.eventIDUnavailable(targetURL.path)
            }
            if let checkpoint {
                guard checkpoint.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame else {
                    throw FileSystemEventHistoryError.volumeChanged
                }
                guard checkpoint.eventID > 0 else {
                    throw FileSystemEventHistoryError.invalidCheckpointRange
                }
                guard checkpoint.eventID <= currentEventID else {
                    throw FileSystemEventHistoryError.eventIDRolledBack
                }
            }

            let buffer = FSEventChangeBuffer(
                targetURL: targetURL,
                sinceEventID: checkpoint?.eventID ?? currentEventID
            )
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(buffer).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<FSEventChangeBuffer>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<FSEventChangeBuffer>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            // The startup disk's visible hierarchy crosses the sealed System
            // and firmlinked Data volumes. Host streams report absolute paths.
            let paths = Self.pathsToWatch(for: targetURL) as CFArray
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagFullHistory
            )
            guard let stream = FSEventStreamCreate(
                nil,
                radixFSEventChangeCallback,
                &context,
                paths,
                checkpoint?.eventID ?? currentEventID,
                latency,
                flags
            ) else {
                throw FileSystemEventHistoryError.streamCreationFailed
            }

            let queue = DispatchQueue(label: "dev.colinkim.radix.fsevents.changes", qos: .utility)
            let lifetime = FSEventStreamLifetime(stream: stream, queue: queue)
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                lifetime.stop()
                throw FileSystemEventHistoryError.streamStartFailed
            }

            // The callback's buffer has no reference to this stream or lifetime.
            // Releasing the producer closure therefore releases the lifetime,
            // even when a consumer abandons the stream without cancelling it.
            return AsyncThrowingStream(unfolding: {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return await buffer.next()
                } onCancel: {
                    buffer.cancel()
                    lifetime.stop()
                }
            })
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    static func pathsToWatch(for targetURL: URL) -> [String] {
        let path = targetURL.standardizedFileURL.path
        return path == "/" ? ["/", "/System/Volumes/Data"] : [path]
    }
}

private nonisolated let radixFSEventChangeCallback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let callbackInfo else { return }
    let buffer = Unmanaged<FSEventChangeBuffer>.fromOpaque(callbackInfo).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    var records: [FileSystemEventRecord] = []
    records.reserveCapacity(min(eventCount, FSEventChangeBuffer.defaultEventLimit))
    var overflowEventID: UInt64?
    for index in 0..<eventCount {
        guard let record = buffer.record(
            path: String(cString: paths[index]),
            rawFlags: eventFlags[index],
            eventID: eventIDs[index]
        ) else { continue }
        if records.count < FSEventChangeBuffer.defaultEventLimit, overflowEventID == nil {
            records.append(record)
        } else {
            overflowEventID = max(overflowEventID ?? records.map(\.eventID).max() ?? 0, record.eventID)
        }
    }
    if let overflowEventID {
        records = [buffer.overflowRecord(eventID: overflowEventID)]
    }
    buffer.receive(records)
}

/// A bounded mailbox, independent of AsyncThrowingStream's continuation
/// storage. Overflow keeps an explicit uncertainty event instead of silently
/// losing changes or retaining an unbounded filesystem journal in memory.
nonisolated final class FSEventChangeBuffer: @unchecked Sendable {
    static let defaultEventLimit = 4_096
    private let lock = NSLock()
    private let targetPath: String
    private let resolvedTargetPath: String
    private let sinceEventID: UInt64
    private let eventLimit: Int
    private var pending: [FileSystemEventRecord] = []
    private var overflowed = false
    private var cancelled = false
    private var continuation: CheckedContinuation<[FileSystemEventRecord]?, Never>?

    init(targetURL: URL, sinceEventID: UInt64, eventLimit: Int = defaultEventLimit) {
        self.targetPath = targetURL.standardizedFileURL.path
        self.resolvedTargetPath = targetURL.resolvingSymlinksInPath().path
        self.sinceEventID = sinceEventID
        self.eventLimit = max(eventLimit, 1)
    }

    func record(path: String, rawFlags: FSEventStreamEventFlags, eventID: UInt64) -> FileSystemEventRecord? {
        // HistoryDone marks the transition to live events, not stream completion.
        guard rawFlags & UInt32(kFSEventStreamEventFlagHistoryDone) == 0 else { return nil }
        let flags = FileSystemEventFlags(fseventRawValue: rawFlags)
        let uncertainty: FileSystemEventFlags = [
            .mustScanSubdirectories, .userDropped, .kernelDropped, .eventIDsWrapped, .rootChanged,
        ]
        guard eventID > sinceEventID || !flags.intersection(uncertainty).isEmpty else { return nil }

        var path = path
        let dataRoot = "/System/Volumes/Data"
        if !Self.contains(targetPath, under: dataRoot), Self.contains(path, under: dataRoot) {
            let visiblePath = path == dataRoot ? "/" : String(path.dropFirst(dataRoot.count))
            if Self.contains(visiblePath, under: targetPath) || Self.contains(visiblePath, under: resolvedTargetPath) {
                path = visiblePath
            }
        }
        if targetPath != resolvedTargetPath, Self.contains(path, under: resolvedTargetPath) {
            path = targetPath + path.dropFirst(resolvedTargetPath.count)
        }
        guard Self.contains(path, under: targetPath) else {
            // Dropped-event notifications can name a broader ancestor than the
            // subscribed target. Preserve the uncertainty for this whole target.
            guard !flags.intersection(uncertainty).isEmpty else { return nil }
            return FileSystemEventRecord(path: targetPath, eventID: eventID, flags: flags)
        }
        return FileSystemEventRecord(path: path, eventID: eventID, flags: flags)
    }

    func receive(_ records: [FileSystemEventRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: records)
            return
        }
        if overflowed || pending.count + records.count > eventLimit {
            let eventID = max(pending.map(\.eventID).max() ?? 0, records.map(\.eventID).max() ?? 0)
            pending = [overflowRecord(eventID: eventID)]
            overflowed = true
        } else {
            pending.append(contentsOf: records)
        }
        lock.unlock()
    }

    func next() async -> [FileSystemEventRecord]? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if !pending.isEmpty {
                let records = pending
                pending.removeAll(keepingCapacity: true)
                overflowed = false
                lock.unlock()
                continuation.resume(returning: records)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        pending.removeAll()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    func overflowRecord(eventID: UInt64) -> FileSystemEventRecord {
        FileSystemEventRecord(path: targetPath, eventID: eventID, flags: [.mustScanSubdirectories, .userDropped])
    }

    private static func contains(_ path: String, under root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}
