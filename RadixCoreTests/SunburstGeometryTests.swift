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

    func testMixedZeroByteChildrenDoNotOverflowParentArc() throws {
        let children = [
            makeFileNode(id: "/root/large", name: "large", size: 10),
            makeFileNode(id: "/root/empty-1", name: "empty-1", size: 0),
            makeFileNode(id: "/root/empty-2", name: "empty-2", size: 0),
        ]
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle.radians - segment.startAngle.radians)
        }
        let lastSegment = try XCTUnwrap(segments.last)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(totalRadians, .pi * 2, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(lastSegment.endAngle.radians, .pi * 2 + 0.0001)
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
        XCTAssertEqual(aggregate.colorToken.role, .aggregate)
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

    func testCenterHitTesterMatchesLayoutHole() throws {
        let root = makeDirectoryNode(
            id: "/root",
            name: "root",
            children: [
                makeFileNode(id: "/root/a", name: "a", size: 1)
            ]
        )
        let store = makeStore(root: root, children: [
            makeFileNode(id: "/root/a", name: "a", size: 1),
        ])
        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let firstSegment = try XCTUnwrap(segments.first)
        let size = CGSize(width: 300, height: 300)

        XCTAssertEqual(firstSegment.innerRadius, SunburstLayout.centerRadius)
        XCTAssertTrue(SunburstCenterHitTester.contains(point: CGPoint(x: 150, y: 150), in: size))
        XCTAssertTrue(SunburstCenterHitTester.contains(point: pointInRing(radius: 0.21, in: size), in: size))
        XCTAssertFalse(SunburstCenterHitTester.contains(point: pointInRing(radius: 0.23, in: size), in: size))
        XCTAssertNil(SunburstHitTester.segment(at: CGPoint(x: 150, y: 150), in: size, segments: segments))
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

    func testTopLevelSiblingColorTokensUseDistinctBranches() throws {
        let children = [
            makeFileNode(id: "/root/a", name: "a", size: 3),
            makeFileNode(id: "/root/b", name: "b", size: 2),
            makeFileNode(id: "/root/c", name: "c", size: 1)
        ]
        let root = makeDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let tokens = segments.map(\.colorToken)

        XCTAssertEqual(tokens.map(\.branchID), ["/root/a", "/root/b", "/root/c"])
        XCTAssertEqual(tokens.map(\.branchIndex), [0, 1, 2])
        XCTAssertEqual(tokens.map(\.branchCount), [3, 3, 3])
        XCTAssertEqual(Set(tokens.map { SunburstColorResolver.components(for: $0) }).count, 3)
    }

    func testBranchColorStaysStableWhenSiblingSortOrderChanges() throws {
        let firstStoreChildren = [
            makeFileNode(id: "/root/a", name: "a", size: 3),
            makeFileNode(id: "/root/b", name: "b", size: 2)
        ]
        let firstRoot = makeDirectoryNode(id: "/root", name: "root", children: firstStoreChildren)
        let firstStore = makeStore(root: firstRoot, children: firstStoreChildren)
        let secondStoreChildren = [
            makeFileNode(id: "/root/a", name: "a", size: 1),
            makeFileNode(id: "/root/b", name: "b", size: 4)
        ]
        let secondRoot = makeDirectoryNode(id: "/root", name: "root", children: secondStoreChildren)
        let secondStore = makeStore(root: secondRoot, children: secondStoreChildren)

        let firstSegment = try XCTUnwrap(
            SunburstLayout.segments(in: firstStore, rootID: firstRoot.id, depthLimit: 1)
                .first { $0.nodeID == "/root/a" }
        )
        let secondSegment = try XCTUnwrap(
            SunburstLayout.segments(in: secondStore, rootID: secondRoot.id, depthLimit: 1)
                .first { $0.nodeID == "/root/a" }
        )

        XCTAssertNotEqual(firstSegment.colorToken.branchIndex, secondSegment.colorToken.branchIndex)
        XCTAssertEqual(
            SunburstColorResolver.components(for: firstSegment.colorToken),
            SunburstColorResolver.components(for: secondSegment.colorToken)
        )
    }

    func testChildColorTokensKeepBranchFamilyButVaryBySibling() throws {
        let children = [
            makeFileNode(id: "/root/a/one", name: "one", size: 3),
            makeFileNode(id: "/root/a/two", name: "two", size: 2),
            makeFileNode(id: "/root/a/three", name: "three", size: 1)
        ]
        let branch = makeDirectoryNode(id: "/root/a", name: "a", children: children)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [branch])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [branch],
            branch.id: children
        ])

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 2)
        let childTokens = segments
            .filter { $0.depth == 1 }
            .map(\.colorToken)

        XCTAssertEqual(childTokens.map(\.branchID), Array(repeating: branch.id, count: 3))
        XCTAssertEqual(childTokens.map(\.siblingIndex), [0, 1, 2])
        XCTAssertEqual(childTokens.map(\.siblingCount), [3, 3, 3])
        XCTAssertEqual(Set(childTokens.map { SunburstColorResolver.components(for: $0) }).count, 3)
    }

    func testFocusedSubtreeKeepsScanRootBranchFamily() throws {
        let nestedChildren = [
            makeFileNode(id: "/root/a/child-1", name: "child-1", size: 2),
            makeFileNode(id: "/root/a/child-2", name: "child-2", size: 1)
        ]
        let branchA = makeDirectoryNode(id: "/root/a", name: "a", children: nestedChildren)
        let branchB = makeFileNode(id: "/root/b", name: "b", size: 1)
        let root = makeDirectoryNode(id: "/root", name: "root", children: [branchA, branchB])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [branchA, branchB],
            branchA.id: nestedChildren
        ])

        let rootSegments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let branchToken = try XCTUnwrap(rootSegments.first { $0.nodeID == branchA.id }).colorToken
        let focusedSegments = SunburstLayout.segments(in: store, rootID: branchA.id, depthLimit: 1)

        XCTAssertEqual(focusedSegments.map(\.colorToken.branchID), [branchA.id, branchA.id])
        XCTAssertEqual(focusedSegments.map(\.colorToken.branchIndex), [branchToken.branchIndex, branchToken.branchIndex])
        XCTAssertEqual(focusedSegments.map(\.colorToken.branchCount), [branchToken.branchCount, branchToken.branchCount])
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
        colorToken: .single(id: id, depth: depth),
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
        isSelfAccessible: true,
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
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}
