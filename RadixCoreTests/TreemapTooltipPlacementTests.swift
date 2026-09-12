import CoreGraphics
import Foundation
import Testing

@testable import RadixCore

struct TreemapTooltipPlacementTests {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let tooltipSize = CGSize(width: 200, height: 80)

    @Test(arguments: [
        (CGPoint(x: 100, y: 100), CGPoint(x: 114, y: 114)),
        (CGPoint(x: 580, y: 100), CGPoint(x: 366, y: 114)),
        (CGPoint(x: 100, y: 380), CGPoint(x: 114, y: 286)),
    ])
    func testPlacesTooltipBesidePointerAndFlipsAtEdges(pointer: CGPoint, expected: CGPoint) {
        #expect(TreemapTooltipPlacement.origin(for: pointer, tooltipSize: tooltipSize, in: bounds) == expected)
    }

    @Test
    func testClampsOversizedTooltipToBoundsMargin() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 10, y: 10),
            tooltipSize: CGSize(width: 800, height: 500),
            in: bounds
        )

        #expect(origin == CGPoint(x: 8, y: 8))
    }

    @Test
    func testTinyBoundsDoNotProduceAnInvertedPlacementArea() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 5, y: 4),
            tooltipSize: tooltipSize,
            in: CGRect(x: 0, y: 0, width: 10, height: 8)
        )

        #expect(origin == CGPoint(x: 5, y: 4))
    }

    @Test
    func testAvoidsViewportControlsWhenAlternatePlacementIsAvailable() {
        let origin = TreemapTooltipPlacement.origin(
            for: CGPoint(x: 350, y: 20),
            tooltipSize: tooltipSize,
            in: bounds,
            avoiding: CGRect(x: 440, y: 0, width: 160, height: 56)
        )

        #expect(origin == CGPoint(x: 136, y: 34))
        #expect(
            !(CGRect(origin: origin, size: tooltipSize)
                .intersects(CGRect(x: 440, y: 0, width: 160, height: 56))))
    }
}
