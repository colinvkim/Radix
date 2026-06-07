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
