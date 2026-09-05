import XCTest
@testable import RadixCore

@MainActor
final class AppPresentationCoordinatorTests: XCTestCase {
    func testArchiveOpenWaitsForOnboardingToDismiss() {
        let archiveURL = URL(filePath: "/tmp/queued.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        XCTAssertEqual(coordinator.requestArchiveImport(archiveURL), .queued)
        XCTAssertEqual(coordinator.activeSheet, .onboarding)

        let resumedURL = coordinator.cancel(kind: .onboarding)

        XCTAssertEqual(resumedURL, archiveURL)
        XCTAssertNil(coordinator.activeDestination)
    }

    func testPresentationsAdvanceInRequestOrder() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.discardPileReview))
        coordinator.present(.dialog(.trashConfirmation))

        XCTAssertNil(coordinator.cancel(kind: .onboarding))
        XCTAssertEqual(coordinator.activeSheet, .discardPileReview)
        XCTAssertNil(coordinator.activeDialog)

        XCTAssertNil(coordinator.cancel(kind: .discardPileReview))
        XCTAssertEqual(coordinator.activeDialog, .trashConfirmation)
        XCTAssertNil(coordinator.activeSheet)
    }

    func testCancellingQueuedPresentationPreventsItFromAppearing() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.dialog(.error))
        coordinator.present(.sheet(.comparisonSetup(UUID())))
        XCTAssertNil(coordinator.cancel(kind: .error))
        XCTAssertNil(coordinator.cancel(kind: .comparisonSetup))
        XCTAssertNil(coordinator.cancel(kind: .onboarding))

        XCTAssertNil(coordinator.activeDestination)
    }

    func testQueuedDestinationKeepsLatestPayload() {
        let firstID = UUID()
        let latestID = UUID()
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.comparisonSetup(firstID)))
        coordinator.present(.sheet(.comparisonSetup(latestID)))
        XCTAssertNil(coordinator.cancel(kind: .onboarding))

        XCTAssertEqual(coordinator.activeSheet, .comparisonSetup(latestID))
    }

    func testMultipleArchiveOpensResumeOneAtATimeAroundPreview() {
        let firstURL = URL(filePath: "/tmp/first.radixscan")
        let secondURL = URL(filePath: "/tmp/second.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        XCTAssertEqual(coordinator.requestArchiveImport(firstURL), .queued)
        XCTAssertEqual(coordinator.requestArchiveImport(secondURL), .queued)
        XCTAssertEqual(coordinator.cancel(kind: .onboarding), firstURL)

        coordinator.present(.sheet(.importPreview(firstURL)))
        XCTAssertEqual(coordinator.cancel(kind: .importPreview), secondURL)
        XCTAssertNil(coordinator.activeDestination)
    }
}
