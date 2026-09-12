import CoreGraphics
import Foundation
import Testing

@testable import RadixCore

struct ChartRectangleSpatialSelectionTests {
    @Test
    func testRectangleNavigationUsesVisibleEdgeDistance() {
        let candidates = [
            rectangleCandidate("current", x: 90, y: 0, width: 10, height: 100),
            rectangleCandidate("adjacent-header", x: 0, y: 0, width: 88, height: 10),
            rectangleCandidate("distant-center", x: 50, y: 49, width: 10, height: 2),
        ]

        #expect(nextRectangle(from: "current", moving: .left, among: candidates) == "adjacent-header")
    }

    @Test
    func testRectangleNavigationDoesNotTreatContainingOrContainedTileAsSideways() {
        let candidates = [
            rectangleCandidate("current", x: 20, y: 0, width: 10, height: 10),
            rectangleCandidate("containing", x: 0, y: 0, width: 100, height: 10),
            rectangleCandidate("child-below", x: 20, y: 10, width: 10, height: 10),
            rectangleCandidate("right", x: 40, y: 0, width: 10, height: 10),
        ]

        #expect(nextRectangle(from: "current", moving: .right, among: candidates) == "right")
        #expect(nextRectangle(from: "current", moving: .down, among: candidates) == "child-below")
    }

    @Test
    func testRectangleNavigationReturnsNilAtDirectionalEdge() {
        let candidates = [
            rectangleCandidate("left", x: 20, y: 20, width: 10, height: 10),
            rectangleCandidate("right", x: 40, y: 20, width: 10, height: 10),
        ]

        #expect(nextRectangle(from: "right", moving: .right, among: candidates) == nil)
    }

    private func nextRectangle(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        among candidates: [ChartRectangleSelectionCandidate]
    ) -> String? {
        ChartRectangleSpatialSelection.nextNodeID(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )
    }

    private func rectangleCandidate(
        _ nodeID: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> ChartRectangleSelectionCandidate {
        ChartRectangleSelectionCandidate(
            nodeID: nodeID,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
