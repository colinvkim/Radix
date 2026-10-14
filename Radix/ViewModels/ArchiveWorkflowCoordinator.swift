import Combine
import Foundation

enum ArchiveOperationKind: String, Equatable, Sendable {
    case export
    case importPreview
    case `import`
    case compare
}

struct ArchiveOperationState: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ArchiveOperationKind
    let title: String
    var message: String
    var progressFraction: Double?
}

@MainActor
final class ArchiveWorkflowCoordinator: ObservableObject {
    @Published private(set) var operation: ArchiveOperationState?

    private var generation: UUID?
    private var operationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    var onBecameIdle: (() -> Void)?

    var isRunning: Bool {
        generation != nil
    }

    deinit {
        operationTask?.cancel()
        progressTask?.cancel()
    }

    func start<Result: Sendable>(
        kind: ArchiveOperationKind? = nil,
        title: String = "",
        message: String = "",
        progressReporter: ScanArchiveProgressReporter? = nil,
        work: @escaping @Sendable () async throws -> Result,
        onSuccess: @escaping (Result) async throws -> Void,
        onFailure: @escaping (any Error) -> Void,
        onFinish: (() -> Void)? = nil,
        onCleanup: (() -> Void)? = nil
    ) {
        cancel(notifyWhenIdle: false)
        let generation = UUID()
        self.generation = generation

        if let kind {
            operation = ArchiveOperationState(
                id: generation,
                kind: kind,
                title: title,
                message: message,
                progressFraction: nil
            )
        }

        if let progressReporter {
            progressTask = Task { [weak self] in
                for await progress in progressReporter.updates {
                    guard let self, self.generation == generation else { return }
                    updateCurrentOperation(
                        message: progress.message,
                        progressFraction: progress.fractionCompleted
                    )
                }
            }
        }

        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                onCleanup?()
                if self.generation == generation {
                    onFinish?()
                }
                finish(generation: generation)
            }

            do {
                let worker = Task<Result, any Error>.detached(priority: .utility) {
                    try await work()
                }
                let result = try await Self.value(cancelling: worker)
                guard !Task.isCancelled, self.generation == generation else { return }
                try await onSuccess(result)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                onFailure(error)
            }
        }
    }

    func updateCurrentOperation(message: String, progressFraction: Double?) {
        guard var operation else { return }
        operation.message = message
        operation.progressFraction = progressFraction
        self.operation = operation
    }

    func cancel() {
        cancel(notifyWhenIdle: true)
    }

    private func cancel(notifyWhenIdle: Bool) {
        generation = nil
        operationTask?.cancel()
        operationTask = nil
        progressTask?.cancel()
        progressTask = nil
        operation = nil
        if notifyWhenIdle {
            onBecameIdle?()
        }
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        operationTask = nil
        progressTask?.cancel()
        progressTask = nil
        operation = nil
        onBecameIdle?()
    }

    nonisolated private static func value<Result: Sendable>(
        cancelling task: Task<Result, any Error>
    ) async throws -> Result {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
