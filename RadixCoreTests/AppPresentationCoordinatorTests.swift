import Combine
import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppPresentationCoordinatorTests {
    @Test
    func testPresentingActiveDestinationPublishesOnlyChangedPayloads() {
        let first = AppPresentationCoordinator.Destination.sheet(.comparisonSetup(UUID()))
        let second = AppPresentationCoordinator.Destination.sheet(.comparisonSetup(UUID()))
        let coordinator = AppPresentationCoordinator(initialDestination: first)
        var destinations: [AppPresentationCoordinator.Destination?] = []
        let subscription = coordinator.$activeDestination.sink { destinations.append($0) }
        defer { subscription.cancel() }

        coordinator.present(first)
        coordinator.present(second)
        coordinator.present(second)

        #expect(destinations == [first, second])
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
        #expect(coordinator.activeSheet == .onboarding)
        #expect(coordinator.cancel(kind: .onboarding) == firstURL)
        #expect(coordinator.activeDestination == nil)

        coordinator.present(.sheet(.importPreview(firstURL)))
        #expect(coordinator.cancel(kind: .importPreview) == secondURL)
        #expect(coordinator.activeDestination == nil)
    }
}
