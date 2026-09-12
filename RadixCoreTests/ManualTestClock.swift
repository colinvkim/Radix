import Foundation

@MainActor
final class ManualTestClock {
    private(set) var now = ContinuousClock.now
    private var sleepers: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
    var pendingSleeps: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard duration > .zero else { return }
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (now.advanced(by: duration), continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in
                self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        now = now.advanced(by: duration)
        for (id, sleeper) in sleepers where sleeper.0 <= now {
            sleepers.removeValue(forKey: id)?.1.resume()
        }
    }
}
