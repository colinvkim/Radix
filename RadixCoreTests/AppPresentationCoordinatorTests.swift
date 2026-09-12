import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppPresentationCoordinatorTests {
    @Test
    func testArchiveOpenWaitsForOnboardingToDismiss() {
        let archiveURL = URL(filePath: "/tmp/queued.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        #expect(coordinator.requestArchiveImport(archiveURL) == .queued)
        #expect(coordinator.activeSheet == .onboarding)

        let resumedURL = coordinator.cancel(kind: .onboarding)

        #expect(resumedURL == archiveURL)
        #expect(coordinator.activeDestination == nil)
    }

    @Test
    func testPresentationsAdvanceInRequestOrder() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.discardPileReview))
        coordinator.present(.dialog(.trashConfirmation))

        #expect(coordinator.cancel(kind: .onboarding) == nil)
        #expect(coordinator.activeSheet == .discardPileReview)
        #expect(coordinator.activeDialog == nil)

        #expect(coordinator.cancel(kind: .discardPileReview) == nil)
        #expect(coordinator.activeDialog == .trashConfirmation)
        #expect(coordinator.activeSheet == nil)
    }

    @Test
    func testCancellingQueuedPresentationPreventsItFromAppearing() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.dialog(.error))
        coordinator.present(.sheet(.comparisonSetup(UUID())))
        #expect(coordinator.cancel(kind: .error) == nil)
        #expect(coordinator.cancel(kind: .comparisonSetup) == nil)
        #expect(coordinator.cancel(kind: .onboarding) == nil)

        #expect(coordinator.activeDestination == nil)
    }

    @Test
    func testQueuedDestinationKeepsLatestPayload() {
        let firstID = UUID()
        let latestID = UUID()
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.comparisonSetup(firstID)))
        coordinator.present(.sheet(.comparisonSetup(latestID)))
        #expect(coordinator.cancel(kind: .onboarding) == nil)

        #expect(coordinator.activeSheet == .comparisonSetup(latestID))
    }

    @Test
    func testMultipleArchiveOpensResumeOneAtATimeAroundPreview() {
        let firstURL = URL(filePath: "/tmp/first.radixscan")
        let secondURL = URL(filePath: "/tmp/second.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        #expect(coordinator.requestArchiveImport(firstURL) == .queued)
        #expect(coordinator.requestArchiveImport(secondURL) == .queued)
        #expect(coordinator.cancel(kind: .onboarding) == firstURL)

        coordinator.present(.sheet(.importPreview(firstURL)))
        #expect(coordinator.cancel(kind: .importPreview) == secondURL)
        #expect(coordinator.activeDestination == nil)
    }
}
