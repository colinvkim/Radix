import Foundation
import Testing

@testable import RadixCore

@MainActor
struct ChartLayoutPresentationStateTests {
    @Test
    func testInitialLayoutAwaitsAndObscuresRendering() {
        let state = presentationState(readiness: ChartLayoutReadiness())

        #expect(state.isAwaitingLayout)
        #expect(!(state.canUseRenderedLayout))
        #expect(state.shouldObscureRenderedLayout)
        #expect(!(state.showsFailure))
    }

    @Test
    func testPendingSameRequestKeepsCurrentRenderUsable() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()

        let state = presentationState(readiness: readiness)

        #expect(!(state.isAwaitingLayout))
        #expect(state.canUseRenderedLayout)
        #expect(!(state.shouldObscureRenderedLayout))
    }

    @Test
    func testPendingDifferentRequestBlocksPreviousRender() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "stale")
        readiness.start()

        let state = presentationState(readiness: readiness)

        #expect(state.isAwaitingLayout)
        #expect(!(state.canUseRenderedLayout))
        #expect(state.shouldObscureRenderedLayout)
    }

    @Test
    func testCancelledSameLayoutKeepsRenderedLayoutUsable() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()
        readiness.cancel()

        let state = presentationState(readiness: readiness)

        #expect(!(state.isAwaitingLayout))
        #expect(state.canUseRenderedLayout)
        #expect(!(state.shouldObscureRenderedLayout))
    }

    @Test
    func testSemanticFailureObscuresStaleRenderedLayout() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "stale")
        readiness.start()
        readiness.fail(
            ChartLayoutFailure(error: TestLayoutError.failed),
            layoutID: "current"
        )

        let state = presentationState(readiness: readiness)

        #expect(!(state.isAwaitingLayout))
        #expect(!(state.canUseRenderedLayout))
        #expect(state.shouldObscureRenderedLayout)
        #expect(state.showsFailure)
    }

    @Test
    func testSameLayoutFailureKeepsRenderedLayoutUsable() {
        var readiness = ChartLayoutReadiness()
        readiness.succeed(layoutID: "current")
        readiness.start()
        readiness.fail(
            ChartLayoutFailure(error: TestLayoutError.failed),
            layoutID: "current"
        )

        let state = presentationState(readiness: readiness)

        #expect(!(state.isAwaitingLayout))
        #expect(state.canUseRenderedLayout)
        #expect(!(state.shouldObscureRenderedLayout))
        #expect(state.showsFailure)
    }

    private func presentationState(
        readiness: ChartLayoutReadiness
    ) -> ChartLayoutPresentationState {
        ChartLayoutPresentationState(
            readiness: readiness,
            layoutID: "current"
        )
    }
}

private enum TestLayoutError: Error {
    case failed
}
