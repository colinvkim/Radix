import Foundation

/// Releases retired ownership after the publishing stack unwinds. UI producers
/// share a queue and wait for cleanup before preparing another large projection.
@MainActor
final class BackgroundReleaseQueue {
    static let shared = BackgroundReleaseQueue()

    private let queue: DispatchQueue
    private let batch = DiscardedValues()
    private var task: Task<Void, Never>?

    init(queue: DispatchQueue = DispatchQueue(label: "com.colinkim.Radix.buffer-release", qos: .utility)) {
        self.queue = queue
    }

    var isReleasing: Bool { task != nil }

    func discard(_ value: some Sendable) {
        batch.append(value)
        guard task == nil else { return }
        // Starting on this actor prevents temporary publishing-stack copies
        // from outliving the background owner and doing the final release here.
        task = Task { [weak self, batch, queue] in
            repeat {
                await withCheckedContinuation { continuation in
                    queue.async {
                        batch.release()
                        continuation.resume()
                    }
                }
            } while !batch.isEmpty
            self?.task = nil
        }
    }

    func waitForPendingReleases() async {
        while let task { await task.value }
    }
}

private nonisolated final class DiscardedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any Sendable] = []

    var isEmpty: Bool { lock.withLock { values.isEmpty } }

    func append(_ value: some Sendable) {
        lock.withLock { values.append(value) }
    }

    @inline(never)
    func release() {
        let retired = lock.withLock {
            let retired = values
            values = []
            return retired
        }
        // No destruction while holding the lock or on the main actor.
        withExtendedLifetime(retired) {}
    }
}
