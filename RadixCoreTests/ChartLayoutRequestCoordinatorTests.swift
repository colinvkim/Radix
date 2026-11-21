import Foundation
import Testing

@testable import RadixCore

@MainActor
struct ChartLayoutRequestCoordinatorTests {
    @Test(arguments: SupersededCompletion.allCases)
    private func testSupersededRequestCannotWinWhenLayoutIDIsReused(completion: SupersededCompletion) async throws {
        let coordinator = ChartLayoutRequestCoordinator<Int>()
        let operation = LayoutOperation()
        let old = coordinator.start(layoutID: "same-layout") { try await operation.run() }
        defer { Task { await operation.finish(.success(-1)) } }
        try await waitUntil("old layout operation started") { await operation.isWaiting }

        let latest = coordinator.start(layoutID: "same-layout") { 29 }
        guard case .success(let value) = await coordinator.outcome(for: latest) else {
            Issue.record("The latest generation should return its output.")
            return
        }
        #expect(value == 29)

        await operation.finish(completion.result)
        guard case .superseded = await coordinator.outcome(for: old) else {
            Issue.record("An older generation must remain superseded after its operation finishes.")
            return
        }
    }

    @Test(arguments: [false, true])
    func testFailureAndCancellationLeaveCoordinatorReusable(isCancellation: Bool) async {
        let coordinator = ChartLayoutRequestCoordinator<Int>()
        let failed = coordinator.start(layoutID: "failed") {
            if isCancellation { throw CancellationError() }
            throw LayoutTestError.rejected
        }

        switch await coordinator.outcome(for: failed) {
        case .cancelled:
            #expect(isCancellation)
        case .failure(let error):
            #expect(!isCancellation)
            #expect(error.message == "Layout rejected.")
        default:
            Issue.record("A current request must report its failure or cancellation.")
        }

        let retry = coordinator.start(layoutID: "retry") { 41 }
        guard case .success(let value) = await coordinator.outcome(for: retry) else {
            Issue.record("A failed request must not prevent a retry.")
            return
        }
        #expect(value == 41)
    }

    @Test
    func testCancellingOutcomeWaiterCancelsUnderlyingRequest() async throws {
        let coordinator = ChartLayoutRequestCoordinator<Int>()
        let operation = LayoutOperation()
        let request = coordinator.start(layoutID: "cancelled") { try await operation.run() }
        defer { Task { await operation.finish(.success(-1)) } }
        try await waitUntil("layout operation started") { await operation.isWaiting }
        let waiter = Task { await coordinator.outcome(for: request) }

        waiter.cancel()
        try await operation.waitForCancellation()
        await operation.finish(.success(17))

        guard case .cancelled = await waiter.value else {
            Issue.record("Cancelling the waiter must reject even a late successful operation.")
            return
        }
    }

    @Test
    func testDeinitializationCancelsRunningRequest() async throws {
        var coordinator: ChartLayoutRequestCoordinator<Int>? = ChartLayoutRequestCoordinator()
        let operation = LayoutOperation()
        _ = try #require(coordinator).start(layoutID: "pending") { try await operation.run() }
        defer { Task { await operation.finish(.success(-1)) } }
        try await waitUntil("layout operation started before release") { await operation.isWaiting }

        coordinator = nil

        try await operation.waitForCancellation()
    }
}

private enum SupersededCompletion: CaseIterable {
    case value
    case failure
    case cancellation

    var result: Result<Int, any Error> {
        switch self {
        case .value: .success(17)
        case .failure: .failure(LayoutTestError.rejected)
        case .cancellation: .failure(CancellationError())
        }
    }
}

private enum LayoutTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Layout rejected." }
}

private actor LayoutOperation {
    private var continuation: CheckedContinuation<Int, any Error>?
    private var result: Result<Int, any Error>?

    private var receivedCancellation = false

    var isWaiting: Bool { continuation != nil }

    func run() async throws -> Int {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() {
        receivedCancellation = true
    }

    func waitForCancellation() async throws {
        try await waitUntil("layout operation received cancellation") { await self.receivedCancellation }
    }

    func finish(_ result: Result<Int, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
