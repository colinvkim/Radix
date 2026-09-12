import CoreGraphics
import Foundation
import Testing

@testable import RadixCore

struct TreemapGeometryTests {
    @Test
    func testTopLevelTilesFillBoundsProportionallyWithoutOverlap() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 75)
        let small = makeTestFileNode(id: "/root/small", name: "small", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large, small])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large, small]])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 400, height: 200),
            minimumTileArea: 1
        )

        #expect(segments.count == 2)
        let areaByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.rect.area) })
        #expect(abs((areaByID[large.id] ?? 0) - (0.75)) <= 0.000_001)
        #expect(abs((areaByID[small.id] ?? 0) - (0.25)) <= 0.000_001)
        #expect(abs((segments.reduce(0) { $0 + $1.rect.area }) - (1)) <= 0.000_001)
        #expect(segments[0].rect.intersection(segments[1].rect).area < 0.000_001)
    }

    @Test
    func testNestedDirectoryReservesHeaderAndContainsDescendantTiles() throws {
        let nestedA = makeTestFileNode(id: "/root/folder/a", name: "a", size: 60)
        let nestedB = makeTestFileNode(id: "/root/folder/b", name: "b", size: 40)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [nestedA, nestedB]
        )
        let sibling = makeTestFileNode(id: "/root/sibling", name: "sibling", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [nestedA, nestedB],
            ]
        )

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: CGSize(width: 800, height: 400),
            minimumTileArea: 1
        )

        let folderSegment = try #require(segments.first { $0.id == folder.id })
        let firstChildSegment = try #require(segments.first { $0.id == nestedA.id })
        let secondChildSegment = try #require(segments.first { $0.id == nestedB.id })

        #expect(folderSegment.showsContainerHeader)
        #expect(firstChildSegment.depth == 1)
        #expect(secondChildSegment.depth == 1)
        #expect(folderSegment.rect.contains(firstChildSegment.rect))
        #expect(folderSegment.rect.contains(secondChildSegment.rect))
        #expect(firstChildSegment.rect.minY > folderSegment.rect.minY)
        #expect(secondChildSegment.rect.minY > folderSegment.rect.minY)
    }

    @Test
    func testSmallSiblingsCollapseIntoAggregateTile() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let smallNodes = (0..<4).map {
            makeTestFileNode(id: "/root/small-\($0)", name: "small-\($0)", size: 1)
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large] + smallNodes)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large] + smallNodes])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )

        #expect(segments.count == 2)
        let aggregate = segments.first { $0.isAggregate }
        #expect(aggregate?.label == "Smaller Items")
        #expect(aggregate?.totalSize == 4)
        #expect(aggregate?.groupedItemCount == 4)
        #expect(aggregate?.nodeID == nil)
    }

    @Test
    func testAggregateSizeDoesNotCountZeroByteLayoutWeightsAsDiskUsage() throws {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let empty = (0..<3).map {
            makeTestFileNode(id: "/root/empty-\($0)", name: "empty-\($0)", size: 0)
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large] + empty)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large] + empty])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )

        let aggregateValue = (segments.first(where: \.isAggregate))
        let aggregate = try #require(aggregateValue)
        #expect(aggregate.totalSize == 0)
        #expect(aggregate.groupedItemCount == 3)
    }

    @Test
    func testAggregateTileIsSortedBySizeBeforeSquarification() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let medium = makeTestFileNode(id: "/root/medium", name: "medium", size: 100)
        let smallNodes = (0..<200).map {
            makeTestFileNode(id: "/root/small-\($0)", name: "small-\($0)", size: 1)
        }
        let children = [large, medium] + smallNodes
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 1_000, height: 1_000)
        )

        #expect(segments.map(\.id) == [large.id, "treemap-aggregate-\(root.id)", medium.id])
    }

    @Test
    func testHitTestingPrefersDeepestContainingTile() throws {
        let nested = makeTestFileNode(id: "/root/folder/nested", name: "nested", size: 100)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [folder], folder.id: [nested]]
        )
        let size = CGSize(width: 600, height: 300)
        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: size,
            minimumTileArea: 1
        )
        let nestedSegment = try #require(segments.first { $0.id == nested.id })
        let point = CGPoint(
            x: nestedSegment.rect.midX * size.width,
            y: nestedSegment.rect.midY * size.height
        )

        let hit = TreemapHitTestIndex(segments: segments).segment(at: point, in: size)

        #expect(hit?.id == nested.id)
    }

    @Test
    func testHitTestingLeavesStructuralGuttersUnassigned() {
        let left = makeTreemapSegment(
            id: "left",
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let right = makeTreemapSegment(
            id: "right",
            rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        )
        let size = CGSize(width: 600, height: 300)
        let index = TreemapHitTestIndex(segments: [left, right])

        #expect(index.segment(at: CGPoint(x: 300, y: 150), in: size) == nil)
    }

    @Test
    func testRendererMapsSegmentIntoOffsetContentFrame() {
        let segment = makeTreemapSegment(
            id: "mapped",
            rect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)
        )
        let contentFrame = CGRect(x: -100, y: 50, width: 800, height: 400)

        #expect(TreemapRenderer.rect(for: segment, in: contentFrame) == CGRect(x: 100, y: 130, width: 400, height: 160))
        #expect(
            TreemapRenderer.displayRect(for: segment, in: contentFrame)
                == CGRect(x: 100.75, y: 130.75, width: 398.5, height: 158.5))
    }

    @Test
    func testTransformedPointerHitsRenderedSegment() throws {
        let parent = makeTreemapSegment(
            id: "parent",
            rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let child = makeTreemapSegment(
            id: "child",
            rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            depth: 1,
            containerNodeID: parent.id
        )
        let baseFrame = CGRect(x: 20, y: 30, width: 400, height: 200)
        let transform = ChartViewportTransform(
            scale: 2,
            offset: CGSize(width: -50, height: 20)
        )
        let contentFrame = transform.frame(for: baseFrame)
        let renderedRect = TreemapRenderer.displayRect(
            for: child,
            in: contentFrame
        )
        let pointer = CGPoint(x: renderedRect.midX, y: renderedRect.midY)
        let chartPoint = try #require(transform.localChartPoint(for: pointer, in: baseFrame))

        #expect(baseFrame.contains(pointer))
        #expect(
            TreemapHitTestIndex(segments: [parent, child]).segment(
                at: chartPoint.point,
                in: chartPoint.size
            )?.id == child.id)
    }

    @Test
    func testHitTestingMatchesRenderedRectsAcrossFractionalChartSize() {
        let segments = [
            makeTreemapSegment(id: "left", rect: CGRect(x: 0, y: 0, width: 0.6, height: 1)),
            makeTreemapSegment(id: "right", rect: CGRect(x: 0.6, y: 0, width: 0.4, height: 1)),
        ]
        let size = CGSize(width: 617.5, height: 293.25)
        let index = TreemapHitTestIndex(segments: segments)

        for x in stride(from: CGFloat(0.25), to: size.width, by: 3.75) {
            for y in stride(from: CGFloat(0.25), to: size.height, by: 4.5) {
                let point = CGPoint(x: x, y: y)
                let expected = segments.last { segment in
                    TreemapRenderer.displayRect(for: segment, in: size).contains(point)
                }
                #expect(
                    index.segment(at: point, in: size)?.id == expected?.id,
                    "Hit-test mismatch at (\(point.x), \(point.y))")
            }
        }
    }

    @Test
    func testSmallTilesDoNotProduceAnOutOfBoundsSelectionStrokeRect() {
        let segment = makeTreemapSegment(
            id: "tiny",
            rect: CGRect(x: 0, y: 0, width: 0.004, height: 1)
        )
        let size = CGSize(width: 500, height: 300)

        #expect(
            TreemapRenderer.strokeRect(
                for: segment,
                in: size,
                lineWidth: 2.75
            ) == nil)
    }

    @Test
    func testDescendantsKeepTopLevelBranchColorFamily() throws {
        let nested = makeTestFileNode(id: "/root/folder/nested", name: "nested", size: 100)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [folder], folder.id: [nested]]
        )

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: CGSize(width: 600, height: 300),
            minimumTileArea: 1
        )
        let folderSegment = try #require(segments.first { $0.id == folder.id })
        let nestedSegment = try #require(segments.first { $0.id == nested.id })

        #expect(folderSegment.colorToken.branchID == folder.id)
        #expect(nestedSegment.colorToken.branchID == folder.id)
        #expect(folderSegment.colorToken.localID != nestedSegment.colorToken.localID)
    }

    @Test
    func testFocusedLayoutPreservesGlobalBranchAndSiblingColorIdentity() throws {
        let first = makeTestFileNode(id: "/root/folder/first", name: "first", size: 200)
        let second = makeTestFileNode(id: "/root/folder/second", name: "second", size: 100)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [first, second]
        )
        let sibling = makeTestFileNode(id: "/root/sibling", name: "sibling", size: 100)
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [folder, sibling]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [first, second],
            ]
        )
        let size = CGSize(width: 1_200, height: 600)
        let rootSegments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 2,
            size: size,
            minimumTileArea: 1
        )
        let focusedSegments = TreemapLayout.segments(
            in: store,
            rootID: folder.id,
            depthLimit: 1,
            size: size,
            minimumTileArea: 1
        )
        let rootToken = try #require(rootSegments.first { $0.nodeID == first.id }?.colorToken)
        let focusedToken = try #require(focusedSegments.first { $0.nodeID == first.id }?.colorToken)

        #expect(focusedToken.branchID == rootToken.branchID)
        #expect(focusedToken.branchIndex == rootToken.branchIndex)
        #expect(focusedToken.branchCount == rootToken.branchCount)
        #expect(focusedToken.localID == rootToken.localID)
        #expect(focusedToken.siblingIndex == rootToken.siblingIndex)
        #expect(focusedToken.siblingCount == rootToken.siblingCount)
        #expect(focusedToken.role == rootToken.role)
    }

    @Test
    func testGroupedRootPreservesGlobalColorIndexForVisibleBranches() throws {
        let groupedA = makeTestFileNode(
            id: "/root/grouped-a",
            name: "grouped-a",
            size: 1
        )
        let groupedB = makeTestFileNode(
            id: "/root/grouped-b",
            name: "grouped-b",
            size: 1
        )
        let visible = makeTestFileNode(
            id: "/root/visible",
            name: "visible",
            size: 999
        )
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [groupedA, groupedB, visible]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [groupedA, groupedB, visible]]
        )

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 100, height: 100),
            minimumTileArea: 20
        )
        let visibleToken = try #require(segments.first { $0.nodeID == visible.id }?.colorToken)

        #expect(visibleToken.branchID == visible.id)
        #expect(visibleToken.branchIndex == 0)
        #expect(visibleToken.branchCount == 3)
    }

    @Test
    func testLayoutStopsWhenCancellationCheckThrows() throws {
        let children = (0..<100).map {
            makeTestFileNode(id: "/root/\($0)", name: "\($0)", size: Int64(100 - $0))
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        var checks = 0

        #expect(throws: (any Error).self) {
            try TreemapLayout.segments(
                in: store,
                rootID: root.id,
                depthLimit: 3,
                size: CGSize(width: 800, height: 400),
                cancellationCheck: {
                    checks += 1
                    if checks > 4 { throw CancellationError() }
                }
            )
        }
    }

    @Test
    func testTinyDirectoryTileDoesNotReadUnrenderableChildren() throws {
        let file = makeTestFileNode(id: "/root/folder/file", name: "file", size: 100)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [file])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder])
        let tree = ChartReadProbe(FileTreeStore(root: root, childrenByID: [root.id: [folder], folder.id: [file]]))

        let segments = try TreemapLayout.segments(
            in: tree, rootID: root.id, depthLimit: 3, size: CGSize(width: 40, height: 40),
            cancellationCheck: {}
        )
        #expect(segments.count == 1)
        let tile = try #require(segments.first)
        #expect(tile.nodeID == folder.id)
        #expect(tile.isDirectory)
        #expect(!(tile.showsContainerHeader))
        #expect(tile.rect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(tree.childReadCount(for: folder.id) == 0)
        #expect(tree.projectedNodeCount == 1)
    }
}

private func makeTreemapSegment(
    id: String,
    rect: CGRect,
    depth: Int = 0,
    containerNodeID: String = "/root"
) -> TreemapSegment {
    TreemapSegment(
        id: id,
        nodeID: id,
        containerNodeID: containerNodeID,
        label: id,
        rect: rect,
        depth: depth,
        colorToken: .single(id: id),
        totalSize: 1,
        isAggregate: false,
        groupedItemCount: nil,
        isDirectory: false,
        showsContainerHeader: false
    )
}

extension CGRect {
    fileprivate var area: CGFloat {
        isNull || isInfinite ? 0 : max(width, 0) * max(height, 0)
    }
}
