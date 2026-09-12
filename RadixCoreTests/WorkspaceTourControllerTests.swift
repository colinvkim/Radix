import Foundation
import Testing

@testable import RadixCore

@MainActor
struct WorkspaceTourControllerTests {
    @Test
    func testWaitsForInitialScanWithoutInterruptingInformationalTips() {
        let tour = WorkspaceTourController()
        let snapshotID = UUID()
        tour.start(snapshotID: nil, isReady: false)
        tour.updateScan(snapshotID: snapshotID, isReady: false)
        #expect(tour.step == .scan)

        tour.updateScan(snapshotID: snapshotID, isReady: true)
        #expect(tour.step == .selectResult)
        tour.advance()
        tour.advance()
        tour.updateScan(snapshotID: nil, isReady: false)
        #expect(tour.step == .visualization)
        tour.updateScan(snapshotID: UUID(), isReady: true)
        #expect(tour.step == .visualization)
    }

    @Test
    func testNextAdvancesThroughInformationalTips() {
        let tour = WorkspaceTourController()
        let snapshotID = UUID()
        tour.start(snapshotID: snapshotID, isReady: true)
        let informationalSteps: [WorkspaceTourController.Step] = [
            .selectResult, .openFolder, .visualization, .inspector, .search, .rescan,
        ]
        for step in informationalSteps {
            #expect(tour.step == step)
            tour.updateScan(snapshotID: snapshotID, isReady: true)
            tour.didAddMarks(["file"], snapshotID: snapshotID)
            tour.reviewOpened()
            #expect(tour.step == step)
            tour.advance()
        }
        #expect(tour.step == .markForReview)
    }

    @Test
    func testReviewUsesNextAfterAddingMarksInTheCurrentSnapshot() {
        let snapshotID = UUID()
        let tour = tourAtMarkLesson(snapshotID: snapshotID)
        tour.didAddMarks([], snapshotID: snapshotID)
        tour.didAddMarks(["stale"], snapshotID: UUID())
        #expect(tour.step == .markForReview)

        tour.didAddMarks(["practice-a", "practice-b"], snapshotID: snapshotID)
        #expect(tour.step == .review)
        tour.reviewOpened()
        #expect(tour.step == .removeMark)
        tour.reviewClosed()
        #expect(tour.step == .review)
        tour.reviewOpened()
        tour.advance()
        #expect(tour.step == .finished)
        tour.reviewClosed()
        #expect(!(tour.isActive))
    }

    @Test
    func testChangingScansRestartsTheMarkingLessonAndRejectsOldAdditions() {
        let snapshotID = UUID()
        let tour = tourAtMarkLesson(snapshotID: snapshotID)
        tour.didAddMarks(["practice"], snapshotID: snapshotID)
        tour.updateScan(snapshotID: nil, isReady: false)
        tour.updateScan(snapshotID: UUID(), isReady: true)
        #expect(tour.step == .markForReview)
        tour.didAddMarks(["practice"], snapshotID: snapshotID)
        #expect(tour.step == .markForReview)
    }

    @Test
    func testSkippingPracticeAndRestartingRemainAvailable() {
        let tour = tourAtMarkLesson(snapshotID: UUID())
        tour.advance()
        #expect(tour.step == .finished)
        tour.advance()
        #expect(!(tour.isActive))

        tour.start(snapshotID: nil, isReady: false)
        tour.advance()
        #expect(tour.step == .scan)
        tour.stop()
        tour.updateScan(snapshotID: UUID(), isReady: true)
        #expect(!(tour.isActive))
    }

    private func tourAtMarkLesson(snapshotID: UUID) -> WorkspaceTourController {
        let tour = WorkspaceTourController()
        tour.start(snapshotID: snapshotID, isReady: true)
        for _ in 0..<6 { tour.advance() }
        #expect(tour.step == .markForReview)
        return tour
    }
}
