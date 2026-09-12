import Testing

@MainActor
struct TestSynchronizationTests {
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

        // Keep the main actor until advance wins the race against onCancel's queued cleanup.
        sleeper.cancel()
        clock.advance(by: .seconds(1))

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingSleeps == 0)
    }
}
