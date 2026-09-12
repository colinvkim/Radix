import Foundation
import Testing

@testable import RadixCore

@MainActor
struct ArchiveWorkflowCoordinatorTests {
    @Test(arguments: [false, true])
    func testSupersededResultCannotApplyFinishOrClearCurrentOperation(staleFails: Bool) async throws {
        let probe = ControlledArchiveWorkProbe()
        let coordinator = ArchiveWorkflowCoordinator()
        defer {
            coordinator.cancel()
            Task { await probe.cancelAll() }
        }
        var successes: [Int] = []
        var failures: [String] = []
        var finishes: [String] = []
        var oldCleanupCount = 0

        coordinator.start(
            kind: .importPreview, title: "Old", message: "Old",
            work: { try await probe.value(for: 0) },
            onSuccess: { successes.append($0) },
            onFailure: { failures.append($0.localizedDescription) },
            onFinish: { finishes.append("old") },
            onCleanup: { oldCleanupCount += 1 }
        )
        try await probe.waitForIssuedRequestCount(1)
        coordinator.start(
            kind: .compare, title: "Current", message: "Current",
            work: { try await probe.value(for: 1) },
            onSuccess: { successes.append($0) },
            onFailure: { failures.append($0.localizedDescription) },
            onFinish: { finishes.append("new") }
        )
        try await probe.waitForIssuedRequestCount(2)

        let staleResult: Result<Int, any Error> =
            staleFails
            ? .failure(TestArchiveWorkflowError.failed) : .success(10)
        try #require(await probe.complete(id: 0, with: staleResult))
        // Cleanup is called after the coordinator handles the result. A yield
        // alone does not establish that the stale callbacks have been rejected.
        try await waitUntil("superseded archive task cleanup") { oldCleanupCount == 1 }
        #expect(successes.isEmpty)
        #expect(failures.isEmpty)
        #expect(finishes.isEmpty)
        #expect(coordinator.operation?.title == "Current")
        #expect(coordinator.operation?.kind == .compare)
        #expect(coordinator.isRunning)

        try #require(await probe.complete(id: 1, with: .success(20)))
        try await waitUntil("current archive workflow completion") { !coordinator.isRunning }
        #expect(successes == [20])
        #expect(failures.isEmpty)
        #expect(finishes == ["new"])
        #expect(coordinator.operation == nil)
    }
}

private enum TestArchiveWorkflowError: LocalizedError {
    case failed

    var errorDescription: String? { "Archive workflow failed" }
}

private actor ControlledArchiveWorkProbe {
    private var issuedCount = 0
    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    func value(for id: Int) async throws -> Int {
        issuedCount += 1
        // Ignore task cancellation so the coordinator must handle stale results.
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }

    func waitForIssuedRequestCount(_ count: Int) async throws {
        try await waitUntil("archive worker request count") { await self.issuedCount >= count }
    }

    func complete(id: Int, with result: Result<Int, any Error>) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(with: result)
        return true
    }

    func cancelAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}
