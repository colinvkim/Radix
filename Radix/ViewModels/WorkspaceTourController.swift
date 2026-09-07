import Combine
import Foundation

/// Advances informational tips explicitly and observes the Discard Pile exercise.
@MainActor
final class WorkspaceTourController: ObservableObject {
    enum Step: CaseIterable {
        case scan, selectResult, openFolder, visualization, inspector, search, rescan
        case markForReview, review, removeMark, finished
    }

    @Published private(set) var step: Step?

    private var snapshotID: UUID?
    private var resumeStep: Step?

    var onStop: (() -> Void)?

    var isActive: Bool { step != nil }

    func start(snapshotID: UUID?, isReady: Bool) {
        self.snapshotID = snapshotID
        resumeStep = nil
        step = snapshotID != nil && isReady ? .selectResult : .scan
    }

    func stop() {
        let wasActive = isActive
        step = nil
        resumeStep = nil
        snapshotID = nil
        if wasActive { onStop?() }
    }

    func updateScan(snapshotID: UUID?, isReady: Bool) {
        guard let step, step != .finished else { return }
        guard let snapshotID, isReady else {
            if step == .markForReview || step == .review || step == .removeMark {
                resumeStep = .markForReview
                self.step = .scan
            }
            return
        }

        if self.snapshotID != snapshotID, step == .review || step == .removeMark {
            self.step = .markForReview
        }
        self.snapshotID = snapshotID
        if self.step == .scan {
            self.step = resumeStep ?? .selectResult
            resumeStep = nil
        }
    }

    func didAddMarks(_ nodeIDs: Set<FileNodeRecord.ID>, snapshotID: UUID) {
        guard step == .markForReview, snapshotID == self.snapshotID, !nodeIDs.isEmpty else { return }
        step = .review
    }

    func reviewOpened() {
        if step == .review { step = .removeMark }
    }

    func reviewClosed() {
        if step == .removeMark { step = .review }
        if step == .finished { stop() }
    }

    /// Next advances informational tips; Skip Exercise bypasses the Discard Pile exercise.
    func advance() {
        switch step {
        case .selectResult: step = .openFolder
        case .openFolder: step = .visualization
        case .visualization: step = .inspector
        case .inspector: step = .search
        case .search: step = .rescan
        case .rescan: step = .markForReview
        case .markForReview, .review, .removeMark: step = .finished
        case .finished: stop()
        case .scan, nil: break
        }
    }
}
