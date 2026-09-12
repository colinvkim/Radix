import CoreGraphics
import Foundation
import Testing

@testable import RadixCore

struct TreemapTooltipContentTests {
    @Test
    func testFolderContentIncludesSignificanceLocationAndFileCount() throws {
        let first = makeTestFileNode(id: "/disk/Documents/first", name: "first", size: 300)
        let second = makeTestFileNode(id: "/disk/Documents/second", name: "second", size: 100)
        let documents = makeTestDirectoryNode(
            id: "/disk/Documents",
            name: "Documents",
            children: [first, second]
        )
        let other = makeTestFileNode(id: "/disk/other", name: "other", size: 600)
        let root = makeTestDirectoryNode(
            id: "/disk",
            name: "Macintosh HD",
            children: [documents, other]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [documents, other],
                documents.id: [first, second],
            ]
        )
        let segment = try #require(segments(in: store, root: root).first { $0.id == documents.id })

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        #expect(content.systemImageName == "folder.fill")
        #expect(content.title == "Documents")
        #expect(content.sizeAndSignificance.contains("40.0% of Macintosh HD"))
        #expect(content.location == "Macintosh HD")
        #expect(content.metadata == "2 files")
        #expect(content.status == nil)

        let queuedContent = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store,
            discardPileRole: .queuedRoot
        )
        #expect(queuedContent.status == "In Discard Pile")
        #expect(queuedContent.accessibilityDescription.contains("In Discard Pile"))
    }

    @Test
    func testFileContentIncludesParentPathAndModificationDate() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let report = makeTestFileNode(
            id: "/disk/Documents/Reports/annual.pdf",
            name: "annual.pdf",
            size: 100,
            lastModified: modified
        )
        let reports = makeTestDirectoryNode(
            id: "/disk/Documents/Reports",
            name: "Reports",
            children: [report]
        )
        let documents = makeTestDirectoryNode(
            id: "/disk/Documents",
            name: "Documents",
            children: [reports]
        )
        let other = makeTestFileNode(id: "/disk/other", name: "other", size: 900)
        let root = makeTestDirectoryNode(
            id: "/disk",
            name: "Macintosh HD",
            children: [documents, other]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [documents, other],
                documents.id: [reports],
                reports.id: [report],
            ]
        )
        let segment = try #require(segments(in: store, root: root).first { $0.id == report.id })

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        #expect(content.systemImageName == "doc.fill")
        #expect(content.title == "annual.pdf")
        #expect(content.sizeAndSignificance.contains("10.0% of Macintosh HD"))
        #expect(content.location == "Macintosh HD › Documents › Reports")
        #expect(content.metadata == "Modified \(RadixFormatters.date(modified))")
    }

    @Test
    func testAggregateContentIncludesContainerPathAndGroupedItemCount() throws {
        let large = makeTestFileNode(id: "/disk/Library/large", name: "large", size: 10_000)
        let small = (0..<4).map {
            makeTestFileNode(id: "/disk/Library/small-\($0)", name: "small-\($0)", size: 1)
        }
        let library = makeTestDirectoryNode(
            id: "/disk/Library",
            name: "Library",
            children: [large] + small
        )
        let root = makeTestDirectoryNode(id: "/disk", name: "Macintosh HD", children: [library])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [library], library.id: [large] + small]
        )
        let segmentValue = (segments(in: store, root: root).first(where: \.isAggregate))
        let segment = try #require(segmentValue)

        let content = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store
        )

        #expect(content.systemImageName == "square.grid.3x3.fill")
        #expect(content.title == "Smaller Items")
        #expect(content.location == "Macintosh HD › Library")
        #expect(content.metadata == "4 grouped items")

        let containingContent = TreemapTooltipContent.content(
            for: segment,
            rootNode: root,
            treeStore: store,
            discardPileRole: .containsQueuedItem
        )
        #expect(containingContent.status == "Contains Items in Discard Pile")
    }

    private func segments(
        in store: FileTreeStore,
        root: FileNodeRecord
    ) -> [TreemapSegment] {
        TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 4,
            size: CGSize(width: 800, height: 500),
            minimumTileArea: 120
        )
    }
}
