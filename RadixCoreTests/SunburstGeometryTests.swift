import Foundation
import Testing

@testable import RadixCore

struct SunburstGeometryTests {
    @Test
    func testTopLevelSegmentsCoverFullCircle() {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 1),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle.radians - segment.startAngle.radians)
        }

        #expect(segments.count == 2)
        #expect(abs((totalRadians) - (.pi * 2)) <= 0.0001)
    }

    @Test
    func testMixedZeroByteChildrenDoNotOverflowParentArc() throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 10),
            makeTestFileNode(id: "/root/empty-1", name: "empty-1", size: 0),
            makeTestFileNode(id: "/root/empty-2", name: "empty-2", size: 0),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle.radians - segment.startAngle.radians)
        }
        let lastSegment = try #require(segments.last)

        #expect(segments.count == 3)
        #expect(abs((totalRadians) - (.pi * 2)) <= 0.0001)
        #expect(lastSegment.endAngle.radians <= .pi * 2 + 0.0001)
    }

    @Test
    func testSaturatedChildrenStayWithinParentArc() throws {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: .max),
            makeTestFileNode(id: "/root/b", name: "b", size: .max),
        ]
        let root = FileNodeRecord(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: .max,
            logicalSize: .max,
            descendantFileCount: children.count,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let totalRadians = segments.reduce(0.0) {
            $0 + ($1.endAngle.radians - $1.startAngle.radians)
        }
        let lastSegment = try #require(segments.last)

        #expect(segments.count == 2)
        #expect(abs((totalRadians) - (.pi * 2)) <= 0.0001)
        #expect(lastSegment.endAngle.radians <= .pi * 2 + 0.0001)
        #expect(
            segments.allSatisfy {
                $0.startAngle.radians.isFinite && $0.endAngle.radians.isFinite
            })
    }

    @Test(arguments: [Int64(0), 1])
    func testSmallItemsCollapseIntoAggregateSegment(smallSize: Int64) throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 100),
            makeTestFileNode(id: "/root/tiny-1", name: "tiny-1", size: smallSize),
            makeTestFileNode(id: "/root/tiny-2", name: "tiny-2", size: smallSize),
            makeTestFileNode(id: "/root/tiny-3", name: "tiny-3", size: smallSize),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1, minimumAngle: .pi / 2)
        let aggregate = try #require(segments.first(where: { $0.isAggregate }))

        #expect(aggregate.nodeID == nil)
        #expect(aggregate.label == "Smaller Items")
        #expect(aggregate.totalSize == 3 * smallSize)
        #expect(aggregate.colorToken.role == .aggregate)
        #expect(segments.count == 2)
        #expect(abs(aggregate.endAngle.radians - aggregate.startAngle.radians - (.pi * 2 * 3 / 103)) < 0.0001)
    }

    @Test
    func testSingleSmallItemRemainsAnIndividualSegment() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 99)
        let small = makeTestFileNode(id: "/root/small", name: "small", size: 1)
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [large, small]
        )
        let store = makeStore(root: root, children: [large, small])

        let segments = SunburstLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            minimumAngle: .pi / 2
        )

        #expect(segments.count == 2)
        #expect(!segments.contains { $0.isAggregate })
        #expect(segments.last?.nodeID == small.id)
        #expect(segments.last?.totalSize == small.allocatedSize)
    }

    @Test
    func testHitTesterReturnsExpectedSegment() throws {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 1),
            makeTestFileNode(id: "/root/b", name: "b", size: 1),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let firstSegment = try #require(segments.first)
        let size = CGSize(width: 300, height: 300)
        let hitPoint = pointInside(segment: firstSegment, in: size)

        #expect(SunburstHitTestIndex(segments: segments).segment(at: hitPoint, in: size)?.id == firstSegment.id)
    }

    @Test
    func testCenterHitTesterMatchesLayoutHole() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 1)]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)
        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let firstSegment = try #require(segments.first)
        let size = CGSize(width: 300, height: 300)

        #expect(firstSegment.innerRadius == SunburstLayout.centerRadius)
        #expect(SunburstCenterHitTester.contains(point: CGPoint(x: 150, y: 150), in: size))
        #expect(SunburstCenterHitTester.contains(point: pointInRing(radius: 0.21, in: size), in: size))
        #expect(!(SunburstCenterHitTester.contains(point: pointInRing(radius: 0.23, in: size), in: size)))
        #expect(SunburstHitTestIndex(segments: segments).segment(at: CGPoint(x: 150, y: 150), in: size) == nil)
    }

    @Test
    func testHitTestIndexFindsSegmentInMatchingRing() {
        let size = CGSize(width: 300, height: 300)
        let innerRing = makeSegment(id: "inner", innerRadius: 0.1, outerRadius: 0.3, depth: 0)
        let outerRing = makeSegment(id: "outer", innerRadius: 0.45, outerRadius: 0.8, depth: 1)
        let index = SunburstHitTestIndex(segments: [innerRing, outerRing])

        #expect(index.segment(at: pointInRing(radius: 0.2, in: size), in: size)?.id == innerRing.id)
        #expect(index.segment(at: pointInRing(radius: 0.6, in: size), in: size)?.id == outerRing.id)
        #expect(index.segment(at: pointInRing(radius: 0.38, in: size), in: size) == nil)
    }

    @Test
    func testHitTestIndexFindsAngleInUnsortedRing() {
        let size = CGSize(width: 300, height: 300)
        let first = makeSegment(id: "first", startAngle: 0, endAngle: .pi, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let second = makeSegment(
            id: "second", startAngle: .pi, endAngle: .pi * 2, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let index = SunburstHitTestIndex(segments: [second, first])

        #expect(index.segment(at: pointInside(segment: second, in: size), in: size)?.id == second.id)
    }

    @Test
    func testTopLevelSiblingColorTokensUseDistinctBranches() {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 2),
            makeTestFileNode(id: "/root/c", name: "c", size: 1),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let tokens = segments.map(\.colorToken)

        #expect(tokens.map(\.branchID) == ["/root/a", "/root/b", "/root/c"])
        #expect(tokens.map(\.branchIndex) == [0, 1, 2])
        #expect(tokens.map(\.branchCount) == [3, 3, 3])
        #expect(Set(tokens.map { SunburstColorResolver.components(for: $0) }).count == 3)
    }

    @Test
    func testBranchColorStaysStableWhenSiblingSortOrderChanges() throws {
        let firstStoreChildren = [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 2),
        ]
        let firstRoot = makeTestDirectoryNode(id: "/root", name: "root", children: firstStoreChildren)
        let firstStore = makeStore(root: firstRoot, children: firstStoreChildren)
        let secondStoreChildren = [
            makeTestFileNode(id: "/root/a", name: "a", size: 1),
            makeTestFileNode(id: "/root/b", name: "b", size: 4),
        ]
        let secondRoot = makeTestDirectoryNode(id: "/root", name: "root", children: secondStoreChildren)
        let secondStore = makeStore(root: secondRoot, children: secondStoreChildren)

        let firstSegment = try #require(
            SunburstLayout.segments(in: firstStore, rootID: firstRoot.id, depthLimit: 1)
                .first { $0.nodeID == "/root/a" })
        let secondSegment = try #require(
            SunburstLayout.segments(in: secondStore, rootID: secondRoot.id, depthLimit: 1)
                .first { $0.nodeID == "/root/a" })

        #expect(firstSegment.colorToken.branchIndex != secondSegment.colorToken.branchIndex)
        #expect(
            SunburstColorResolver.components(for: firstSegment.colorToken)
                == SunburstColorResolver.components(for: secondSegment.colorToken))
    }

    @Test
    func testChildColorTokensKeepBranchFamilyButVaryBySibling() {
        let children = [
            makeTestFileNode(id: "/root/a/one", name: "one", size: 3),
            makeTestFileNode(id: "/root/a/two", name: "two", size: 2),
            makeTestFileNode(id: "/root/a/three", name: "three", size: 1),
        ]
        let branch = makeTestDirectoryNode(id: "/root/a", name: "a", children: children)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branch])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [branch],
                branch.id: children,
            ])

        let segments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 2)
        let childTokens =
            segments
            .filter { $0.depth == 1 }
            .map(\.colorToken)

        #expect(childTokens.map(\.branchID) == Array(repeating: branch.id, count: 3))
        #expect(childTokens.map(\.siblingIndex) == [0, 1, 2])
        #expect(childTokens.map(\.siblingCount) == [3, 3, 3])
        #expect(Set(childTokens.map { SunburstColorResolver.components(for: $0) }).count == 3)
    }

    @Test
    func testFocusedSubtreeKeepsScanRootBranchFamily() throws {
        let nestedChildren = [
            makeTestFileNode(id: "/root/a/child-1", name: "child-1", size: 2),
            makeTestFileNode(id: "/root/a/child-2", name: "child-2", size: 1),
        ]
        let branchA = makeTestDirectoryNode(id: "/root/a", name: "a", children: nestedChildren)
        let branchB = makeTestFileNode(id: "/root/b", name: "b", size: 1)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branchA, branchB])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [branchA, branchB],
                branchA.id: nestedChildren,
            ])

        let rootSegments = SunburstLayout.segments(in: store, rootID: root.id, depthLimit: 1)
        let branchToken = try #require(rootSegments.first { $0.nodeID == branchA.id }).colorToken
        let focusedSegments = SunburstLayout.segments(in: store, rootID: branchA.id, depthLimit: 1)

        #expect(focusedSegments.map(\.colorToken.branchID) == [branchA.id, branchA.id])
        #expect(focusedSegments.map(\.colorToken.branchIndex) == [branchToken.branchIndex, branchToken.branchIndex])
        #expect(focusedSegments.map(\.colorToken.branchCount) == [branchToken.branchCount, branchToken.branchCount])
    }

    @Test
    func testLayoutStopsWhenCancellationCheckThrows() throws {
        let children = (0..<100).map { index in
            makeTestFileNode(id: "/root/file-\(index)", name: "file-\(index)", size: 1)
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = makeStore(root: root, children: children)
        var cancellationChecks = 0

        #expect(throws: CancellationError.self) {
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
        }
        #expect(cancellationChecks == 4)
    }

    @Test
    func testGroupedRootReusesChildrenAndPreservesGlobalColorPositions() throws {
        let children = [
            makeTestFileNode(id: "/root/visible", name: "visible", size: 999),
            makeTestFileNode(id: "/root/small-a", name: "small-a", size: 1),
            makeTestFileNode(id: "/root/small-b", name: "small-b", size: 1),
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let tree = ChartReadProbe(makeStore(root: root, children: children))

        let segments = try SunburstLayout.segments(
            in: tree, rootID: root.id, depthLimit: 1, cancellationCheck: {}
        )
        let visible = try #require(segments.first { $0.nodeID == children[0].id })
        #expect(visible.colorToken.branchIndex == 0)
        #expect(visible.colorToken.branchCount == 3)
        #expect(segments.count == 2)
        #expect(segments.contains { $0.isAggregate })
        #expect(tree.childReadCount(for: root.id) == 1)
        #expect(tree.projectedNodeCount == children.count)
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
        containerNodeID: "/root",
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
