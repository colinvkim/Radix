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
}
