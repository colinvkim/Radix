import XCTest
@testable import RadixCore

@MainActor
final class WorkspaceTourControllerTests: XCTestCase {
    func testWaitsForInitialScanWithoutInterruptingInformationalTips() {
        let tour = WorkspaceTourController()
        let snapshotID = UUID()
        tour.start(snapshotID: nil, isReady: false)
        tour.updateScan(snapshotID: snapshotID, isReady: false)
        XCTAssertEqual(tour.step, .scan)

        tour.updateScan(snapshotID: snapshotID, isReady: true)
        XCTAssertEqual(tour.step, .selectResult)
        tour.advance()
        tour.advance()
        tour.updateScan(snapshotID: nil, isReady: false)
        XCTAssertEqual(tour.step, .visualization)
        tour.updateScan(snapshotID: UUID(), isReady: true)
        XCTAssertEqual(tour.step, .visualization)
    }

    func testNextAdvancesThroughInformationalTips() {
        let tour = WorkspaceTourController()
        let snapshotID = UUID()
        tour.start(snapshotID: snapshotID, isReady: true)
        let informationalSteps: [WorkspaceTourController.Step] = [
            .selectResult, .openFolder, .visualization, .inspector, .search, .rescan
        ]
        for step in informationalSteps {
            XCTAssertEqual(tour.step, step)
            tour.updateScan(snapshotID: snapshotID, isReady: true)
            tour.didAddMarks(["file"], snapshotID: snapshotID)
            tour.reviewOpened()
            XCTAssertEqual(tour.step, step)
            tour.advance()
        }
        XCTAssertEqual(tour.step, .markForReview)
    }

    func testReviewUsesNextAfterAddingMarksInTheCurrentSnapshot() {
        let snapshotID = UUID()
        let tour = tourAtMarkLesson(snapshotID: snapshotID)
        tour.didAddMarks([], snapshotID: snapshotID)
        tour.didAddMarks(["stale"], snapshotID: UUID())
        XCTAssertEqual(tour.step, .markForReview)

        tour.didAddMarks(["practice-a", "practice-b"], snapshotID: snapshotID)
        XCTAssertEqual(tour.step, .review)
        tour.reviewOpened()
        XCTAssertEqual(tour.step, .removeMark)
        tour.reviewClosed()
        XCTAssertEqual(tour.step, .review)
        tour.reviewOpened()
        tour.advance()
        XCTAssertEqual(tour.step, .finished)
        tour.reviewClosed()
        XCTAssertFalse(tour.isActive)
    }

    func testChangingScansRestartsTheMarkingLessonAndRejectsOldAdditions() {
        let snapshotID = UUID()
        let tour = tourAtMarkLesson(snapshotID: snapshotID)
        tour.didAddMarks(["practice"], snapshotID: snapshotID)
        tour.updateScan(snapshotID: nil, isReady: false)
        tour.updateScan(snapshotID: UUID(), isReady: true)
        XCTAssertEqual(tour.step, .markForReview)
        tour.didAddMarks(["practice"], snapshotID: snapshotID)
        XCTAssertEqual(tour.step, .markForReview)
    }

    func testSkippingPracticeAndRestartingRemainAvailable() {
        let tour = tourAtMarkLesson(snapshotID: UUID())
        tour.advance()
        XCTAssertEqual(tour.step, .finished)
        tour.advance()
        XCTAssertFalse(tour.isActive)

        tour.start(snapshotID: nil, isReady: false)
        tour.advance()
        XCTAssertEqual(tour.step, .scan)
        tour.stop()
        tour.updateScan(snapshotID: UUID(), isReady: true)
        XCTAssertFalse(tour.isActive)
    }

    private func tourAtMarkLesson(snapshotID: UUID) -> WorkspaceTourController {
        let tour = WorkspaceTourController()
        tour.start(snapshotID: snapshotID, isReady: true)
        for _ in 0..<6 { tour.advance() }
        XCTAssertEqual(tour.step, .markForReview)
        return tour
    }
}
