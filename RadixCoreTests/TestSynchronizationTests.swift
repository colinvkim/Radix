import Foundation
import Testing

@testable import RadixCore

@MainActor
struct TestSynchronizationTests {
    @Test
    func watcherDeliveryBarrierWaitsForConsumerProcessingAndSupportsCancellation() async throws {
        let watcher = TestFileSystemChangeWatcher()
        let stream = watcher.changes(for: URL(filePath: "/fixture"), since: nil)
        let clock = ManualTestClock()
        var handledBatches = 0
        var deliveryFinished = false
        let consumer = Task {
            for try await _ in stream {
                try await clock.sleep(for: .seconds(1))
                handledBatches += 1
            }
        }
        defer { consumer.cancel() }
        let delivery = Task {
            try await watcher.emitAndWaitUntilProcessed([
                FileSystemEventRecord(path: "/fixture/file", eventID: 1, flags: .itemCreated)
            ])
            deliveryFinished = true
        }
        defer { delivery.cancel() }

        try await waitUntil("consumer processing suspended") { clock.pendingSleeps == 1 }
        #expect(!deliveryFinished)
        #expect(handledBatches == 0)
        clock.advance(by: .seconds(1))
        try await waitUntil("delivery acknowledged after processing") { deliveryFinished }
        #expect(handledBatches == 1)

        consumer.cancel()
        try await consumer.value
        try await waitUntil("active watcher read cancelled") { watcher.cancellations == 1 }
    }

    @Test
    func timedOutWaitStopsTheTestInsteadOfContinuingWithInvalidState() async {
        var continuedAfterTimeout = false
        await #expect(throws: TestWaitTimeout.self) {
            try await waitUntil("never satisfied", timeout: 0) { false }
            continuedAfterTimeout = true
        }
        #expect(!continuedAfterTimeout)
    }

    @Test
    func cancelledWaitDoesNotTreatAnAlreadyTrueConditionAsSuccess() async {
        let task = Task { try await waitUntil { true } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func cancelledClockSleepStillThrowsWhenTimeAdvancesBeforeCancellationCleanup() async throws {
        let clock = ManualTestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        defer { sleeper.cancel() }
        try await waitUntil("clock sleep registered") { clock.pendingSleeps == 1 }

        sleeper.cancel()
        clock.advance(by: .seconds(1))

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingSleeps == 0)
    }
}
