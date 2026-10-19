import Foundation
import Testing

@testable import RadixCore

/// Each stream has one consumer. Asking for its next batch acknowledges that
/// FolderRefreshController has synchronously handled the previously returned batch.
nonisolated final class TestFileSystemChangeWatcher: FileSystemChangeWatching, @unchecked Sendable {
    struct Request {
        let targetURL: URL
        let checkpoint: ScanIncrementalCheckpoint?
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var streams: [Stream] = []
    private var cancellationCount = 0
    private var shouldFail = false

    var requests: [Request] { lock.withLock { storedRequests } }
    var cancellations: Int { lock.withLock { cancellationCount } }
    var failAtStartup: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func changes(for targetURL: URL, since checkpoint: ScanIncrementalCheckpoint?)
        -> AsyncThrowingStream<[FileSystemEventRecord], Error> {
        let stream = Stream { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.cancellationCount += 1 }
        }
        let fails = lock.withLock {
            storedRequests.append(Request(targetURL: targetURL, checkpoint: checkpoint))
            streams.append(stream)
            return shouldFail
        }
        if fails { stream.continuation.finish(throwing: FileSystemEventHistoryError.streamStartFailed) }
        return AsyncThrowingStream(unfolding: { try await stream.next() })
    }

    @MainActor
    func emitAndWaitUntilProcessed(
        _ events: [FileSystemEventRecord],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard let stream = lock.withLock({ streams.last }), let ordinal = stream.emit(events) else {
            throw FixtureError.streamUnavailable
        }
        try await waitUntil("filesystem event batch processed", sourceLocation: sourceLocation) {
            stream.processedBatchCount >= ordinal || stream.isFinished
        }
        guard stream.processedBatchCount >= ordinal else { throw FixtureError.streamUnavailable }
    }

    private enum FixtureError: Error { case streamUnavailable }

    private final class Stream: @unchecked Sendable {
        let continuation: AsyncThrowingStream<[FileSystemEventRecord], Error>.Continuation
        private var iterator: AsyncThrowingStream<[FileSystemEventRecord], Error>.Iterator
        private let lock = NSLock()
        private var emittedBatches = 0
        private var returnedBatches = 0
        private var processedBatches = 0
        private var finished = false

        var processedBatchCount: Int { lock.withLock { processedBatches } }
        var isFinished: Bool { lock.withLock { finished } }

        init(onCancelled: @escaping @Sendable () -> Void) {
            let pair = AsyncThrowingStream<[FileSystemEventRecord], Error>.makeStream()
            continuation = pair.continuation
            iterator = pair.stream.makeAsyncIterator()
            continuation.onTermination = { [weak self] termination in
                if let self { self.lock.withLock { self.finished = true } }
                if case .cancelled = termination { onCancelled() }
            }
        }

        func emit(_ events: [FileSystemEventRecord]) -> Int? {
            let ordinal = lock.withLock { emittedBatches += 1; return emittedBatches }
            if case .enqueued = continuation.yield(events) { return ordinal }
            return nil
        }

        func next() async throws -> [FileSystemEventRecord]? {
            lock.withLock { processedBatches = returnedBatches }
            let events = try await iterator.next()
            if events != nil { lock.withLock { returnedBatches += 1 } }
            return events
        }
    }
}
