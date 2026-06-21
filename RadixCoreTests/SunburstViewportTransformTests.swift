import XCTest
@testable import RadixCore

final class SunburstViewportTransformTests: XCTestCase {
    func testZoomExpandsChartAroundBaseCenter() {
        let baseFrame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 2,
            anchor: nil,
            in: baseFrame
        )

        XCTAssertEqual(transform.scale, 2)
        XCTAssertEqual(transform.offset, .zero)
        XCTAssertEqual(transform.frame(for: baseFrame), CGRect(x: -90, y: -30, width: 400, height: 200))
    }

    func testZoomAroundAnchorKeepsAnchoredPointStable() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let anchor = CGPoint(x: 150, y: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 2,
            anchor: anchor,
            in: baseFrame
        )

        let localChartPoint = try XCTUnwrap(transform.localChartPoint(for: anchor, in: baseFrame))

        XCTAssertEqual(transform.offset, CGSize(width: -50, height: 0))
        XCTAssertEqual(localChartPoint.point, CGPoint(x: 300, y: 200))
        XCTAssertEqual(localChartPoint.size, CGSize(width: 400, height: 400))
    }

    func testPanOffsetIsConstrainedToKeepBaseFrameCovered() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(scale: 2).panned(
            by: CGSize(width: 500, height: -500),
            in: baseFrame
        )

        XCTAssertEqual(transform.offset, CGSize(width: 100, height: -50))
        XCTAssertTrue(transform.frame(for: baseFrame).contains(baseFrame))
    }

    func testConstrainedShrinksOffsetForSmallerFrame() {
        let smallerFrame = CGRect(x: 0, y: 0, width: 120, height: 80)
        let transform = SunburstViewportTransform(
            scale: 2,
            offset: CGSize(width: 100, height: -100)
        ).constrained(to: smallerFrame)

        XCTAssertEqual(transform.offset, CGSize(width: 60, height: -40))
        XCTAssertTrue(transform.frame(for: smallerFrame).contains(smallerFrame))
    }

    func testZoomOutToMinimumResetsOffset() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform(
            scale: 2,
            offset: CGSize(width: 40, height: -20)
        ).zoomed(
            by: 0.1,
            anchor: CGPoint(x: 50, y: 25),
            in: baseFrame
        )

        XCTAssertEqual(transform, .identity)
    }

    func testZoomRespectsCustomMaximumScale() {
        let baseFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let transform = SunburstViewportTransform().zoomed(
            by: 4,
            anchor: nil,
            in: baseFrame,
            maximumScale: 2
        )

        XCTAssertEqual(transform.scale, 2)
    }
}
