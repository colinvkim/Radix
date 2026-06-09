import XCTest
@testable import RadixCore

final class SunburstGeometryTests: XCTestCase {
    func testTopLevelSegmentsCoverFullCircle() {
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [
                makeFileNode(id: "/root/a", name: "a", size: 3),
                makeFileNode(id: "/root/b", name: "b", size: 1)
            ]
        )
        let store = makeStore(root: root, children: [
            makeFileNode(id: "/root/a", name: "a", size: 3),
            makeFileNode(id: "/root/b", name: "b", size: 1),
        ])

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle.radians - segment.startAngle.radians)
        }

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(totalRadians, .pi * 2, accuracy: 0.0001)
    }

    func testSmallItemsCollapseIntoAggregateSegment() throws {
        let children = [
            makeFileNode(id: "/root/large", name: "large", size: 100),
            makeFileNode(id: "/root/tiny-1", name: "tiny-1", size: 1),
            makeFileNode(id: "/root/tiny-2", name: "tiny-2", size: 1),
            makeFileNode(id: "/root/tiny-3", name: "tiny-3", size: 1)
        ]
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1, minimumAngle: .pi / 2)
        let aggregate = try XCTUnwrap(segments.first(where: { $0.isAggregate }))

        XCTAssertNil(aggregate.nodeID)
        XCTAssertEqual(aggregate.label, "Smaller Items")
        XCTAssertEqual(aggregate.totalSize, 3)
    }

    func testHitTesterReturnsExpectedSegment() throws {
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [
                makeFileNode(id: "/root/a", name: "a", size: 1),
                makeFileNode(id: "/root/b", name: "b", size: 1)
            ]
        )
        let store = makeStore(root: root, children: [
            makeFileNode(id: "/root/a", name: "a", size: 1),
            makeFileNode(id: "/root/b", name: "b", size: 1),
        ])

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let firstSegment = try XCTUnwrap(segments.first)
        let size = CGSize(width: 300, height: 300)
        let hitPoint = pointInside(segment: firstSegment, in: size)

        XCTAssertEqual(SunburstHitTester.segment(at: hitPoint, in: size, segments: segments)?.id, firstSegment.id)
    }

    func testHitTestIndexFindsSegmentInMatchingRing() throws {
        let size = CGSize(width: 300, height: 300)
        let innerRing = makeSegment(id: "inner", innerRadius: 0.1, outerRadius: 0.3, depth: 0)
        let outerRing = makeSegment(id: "outer", innerRadius: 0.45, outerRadius: 0.8, depth: 1)
        let index = SunburstHitTestIndex(segments: [innerRing, outerRing])

        XCTAssertEqual(index.segment(at: pointInRing(radius: 0.2, in: size), in: size)?.id, innerRing.id)
        XCTAssertEqual(index.segment(at: pointInRing(radius: 0.6, in: size), in: size)?.id, outerRing.id)
        XCTAssertNil(index.segment(at: pointInRing(radius: 0.38, in: size), in: size))
    }

    func testHitTestIndexFindsAngleInUnsortedRing() throws {
        let size = CGSize(width: 300, height: 300)
        let first = makeSegment(id: "first", startAngle: 0, endAngle: .pi, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let second = makeSegment(id: "second", startAngle: .pi, endAngle: .pi * 2, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let index = SunburstHitTestIndex(segments: [second, first])

        XCTAssertEqual(index.segment(at: pointInside(segment: second, in: size), in: size)?.id, second.id)
    }

    func testStablePaletteIndexIsDeterministicAndBounded() {
        XCTAssertEqual(StablePaletteIndex.index(for: "/root/Documents", count: 6), 3)
        XCTAssertEqual(StablePaletteIndex.index(for: "/root/Documents", count: 1), 0)
        XCTAssertEqual(StablePaletteIndex.index(for: "/root/Documents", count: 0), 0)
    }

    func testLayoutStopsWhenCancellationCheckThrows() throws {
        let children = (0..<100).map { index in
            makeFileNode(id: "/root/file-\(index)", name: "file-\(index)", size: 1)
        }
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try SunburstLayout.segments(
                in: store,
                rootID: root.id,
                depthLimit: 2,
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 4 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 4)
    }
}

private func pointInside(segment: SunburstSegment, in size: CGSize) -> CGPoint {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let maxRadius = min(size.width, size.height) / 2
    let radius = maxRadius * ((segment.innerRadius + segment.outerRadius) / 2)
    let angle = ((segment.startAngle.radians + segment.endAngle.radians) / 2) - (.pi / 2)

    return CGPoint(
        x: center.x + (cos(angle) * radius),
        y: center.y + (sin(angle) * radius)
    )
}

private func pointInRing(radius normalizedRadius: CGFloat, in size: CGSize) -> CGPoint {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let maxRadius = min(size.width, size.height) / 2
    return CGPoint(x: center.x, y: center.y - (normalizedRadius * maxRadius))
}

private func makeSegment(
    id: String,
    startAngle: Double = 0,
    endAngle: Double = .pi * 2,
    innerRadius: CGFloat,
    outerRadius: CGFloat,
    depth: Int
) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: .radians(startAngle),
        endAngle: .radians(endAngle),
        innerRadius: innerRadius,
        outerRadius: outerRadius,
        depth: depth,
        colorKey: id,
        totalSize: 1,
        isAggregate: false
    )
}

private func makeStore(root: FileNodeRecord, children: [FileNodeRecord]) -> FileTreeStore {
    FileTreeStore(root: root, childrenByID: [root.id: children])
}

private func makeFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeDirectoryNode(id: String, name: String, children: [FileNodeRecord]) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        descendantFileCount: children.reduce(0) { $0 + ($1.isDirectory ? $1.descendantFileCount : 1) },
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
