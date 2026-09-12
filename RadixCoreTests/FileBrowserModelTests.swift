import Combine
import Foundation
import Testing

@testable import RadixCore

extension FileBrowserModel {
    @MainActor
    fileprivate func setActiveSearchText(_ text: String) {
        var query = activeQuery
        query.text = text
        setActiveQuery(query)
    }
}

struct FileBrowserModelTests {
    @MainActor
    @Test
    func testCurrentContentsSortsFiltersAndFindsDisplayedNodes() {
        let small = makeTestFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeTestFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let nested = makeTestFileNode(id: "/root/Folder/nested.txt", name: "nested.txt", size: 20)
        let folder = makeTestDirectoryNode(id: "/root/Folder", name: "Folder", children: [nested])
        let model = FileBrowserModel()

        model.updateContent(
            nodes: [small, large, folder],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        #expect(model.displayedNodes.map(\.id) == [large.id, folder.id, small.id])
        #expect(model.displayedNode(id: large.id)?.name == "large.log")

        model.setActiveSearchText("small")
        #expect(model.displayedNodes.map(\.id) == [small.id])

        model.setActiveSearchText("")
        model.setSortOrder([FileNodeTableComparator(field: .name)])
        #expect(model.displayedNodes.map(\.id) == [folder.id, large.id, small.id])
    }

    @MainActor
    @Test
    func testCurrentContentsRefreshesRowsWhenIDsStayTheSame() {
        let small = makeTestFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeTestFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let model = FileBrowserModel()

        model.updateContent(
            nodes: [small, large],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )
        #expect(model.displayedNodes.map(\.id) == [large.id, small.id])
        #expect(model.displayedNode(id: small.id)?.allocatedSize == 10)

        let resizedSmall = makeTestFileNode(id: small.id, name: small.name, size: 100)
        model.updateContent(
            nodes: [resizedSmall, large],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        #expect(model.displayedNodes.map(\.id) == [small.id, large.id])
        #expect(model.displayedNode(id: small.id)?.allocatedSize == 100)
    }

    @Test
    func testCurrentContentsFiltersBeforeReturningSortedMatches() {
        let smallMatch = makeTestFileNode(id: "/root/matches/small.txt", name: "small-match.txt", size: 10)
        let largeMatch = makeTestFileNode(id: "/root/matches/large.txt", name: "large-match.txt", size: 30)
        let ignored = makeTestFileNode(id: "/root/ignored.bin", name: "ignored.bin", size: 100)

        let result = FileBrowserResults.filteredAndSortedCurrentContents(
            [smallMatch, ignored, largeMatch],
            query: FileBrowserQuery(text: "match"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )

        #expect(result.map(\.id) == [largeMatch.id, smallMatch.id])
    }

    @Test
    func testCurrentContentsSearchNormalizesCaseAccentsAndPathQueries() {
        let resume = makeTestFileNode(id: "/root/docs/resume.pdf", name: "Résumé.pdf", size: 10)
        let report = makeTestFileNode(id: "/root/reports/quarterly.pdf", name: "REPORT.PDF", size: 20)
        let cache = makeTestFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 30)
        let ignored = makeTestFileNode(id: "/root/other.bin", name: "other.bin", size: 40)
        let nodes = [resume, report, cache, ignored]
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]

        #expect(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "resume"),
                sortOrder: sortOrder
            ).map(\.id) == [resume.id])
        #expect(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "report"),
                sortOrder: sortOrder
            ).map(\.id) == [report.id])
        #expect(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "/library/caches"),
                sortOrder: sortOrder
            ).map(\.id) == [cache.id])
        #expect(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "Library"),
                sortOrder: sortOrder
            ).isEmpty)
    }

    @Test(arguments: [
        ("resume", ["/root/docs/resume.pdf"]),
        ("report", ["/root/reports/quarterly.pdf"]),
        ("/library/caches", ["/root/Library/Caches/cache.db"]),
        ("\\library\\caches", ["/root/Library/Caches/cache.db"]),
        ("Library", []),
    ])
    func testCurrentContentsAndEntireScanSearchUseSameNormalizedRules(query: String, expectedIDs: [String]) async throws
    {
        let resume = makeTestFileNode(id: "/root/docs/resume.pdf", name: "Résumé.pdf", size: 10)
        let report = makeTestFileNode(id: "/root/reports/quarterly.pdf", name: "REPORT.PDF", size: 20)
        let cache = makeTestFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 30)
        let ignored = makeTestFileNode(id: "/root/other.bin", name: "other.bin", size: 40)
        let nodes = [resume, report, cache, ignored]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: nodes)
        let store = FileTreeStore(root: root, childrenByID: [root.id: nodes])
        let service = await FileSearchService()
        let snapshotID = UUID()
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        let currentContentsResults = FileBrowserResults.filteredAndSortedCurrentContents(
            nodes,
            query: FileBrowserQuery(text: query),
            sortOrder: sortOrder,
            fileTreeStore: store
        )
        let entireScanResults = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: query),
            sortOrder: sortOrder
        )

        #expect(currentContentsResults.map(\.id) == expectedIDs, "Current contents query: \(query)")
        #expect(entireScanResults.map(\.id) == expectedIDs, "Entire scan query: \(query)")
    }

    @Test
    func testEntireScanSearchCannotObserveLogicalScopeSiblings() async throws {
        let visible = makeTestFileNode(
            id: "/root/Home/report-visible.pdf",
            name: "report-visible.pdf",
            size: 20
        )
        let home = makeTestDirectoryNode(id: "/root/Home", name: "Home", children: [visible])
        let outside = makeTestFileNode(
            id: "/root/report-outside.pdf",
            name: "report-outside.pdf",
            size: 30
        )
        let unrelatedNodes = (0..<4_100).map { offset in
            makeTestFileNode(
                id: "/root/unrelated-\(offset).dat",
                name: "unrelated-\(offset).dat",
                size: 1
            )
        }
        let rootChildren = [home, outside] + unrelatedNodes
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: rootChildren)
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: rootChildren,
                home.id: [visible],
            ])
        let scope = try #require(store.logicalScope(rootedAt: home.id))
        let service = await FileSearchService()
        let snapshotID = UUID()

        let metadataResults = try await service.search(
            snapshotID: snapshotID,
            treeStore: scope,
            query: FileBrowserQuery(allocatedSize: .init(relation: .atLeast, bytes: 0)),
            sortOrder: []
        )
        let visibleResults = try await service.search(
            snapshotID: snapshotID,
            treeStore: scope,
            query: FileBrowserQuery(text: "\\HOME\\REPORT-VIS"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        let siblingResults = try await service.search(
            snapshotID: snapshotID,
            treeStore: scope,
            query: FileBrowserQuery(text: "/root/report-outside"),
            sortOrder: []
        )

        #expect(metadataResults.map(\.id) == [visible.id])
        #expect(visibleResults.map(\.id) == [visible.id])
        #expect(siblingResults.isEmpty)
        #expect(scope.node(id: outside.id) == nil)
    }

    @Test
    func testStructuredQueryCombinesTextKindAndAllocatedSizeAcrossScopes() async throws {
        let smallTarget = makeTestFileNode(
            id: "/root/small-target.bin",
            name: "small-target.bin",
            size: 499_999_999
        )
        let boundaryTarget = makeTestFileNode(
            id: "/root/boundary-target.bin",
            name: "boundary-target.bin",
            size: 500_000_000
        )
        let largeTarget = makeTestFileNode(
            id: "/root/large-target.bin",
            name: "large-target.bin",
            size: 500_000_001
        )
        let largeOther = makeTestFileNode(
            id: "/root/large-other.bin",
            name: "large-other.bin",
            size: 700_000_000
        )
        let largeFolder = makeTestDirectoryNode(
            id: "/root/target-folder",
            name: "target-folder",
            children: [largeOther]
        )
        let nodes = [smallTarget, boundaryTarget, largeTarget, largeFolder]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: nodes)
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: nodes,
                largeFolder.id: [largeOther],
            ])
        let query = FileBrowserQuery(
            text: "target",
            itemKind: .file,
            allocatedSize: FileBrowserAllocatedSizeFilter(
                relation: .greaterThan,
                bytes: 500_000_000
            )
        )
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]

        let currentContentsResults = FileBrowserResults.filteredAndSortedCurrentContents(
            nodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: store
        )
        let entireScanResults = try await FileSearchService().search(
            snapshotID: UUID(),
            treeStore: store,
            query: query,
            sortOrder: sortOrder
        )

        #expect(currentContentsResults.map(\.id) == [largeTarget.id])
        #expect(entireScanResults.map(\.id) == [largeTarget.id])
    }

    @Test
    func testMetadataSearchPreservesKindsSizesAndOrderBeforeAndAfterTextSearch() async throws {
        let file = makeTestFileNode(id: "/root/a.txt", name: "a.txt", size: 10)
        let nested = makeTestFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 20)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let payload = makeTestFileNode(id: "/root/app/c.txt", name: "c.txt", size: 30)
        let package = makeTestDirectoryNode(id: "/root/app", name: "app", children: [payload], isPackage: true)
        let link = makeTestFileNode(id: "/root/link", name: "link", size: 20, isSymbolicLink: true)
        let synthetic = makeTestFileNode(id: "/root/other", name: "other", size: 20, isSynthetic: true)
        let children = [file, folder, package, link, synthetic]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: children,
                folder.id: [nested],
                package.id: [payload],
            ])
        let service = await FileSearchService()
        let snapshotID = UUID()
        let cases: [(query: FileBrowserQuery, expected: [String])] = [
            (FileBrowserQuery(text: " \n ", itemKind: .file), [payload.id, nested.id, file.id]),
            (FileBrowserQuery(itemKind: .folder), [folder.id]),
            (FileBrowserQuery(itemKind: .package), [package.id]),
            (
                FileBrowserQuery(allocatedSize: .init(relation: .atLeast, bytes: 20)),
                [package.id, payload.id, folder.id, nested.id, link.id, synthetic.id]
            ),
            (
                FileBrowserQuery(itemKind: .file, allocatedSize: .init(relation: .greaterThan, bytes: 20)),
                [payload.id]
            ),
        ]

        for hasTextIndex in [false, true] {
            if hasTextIndex {
                let textMatches = try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: FileBrowserQuery(text: "/folder/b"),
                    sortOrder: []
                )
                #expect(textMatches.map(\.id) == [nested.id])
            }
            for searchCase in cases {
                let results = try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: searchCase.query,
                    sortOrder: []
                )
                #expect(results.map(\.id) == searchCase.expected)
            }
        }
    }

    @Test
    func testAllocatedSizeRelationsHandleExactBoundary() {
        let boundary: Int64 = 500_000_000

        #expect(!(FileBrowserAllocatedSizeFilter(relation: .greaterThan, bytes: boundary).matches(boundary)))
        #expect(FileBrowserAllocatedSizeFilter(relation: .atLeast, bytes: boundary).matches(boundary))
        #expect(!(FileBrowserAllocatedSizeFilter(relation: .lessThan, bytes: boundary).matches(boundary)))
        #expect(FileBrowserAllocatedSizeFilter(relation: .atMost, bytes: boundary).matches(boundary))
    }

    @Test
    func testSizeUnitsPreserveEditablePrecisionAndRejectInvalidByteCounts() {
        let fractionalKilobytes: Int64 = 1_500
        let unit = FileBrowserSizeUnit.bestUnit(for: fractionalKilobytes)
        let reopenedValue = Double(fractionalKilobytes) / Double(unit.bytes)

        #expect(unit == .kilobytes)
        #expect(unit.byteCount(for: reopenedValue) == fractionalKilobytes)
        #expect(FileBrowserSizeUnit.bestUnit(for: 500_000_000) == .megabytes)
        #expect(FileBrowserSizeUnit.bestUnit(for: 1_500_000_000) == .gigabytes)
        #expect(FileBrowserSizeUnit.bestUnit(for: 1_234_560) == .kilobytes)
        #expect(FileBrowserSizeUnit.kilobytes.byteCount(for: 1.234) == 1_234)
        #expect(FileBrowserSizeUnit.megabytes.byteCount(for: -.infinity) == nil)
        #expect(FileBrowserSizeUnit.megabytes.byteCount(for: -1) == nil)
        #expect(
            FileBrowserSizeUnit.kilobytes.byteCount(
                for: Double(Int64.max) / Double(FileBrowserSizeUnit.kilobytes.bytes)
            ) == nil)
    }

    @Test
    func testStructuredKindClassificationDistinguishesSearchableItemTypes() {
        let file = makeTestFileNode(id: "/root/file", name: "file")
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [])
        let package = makeTestDirectoryNode(id: "/root/app", name: "app", children: [], isPackage: true)
        let symbolicLink = makeTestFileNode(id: "/root/link", name: "link", isSymbolicLink: true)
        let synthetic = makeTestFileNode(id: "/root/system-data", name: "system-data", isSynthetic: true)

        #expect(FileBrowserItemKindFilter.classification(for: file) == .file)
        #expect(FileBrowserItemKindFilter.classification(for: folder) == .folder)
        #expect(FileBrowserItemKindFilter.classification(for: package) == .package)
        #expect(FileBrowserItemKindFilter.classification(for: symbolicLink) == nil)
        #expect(FileBrowserItemKindFilter.classification(for: synthetic) == nil)
    }

    @MainActor
    @Test
    func testEntireScanSupportsStructuredFilterWithoutSearchText() async throws {
        let small = makeTestFileNode(id: "/root/small.bin", name: "small.bin", size: 100)
        let large = makeTestFileNode(id: "/root/large.bin", name: "large.bin", size: 1_000)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [large])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [small, folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [small, folder],
                folder.id: [large],
            ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = FileBrowserModel(searchDebounceDuration: .zero)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveQuery(
            FileBrowserQuery(
                itemKind: .file,
                allocatedSize: FileBrowserAllocatedSizeFilter(relation: .greaterThan, bytes: 500)
            )
        )

        #expect(model.isShowingEntireScanResults)
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [large.id])
    }

    @MainActor
    @Test
    func testSearchScopesKeepAndClearIndependentStructuredQueries() {
        let model = FileBrowserModel()
        let currentContentsQuery = FileBrowserQuery(
            itemKind: .folder,
            allocatedSize: FileBrowserAllocatedSizeFilter(
                relation: .atLeast,
                bytes: 500_000_000
            )
        )
        let entireScanQuery = FileBrowserQuery(
            itemKind: .package
        )

        model.setActiveQuery(currentContentsQuery)
        model.setSearchScope(.entireScan)
        #expect(model.activeQuery == FileBrowserQuery())

        model.setActiveQuery(entireScanQuery)
        model.setSearchScope(.currentContents)
        #expect(model.activeQuery == currentContentsQuery)

        model.clearActiveQuery()
        #expect(model.activeQuery == FileBrowserQuery())

        model.setSearchScope(.entireScan)
        #expect(model.activeQuery == entireScanQuery)
    }

    @MainActor
    @Test
    func testCurrentContentsHideDiscardPileQueuedNodes() async throws {
        let hiddenFile = makeTestFileNode(id: "/root/hidden.txt", name: "hidden.txt", size: 40)
        let visibleFile = makeTestFileNode(id: "/root/visible.txt", name: "visible.txt", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hiddenFile, visibleFile])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hiddenFile, visibleFile]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = FileBrowserModel(
            searchDebounceDuration: .zero,
            currentContentsAsyncThreshold: 1
        )

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store,
            hiddenNodeIDs: [hiddenFile.id]
        )

        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [visibleFile.id])

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [hiddenFile.id, visibleFile.id])
    }

    @Test
    func testHiddenNodeFilteringChecksCancellation() throws {
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: nodes)
        let store = FileTreeStore(root: root, childrenByID: [root.id: nodes])
        let probe = CancellationProbe(throwOnCheck: 3)

        #expect(throws: CancellationError.self) {
            try FileBrowserResults.visibleNodes(
                nodes,
                hiddenNodeIDs: [nodes[0].id],
                fileTreeStore: store,
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == 3)
    }

    @MainActor
    @Test
    func testEntireScanSearchHidesDiscardPileQueuedDescendants() async throws {
        let hiddenTarget = makeTestFileNode(id: "/root/folder/target-hidden.txt", name: "target-hidden.txt", size: 40)
        let hiddenFolder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [hiddenTarget])
        let visibleTarget = makeTestFileNode(id: "/root/target-visible.txt", name: "target-visible.txt", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hiddenFolder, visibleTarget])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [hiddenFolder, visibleTarget],
                hiddenFolder.id: [hiddenTarget],
            ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = FileBrowserModel(searchDebounceDuration: .zero)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store,
            hiddenNodeIDs: [hiddenFolder.id]
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")

        try await waitForSearchToFinish(model)

        #expect(model.displayedNodes.map(\.id) == [visibleTarget.id])
    }

    @Test
    func testEqualSortValuesFallBackToNameAndID() async throws {
        let beta = makeTestFileNode(id: "/root/beta.txt", name: "Beta.txt", size: 10)
        let alphaB = makeTestFileNode(id: "/root/b-alpha.txt", name: "Alpha.txt", size: 10)
        let alphaA = makeTestFileNode(id: "/root/a-alpha.txt", name: "Alpha.txt", size: 10)
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]

        let currentContents = FileBrowserResults.filteredAndSortedCurrentContents(
            [beta, alphaB, alphaA],
            query: FileBrowserQuery(),
            sortOrder: sortOrder
        )
        #expect(currentContents.map(\.id) == [alphaA.id, alphaB.id, beta.id])

        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [beta, alphaB, alphaA])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [beta, alphaB, alphaA]])
        let service = await FileSearchService()
        let searchResults = try await service.search(
            snapshotID: UUID(),
            treeStore: store,
            query: FileBrowserQuery(text: "txt"),
            sortOrder: sortOrder
        )

        #expect(searchResults.map(\.id) == [alphaA.id, alphaB.id, beta.id])
    }

    @Test
    func testSortsByDisplayedFileCountAndModifiedDateColumns() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let packagePayloads = [
            makeTestFileNode(id: "/root/Sample.app/a.dat", name: "a.dat"),
            makeTestFileNode(id: "/root/Sample.app/b.dat", name: "b.dat"),
            makeTestFileNode(id: "/root/Sample.app/c.dat", name: "c.dat"),
        ]
        let hiddenPackage = makeTestDirectoryNode(
            id: "/root/Sample.app",
            name: "Sample.app",
            children: packagePayloads,
            isPackage: true
        )
        let smallFolder = makeTestDirectoryNode(
            id: "/root/small",
            name: "small",
            children: [
                makeTestFileNode(id: "/root/small/a.txt", name: "a.txt", lastModified: older)
            ]
        )
        let largeFolder = makeTestDirectoryNode(
            id: "/root/large",
            name: "large",
            children: [
                makeTestFileNode(id: "/root/large/a.txt", name: "a.txt", lastModified: older),
                makeTestFileNode(id: "/root/large/b.txt", name: "b.txt", lastModified: newer),
            ]
        )
        let oldFile = makeTestFileNode(id: "/root/old.txt", name: "old.txt", lastModified: older)
        let newFile = makeTestFileNode(id: "/root/new.txt", name: "new.txt", lastModified: newer)
        let unknownFile = makeTestFileNode(id: "/root/unknown.txt", name: "unknown.txt")

        let fileCountResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [smallFolder, largeFolder, hiddenPackage, oldFile],
            query: FileBrowserQuery(),
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)]
        )
        #expect(fileCountResults.map(\.id) == [largeFolder.id, oldFile.id, smallFolder.id, hiddenPackage.id])

        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [hiddenPackage, largeFolder, oldFile]
        )
        let visiblePackageStore = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [hiddenPackage, largeFolder, oldFile],
                hiddenPackage.id: packagePayloads,
            ])
        let visibleFileCountResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [largeFolder, hiddenPackage, oldFile],
            query: FileBrowserQuery(),
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)],
            fileTreeStore: visiblePackageStore
        )
        #expect(visibleFileCountResults.map(\.id) == [hiddenPackage.id, largeFolder.id, oldFile.id])

        let modifiedResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [newFile, unknownFile, oldFile],
            query: FileBrowserQuery(),
            sortOrder: [FileNodeTableComparator(field: .lastModified)]
        )
        #expect(modifiedResults.map(\.id) == [unknownFile.id, oldFile.id, newFile.id])
    }

    @Test
    func testDisplayProjectionChecksCancellationDuringIndexing() throws {
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }
        let probe = CancellationProbe(throwOnCheck: 3)

        #expect(throws: CancellationError.self) {
            try FileBrowserDisplayProjection(
                nodes: nodes,
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == 3)
    }

    @Test
    func testCancellableSortThrowsBeforeSort() throws {
        let probe = CancellationProbe(throwOnCheck: 1)
        let node = makeTestFileNode(id: "/root/file.txt", name: "file.txt")

        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                [node],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == 1)
    }

    @Test
    func testCancellableSortThrowsDuringPreparation() throws {
        let probe = CancellationProbe(throwOnCheck: 3)
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }

        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == 3)
    }

    @Test
    func testCancellableSortThrowsDuringResultProjection() throws {
        let nodes = (0..<600).map { index in
            makeTestFileNode(
                id: "/root/file-\(index).txt",
                name: "file-\(index).txt",
                size: Int64(index)
            )
        }
        let preparationCheckCount = (nodes.count + 255) / 256
        // Entry, preparation, post-preparation, pre-allocation, and the first
        // completed projection chunk.
        let secondProjectionCheck = preparationCheckCount + 4
        let probe = CancellationProbe(throwOnCheck: secondProjectionCheck)

        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .allocatedSize)],
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == secondProjectionCheck)
    }

    @Test
    func testCancellableSortChecksBeforeEmptyProjectionAndAfterFinalChunk() throws {
        let emptyProbe = CancellationProbe(throwOnCheck: 3)
        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                [],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: emptyProbe.check
            )
        }
        #expect(emptyProbe.checkCount == 3)

        let node = makeTestFileNode(
            id: "/root/file.txt",
            name: "file.txt",
            size: 1
        )
        let finalChunkProbe = CancellationProbe(throwOnCheck: 5)
        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                [node],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: finalChunkProbe.check
            )
        }
        #expect(finalChunkProbe.checkCount == 5)
    }

    @Test
    func testLargeSortPreservesOrderAcrossSortedRuns() {
        let nodes = (0..<20_000).map { index in
            if index.isMultiple(of: 3) {
                return makeTestSummarizedDirectoryNode(
                    id: "/root/folder-\(index)",
                    name: "folder-\(index)",
                    size: Int64(index),
                    descendantFileCount: index % 7
                )
            }
            return makeTestFileNode(
                id: "/root/file-\(index).dat",
                name: "file-\(index).dat",
                size: Int64(index)
            )
        }

        let sortedNodes = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )

        #expect(sortedNodes.map(\.id) == nodes.reversed().map(\.id))

        let sortOrder = [
            FileNodeTableComparator(field: .itemKind),
            FileNodeTableComparator(field: .descendantFileCount, order: .reverse),
            FileNodeTableComparator(field: .allocatedSize, order: .reverse),
        ]
        let expected = nodes.sorted { lhs, rhs in
            for comparator in sortOrder {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame {
                    return result == .orderedAscending
                }
            }
            return false  // Allocated sizes are unique in this fixture.
        }
        #expect(FileBrowserResults.sorted(nodes, sortOrder: sortOrder).map(\.id) == expected.map(\.id))
    }

    @Test
    func testCancellableSortChecksCancellationBetweenLargeRuns() throws {
        let nodes = (0..<20_000).map { index in
            makeTestFileNode(
                id: "/root/file-\(index).dat",
                name: "file-\(index).dat",
                size: Int64(index)
            )
        }
        let preparationCheckCount = (nodes.count + 255) / 256
        // Entry, preparation, post-preparation, and one check before each sorted run.
        let firstCheckAfterOneSortedRun = preparationCheckCount + 4
        let probe = CancellationProbe(throwOnCheck: firstCheckAfterOneSortedRun)

        #expect(throws: CancellationError.self) {
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)],
                cancellationCheck: probe.check
            )
        }
        #expect(probe.checkCount == firstCheckAfterOneSortedRun)
    }

    @Test
    func testSortOrderMatchesTableComparators() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let alpha = makeTestFileNode(id: "/root/alpha.txt", name: "alpha.txt", size: 10, lastModified: newer)
        let beta = makeTestFileNode(id: "/root/beta.txt", name: "beta.txt", size: 30)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [
                makeTestFileNode(id: "/root/folder/a.txt", name: "a.txt", size: 10, lastModified: older),
                makeTestFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 10, lastModified: older),
            ]
        )
        let nodes = [folder, beta, alpha]

        let nameResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .name)]
        )
        #expect(nameResults.map(\.id) == [alpha.id, beta.id, folder.id])

        let sizeResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        #expect(sizeResults.map(\.id) == [beta.id, folder.id, alpha.id])

        let kindResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .itemKind)]
        )
        #expect(kindResults.map(\.id) == [alpha.id, beta.id, folder.id])

        let countResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)]
        )
        #expect(countResults.map(\.id) == [folder.id, alpha.id, beta.id])

        let modifiedResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .lastModified)]
        )
        #expect(modifiedResults.map(\.id) == [beta.id, folder.id, alpha.id])
    }

    @Test
    func testSortOrderUsesSecondaryDescriptorBeforeDeterministicFallback() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let alpha = makeTestFileNode(
            id: "/root/alpha.txt",
            name: "alpha.txt",
            size: 10,
            lastModified: older
        )
        let zeta = makeTestFileNode(
            id: "/root/zeta.txt",
            name: "zeta.txt",
            size: 10,
            lastModified: newer
        )

        let secondaryResult = FileBrowserResults.sorted(
            [alpha, zeta],
            sortOrder: [
                FileNodeTableComparator(field: .allocatedSize, order: .reverse),
                FileNodeTableComparator(field: .lastModified, order: .reverse),
            ]
        )
        let fallbackResult = FileBrowserResults.sorted(
            [zeta, alpha],
            sortOrder: [
                FileNodeTableComparator(field: .allocatedSize, order: .reverse)
            ]
        )

        #expect(secondaryResult.map(\.id) == [zeta.id, alpha.id])
        #expect(fallbackResult.map(\.id) == [alpha.id, zeta.id])
    }

    @MainActor
    @Test
    func testLargeCurrentContentsFilterPublishesLatestQuery() async throws {
        let small = makeTestFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeTestFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let other = makeTestFileNode(id: "/root/other.bin", name: "other.bin", size: 20)
        let model = FileBrowserModel(
            searchDebounceDuration: .milliseconds(40),
            currentContentsAsyncThreshold: 1
        )

        model.updateContent(
            nodes: [small, large, other],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )
        #expect(!(model.isDisplayingCurrentResults))
        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [large.id, other.id, small.id])

        model.setActiveSearchText("small")
        #expect(model.isRefreshingCurrentContents)
        #expect(!(model.isDisplayingCurrentResults))
        #expect(model.displayedNodes.map(\.id) == [large.id, other.id, small.id])

        model.setActiveSearchText("large")

        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [large.id])

    }

    @MainActor
    @Test
    func testLargeCurrentContentsRefreshAppliesWithEmptyEntireScanSearch() async throws {
        let small = makeTestFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeTestFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let other = makeTestFileNode(id: "/root/other.bin", name: "other.bin", size: 20)
        let model = FileBrowserModel(
            searchDebounceDuration: .zero,
            currentContentsAsyncThreshold: 1
        )

        model.updateContent(
            nodes: [small, large, other],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )
        try await waitForCurrentContentsRefreshToFinish(model)

        model.setSearchScope(.entireScan)

        #expect(model.isRefreshingCurrentContents)
        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [large.id, other.id, small.id])
    }

    @MainActor
    @Test
    func testLargeCurrentContentsUpdateWithSameContentIDMarksRowsStale() async throws {
        let old = makeTestFileNode(id: "/root/old.txt", name: "old.txt", size: 10)
        let new = makeTestFileNode(id: "/root/new.txt", name: "new.txt", size: 20)
        let model = FileBrowserModel(
            searchDebounceDuration: .milliseconds(40),
            currentContentsAsyncThreshold: 1
        )

        model.updateContent(
            nodes: [old],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )
        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [old.id])

        model.updateContent(
            nodes: [new],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        #expect(model.isRefreshingCurrentContents)
        #expect(!(model.isDisplayingCurrentResults))
        #expect(model.displayedNodes.map(\.id) == [old.id])

        try await waitForCurrentContentsRefreshToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [new.id])
    }

    @MainActor
    @Test
    func testContentUpdatePublishesRowsAndDisplayedNodesTogether() {
        let small = makeTestFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeTestFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let model = FileBrowserModel()
        var publishCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            publishCount += 1
        }

        model.updateContent(
            nodes: [small, large],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        #expect(model.displayedNodes.map(\.id) == [large.id, small.id])
        #expect(model.displayedNode(id: small.id)?.name == small.name)
        #expect(publishCount == 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    @Test
    func testDisplayStateBuildsRowPresentationValues() {
        let modifiedDate = Date(timeIntervalSince1970: 1_234_567)
        let file = makeTestFileNode(
            id: "/root/file.txt",
            name: "file.txt",
            size: 1_024,
            lastModified: modifiedDate
        )
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [
                makeTestFileNode(id: "/root/folder/a.txt", name: "a.txt", size: 1),
                makeTestFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 1),
            ]
        )
        let package = makeTestDirectoryNode(
            id: "/root/Sample.app",
            name: "Sample.app",
            children: [
                makeTestFileNode(id: "/root/Sample.app/Contents/MacOS/Sample", name: "Sample", size: 1)
            ],
            isPackage: true
        )
        let model = FileBrowserModel()

        model.updateContent(
            nodes: [file, folder, package],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        let fileValues = model.displayValues(for: file)
        let folderValues = model.displayValues(for: folder)
        let visiblePackageValues = model.displayValues(for: package)
        let hiddenPackageValues = model.displayValues(for: package, hidesPackageContents: true)

        #expect(fileValues.allocatedSize == "1 KB")
        #expect(fileValues.descendantCount == "1")
        #expect(fileValues.modifiedDate == RadixFormatters.date(modifiedDate))
        #expect(folderValues.descendantCount == "2")
        #expect(visiblePackageValues.descendantCount == "1")
        #expect(hiddenPackageValues.descendantCount == "—")
    }

    @Test
    func testSearchServiceMatchesNameKindAndPathOnlyForPathQueries() async throws {
        let photo = makeTestFileNode(id: "/root/photos/vacation.jpg", name: "vacation.jpg", size: 20)
        let cache = makeTestFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 10)
        let photos = makeTestDirectoryNode(id: "/root/photos", name: "photos", children: [photo])
        let library = makeTestDirectoryNode(id: "/root/Library", name: "Library", children: [cache])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [photos, library])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [photos, library],
                photos.id: [photo],
                library.id: [cache],
            ])
        let service = await FileSearchService()
        let snapshotID = UUID()

        let photoMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: "vacation"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        #expect(photoMatches.map(\.id) == [photo.id])

        let nonPathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: "Caches"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        #expect(nonPathMatches.isEmpty)

        let pathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: "/Library/Caches"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        #expect(pathMatches.map(\.id) == [cache.id])
    }

    @Test
    func testSearchServiceMatchesAncestorAndBoundaryPathQueries() async throws {
        let resume = makeTestFileNode(
            id: "/root/Archívé/Projects/Résumé.pdf",
            name: "Résumé.pdf"
        )
        let report = makeTestFileNode(
            id: "/root/Archívé/Projects/Report.txt",
            name: "Report.txt"
        )
        let projects = makeTestDirectoryNode(
            id: "/root/Archívé/Projects",
            name: "Projects",
            children: [resume, report]
        )
        let archive = makeTestDirectoryNode(
            id: "/root/Archívé",
            name: "Archívé",
            children: [projects]
        )
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [archive])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [archive],
                archive.id: [projects],
                projects.id: [resume, report],
            ])
        let service = await FileSearchService()
        let snapshotID = UUID()
        let cases: [(query: String, expectedIDs: Set<String>)] = [
            ("/archive", [archive.id, projects.id, resume.id, report.id]),
            ("hive/pro", [projects.id, resume.id, report.id]),
            ("projects/resu", [resume.id]),
            ("\\ARCHÍVE\\PROJECTS\\RÉSU", [resume.id]),
            ("/archive/projects/", [resume.id, report.id]),
        ]

        for searchCase in cases {
            let results = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: FileBrowserQuery(text: searchCase.query),
                sortOrder: []
            )

            #expect(Set(results.map(\.id)) == searchCase.expectedIDs, "Query: \(searchCase.query)")
            #expect(results.count == searchCase.expectedIDs.count)
        }
    }

    @Test
    func testSearchServiceReplacesIndexForDifferentTreeWithSameSnapshotID() async throws {
        let snapshotID = UUID()
        let originalFile = makeSearchTestFileNode(
            id: "stable-file",
            path: "/root/old/alpha.txt",
            name: "alpha.txt"
        )
        let originalFolder = makeTestDirectoryNode(
            id: "/root/old",
            name: "old",
            children: [originalFile]
        )
        let originalRoot = makeTestDirectoryNode(id: "/root", name: "root", children: [originalFolder])
        let originalStore = FileTreeStore(
            root: originalRoot,
            childrenByID: [
                originalRoot.id: [originalFolder],
                originalFolder.id: [originalFile],
            ]
        )
        let replacementFile = makeSearchTestFileNode(
            id: originalFile.id,
            path: "/root/new/beta.txt",
            name: "beta.txt"
        )
        let replacementRoot = makeTestDirectoryNode(
            id: originalRoot.id,
            name: originalRoot.name,
            children: [replacementFile]
        )
        let replacementStore = FileTreeStore(
            root: replacementRoot,
            childrenByID: [replacementRoot.id: [replacementFile]]
        )
        let service = await FileSearchService()

        let originalMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: originalStore,
            query: FileBrowserQuery(text: "/old/alpha"),
            sortOrder: []
        )
        let replacementMetadataMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: replacementStore,
            query: FileBrowserQuery(itemKind: .file),
            sortOrder: []
        )
        let replacementMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: replacementStore,
            query: FileBrowserQuery(text: "/new/beta"),
            sortOrder: []
        )
        let stalePathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: replacementStore,
            query: FileBrowserQuery(text: "/old/alpha"),
            sortOrder: []
        )
        let restoredOriginalMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: originalStore,
            query: FileBrowserQuery(text: "/old/alpha"),
            sortOrder: []
        )

        #expect(originalMatches.map(\.name) == ["alpha.txt"])
        #expect(replacementMetadataMatches.map(\.name) == ["beta.txt"])
        #expect(replacementMatches.map(\.name) == ["beta.txt"])
        #expect(stalePathMatches.isEmpty)
        #expect(restoredOriginalMatches.map(\.name) == ["alpha.txt"])
    }

    @Test
    func testSearchServicePruningAndRepeatedSearchesPreserveResults() async throws {
        let match = makeTestFileNode(id: "/root/target.txt", name: "target.txt")
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [match])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [match]])
        let service = await FileSearchService()
        let snapshotID = UUID()

        func resultIDs() async throws -> [String] {
            try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: FileBrowserQuery(text: "/root/target"),
                sortOrder: []
            ).map(\.id)
        }

        let baseline = try await resultIDs()
        let repeated = try await resultIDs()
        #expect(repeated == baseline)

        await service.pruneIndexes(keeping: snapshotID)
        let retained = try await resultIDs()
        #expect(retained == baseline)

        await service.pruneIndexes(keeping: UUID())
        let rebuiltAfterSnapshotPrune = try await resultIDs()
        #expect(rebuiltAfterSnapshotPrune == baseline)

        await service.pruneIndexes(keeping: nil)
        let rebuiltAfterFullPrune = try await resultIDs()
        #expect(rebuiltAfterFullPrune == baseline)
    }

    @Test
    func testSearchServiceHonorsPreCancellationAndRemainsReusable() async throws {
        let target = makeTestFileNode(id: "/root/target.txt", name: "target.txt")
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        for query in [FileBrowserQuery(text: "target"), FileBrowserQuery(itemKind: .file)] {
            let service = await FileSearchService()
            let snapshotID = UUID()

            let cancelledColdSearch = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: query,
                    sortOrder: []
                )
            }
            await assertCancellation(of: cancelledColdSearch)

            let warmedResults = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: query,
                sortOrder: []
            )
            #expect(warmedResults.map(\.id) == [target.id])

            let cancelledWarmSearch = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.search(
                    snapshotID: snapshotID,
                    treeStore: store,
                    query: query,
                    sortOrder: []
                )
            }
            await assertCancellation(of: cancelledWarmSearch)

            let repeatedResults = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: query,
                sortOrder: []
            )
            #expect(repeatedResults == warmedResults)
        }
    }

    @Test
    func testSearchServicePathMatchingHasExactNodeMatcherParityForExceptionalURLs() async throws {
        let synthetic = makeSearchTestFileNode(
            id: "synthetic-child",
            path: "/scan",
            name: "Synthetic Usage",
            isSynthetic: true
        )
        let detached = makeSearchTestFileNode(
            id: "detached-child",
            path: "/detached/place/odd.bin",
            name: "Odd"
        )
        let renamed = makeSearchTestFileNode(
            id: "renamed-child",
            path: "/scan/on-disk.txt",
            name: "Friendly Résumé"
        )
        let repeatedSeparator = makeSearchTestFileNode(
            id: "repeated-separator-child",
            path: "/scan//double-only.bin",
            name: "Repeated Separator"
        )
        let repeatedRootSeparator = makeSearchTestFileNode(
            id: "repeated-root-separator-child",
            path: "//leading-only.bin",
            name: "Repeated Root Separator"
        )
        let relative = makeSearchTestFileNode(
            id: "relative-child",
            path: "unused",
            name: "Relative",
            url: URL(string: "relative-node")!
        )
        let overlappingPrefixFile = makeSearchTestFileNode(
            id: "/scan/abababa/ababa.txt",
            path: "/scan/abababa/ababa.txt",
            name: "ababa.txt"
        )
        let overlappingPrefixFolder = makeTestDirectoryNode(
            id: "/scan/abababa",
            name: "abababa",
            children: [overlappingPrefixFile]
        )
        let scan = makeTestDirectoryNode(
            id: "/scan",
            name: "scan",
            children: [
                synthetic,
                detached,
                renamed,
                repeatedSeparator,
                repeatedRootSeparator,
                relative,
                overlappingPrefixFolder,
            ]
        )
        let root = makeTestDirectoryNode(id: "/", name: "/", children: [scan])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [scan],
                scan.id: [
                    synthetic,
                    detached,
                    renamed,
                    repeatedSeparator,
                    repeatedRootSeparator,
                    relative,
                    overlappingPrefixFolder,
                ],
                overlappingPrefixFolder.id: [overlappingPrefixFile],
            ])
        let searchableNodes = store.indexedNodeIDs(excludingRoot: true).compactMap(store.node(id:))
        let service = await FileSearchService()
        let snapshotID = UUID()
        let queries = [
            "/",
            "//",
            "/scan",
            "/scan/",
            "/scan/synthetic",
            "/detached/place/odd",
            "/scan/friendly",
            "/scan/on-disk",
            "/scan//double-only",
            "/scan/double-only",
            "//leading-only",
            "/leading-only",
            "ababab/ababa",
            "/scan/abababa/ababa",
            "friendly resume",
            "\\SCAN\\ON-DISK",
        ]

        for queryText in queries {
            let query = FileBrowserQuery(text: queryText)
            let preparedQuery = query.prepared()
            let expectedIDs = searchableNodes.filter { node in
                SearchNormalizer.nodeMatches(
                    node,
                    normalizedQuery: preparedQuery.normalizedText,
                    normalizedPathQuery: preparedQuery.normalizedPathText,
                    includesPath: preparedQuery.includesPath
                )
            }.map(\.id)
            let results = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: query,
                sortOrder: []
            )

            #expect(results.map(\.id) == expectedIDs, "Query: \(queryText)")
        }
    }

    @MainActor
    @Test
    func testModelRunsEntireScanSearchThroughService() async throws {
        let smallTarget = makeTestFileNode(id: "/root/target-small.txt", name: "target-small.txt", size: 5)
        let largeTarget = makeTestFileNode(id: "/root/target-large.txt", name: "target-large.txt", size: 50)
        let other = makeTestFileNode(id: "/root/other.log", name: "other.log", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [smallTarget, largeTarget, other])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [smallTarget, largeTarget, other]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = FileBrowserModel(searchDebounceDuration: .zero)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        #expect(!(model.isDisplayingCurrentResults))

        try await waitForSearchToFinish(model)
        #expect(model.isDisplayingCurrentResults)
        #expect(model.displayedNodes.map(\.id) == [largeTarget.id, smallTarget.id])
    }

    @MainActor
    @Test
    func testEntireScanSearchRefreshesForNewTreeContentWithSameSnapshotAndVisibleRows() async throws {
        let visible = makeTestFileNode(id: "/root/visible.txt", name: "visible.txt", size: 10)
        let alpha = makeTestFileNode(id: "/root/archive/alpha.txt", name: "alpha.txt", size: 20)
        let archive = makeTestDirectoryNode(id: "/root/archive", name: "archive", children: [alpha])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [archive, visible])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [archive, visible],
                archive.id: [alpha],
            ])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = FileBrowserModel(searchDebounceDuration: .zero)

        model.updateContent(
            nodes: [visible],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("alpha")
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [alpha.id])

        let beta = makeTestFileNode(id: "/root/archive/beta.txt", name: "beta.txt", size: 20)
        let replacementArchive = makeTestDirectoryNode(
            id: archive.id,
            name: archive.name,
            children: [beta]
        )
        let replacementStore = FileTreeStore(
            root: replacementArchive,
            childrenByID: [replacementArchive.id: [beta]]
        )
        let updatedSnapshot = try #require(snapshot.replacingNode(id: archive.id, with: replacementStore))

        model.updateContent(
            nodes: [visible],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: updatedSnapshot,
            fileTreeStore: updatedSnapshot.treeStore
        )
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.isEmpty)

        model.setActiveSearchText("beta")
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [beta.id])
    }

    @MainActor
    @Test
    func testDelayedEntireScanResultCannotReplaceNewerQuery() async throws {
        let slow = makeTestFileNode(id: "/root/slow.txt", name: "slow.txt", size: 5)
        let fast = makeTestFileNode(id: "/root/fast.txt", name: "fast.txt", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [slow, fast])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [slow, fast]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let slowQuery = SearchNormalizer.normalize("slow")
        let fastQuery = SearchNormalizer.normalize("fast")
        let service = DelayedFileSearchService(
            delayedQuery: slowQuery,
            delayedIDs: [slow.id],
            immediateIDsByQuery: [fastQuery: [fast.id]]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("slow")
        try await service.waitUntilStarted(slowQuery)

        model.setActiveSearchText("fast")

        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [fast.id])

        try await service.releaseDelayedResults()
        #expect(await service.completedCancellationStates == [true])
        #expect(model.displayedNodes.map(\.id) == [fast.id])
    }

    @MainActor
    @Test
    func testSwitchingToCurrentContentsClearsWholeScanLoadingAndIgnoresLateResult() async throws {
        let current = makeTestFileNode(id: "/root/current.log", name: "current.log", size: 10)
        let wholeScanOnly = makeTestFileNode(id: "/root/archive/target.txt", name: "target.txt", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [current, wholeScanOnly])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [current, wholeScanOnly]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let query = SearchNormalizer.normalize("target")
        let service = DelayedFileSearchService(
            delayedQuery: query,
            delayedIDs: [wholeScanOnly.id],
            immediateIDsByQuery: [:]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }

        model.updateContent(
            nodes: [current],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        try await service.waitUntilStarted(query)
        #expect(model.isSearchingEntireScan)

        model.setSearchScope(.currentContents)

        #expect(!(model.isSearchingEntireScan))
        #expect(model.displayedNodes.map(\.id) == [current.id])

        try await service.releaseDelayedResults()
        #expect(await service.completedCancellationStates == [true])
        #expect(model.displayedNodes.map(\.id) == [current.id])
    }

    @MainActor
    @Test
    func testCleanupCancelsActiveSearchAndKeepsCurrentRows() async throws {
        let current = makeTestFileNode(id: "/root/current.txt", name: "current.txt", size: 10)
        let wholeScanOnly = makeTestFileNode(id: "/root/archive/target.txt", name: "target.txt", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [current, wholeScanOnly])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [current, wholeScanOnly]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let query = SearchNormalizer.normalize("target")
        let service = DelayedFileSearchService(
            delayedQuery: query,
            delayedIDs: [wholeScanOnly.id],
            immediateIDsByQuery: [:]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }

        model.updateContent(
            nodes: [current],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        try await service.waitUntilStarted(query)

        model.cleanup()

        #expect(!(model.isSearchingEntireScan))
        try await service.releaseDelayedResults()
        #expect(await service.completedCancellationStates == [true])
        #expect(model.displayedNodes.map(\.id) == [current.id])
    }

    @MainActor
    @Test
    func testCleanupCancelsSearchIndexPruneTask() async throws {
        let service = CancellablePruningFileSearchService()
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }
        let firstRoot = makeTestDirectoryNode(id: "/first", name: "first", children: [])
        let secondRoot = makeTestDirectoryNode(id: "/second", name: "second", children: [])
        let firstStore = FileTreeStore(root: firstRoot)
        let secondStore = FileTreeStore(root: secondRoot)
        let firstSnapshot = makeTestSnapshot(root: firstRoot, store: firstStore)
        let secondSnapshot = makeTestSnapshot(root: secondRoot, store: secondStore)

        model.updateContent(
            nodes: [],
            contentID: "\(firstSnapshot.id.uuidString)|\(firstRoot.id)",
            snapshot: firstSnapshot,
            fileTreeStore: firstStore
        )
        model.updateContent(
            nodes: [],
            contentID: "\(secondSnapshot.id.uuidString)|\(secondRoot.id)",
            snapshot: secondSnapshot,
            fileTreeStore: secondStore
        )
        try await service.waitUntilPruneStarted()

        model.cleanup()

        try await waitForPruneCancellation(service)
    }

    @MainActor
    @Test(arguments: [false, true])
    func testSameContentRestartsCancelledSearch(forceRefresh: Bool) async throws {
        let target = makeTestFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let query = SearchNormalizer.normalize("target")
        let service = DelayedFileSearchService(
            delayedQuery: query,
            delayedIDs: [target.id],
            immediateIDsByQuery: [:]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        try await service.waitUntilStarted(query)
        model.cleanup()

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store,
            forceRefresh: forceRefresh
        )

        try await waitForStartCount(service, query: query, count: 2)
        #expect(model.isSearchingEntireScan)
        try await service.releaseDelayedResults()
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [target.id])
        model.cleanup()
    }

    @MainActor
    @Test
    func testCleanupAfterCompletedSearchDoesNotForceSameContentRefresh() async throws {
        let target = makeTestFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let query = SearchNormalizer.normalize("target")
        let service = DelayedFileSearchService(
            delayedQuery: "delayed",
            delayedIDs: [],
            immediateIDsByQuery: [query: [target.id]]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        try await waitForSearchToFinish(model)
        let initialStartCount = await service.startCount(for: query)
        #expect(initialStartCount == 1)

        model.cleanup()
        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [target.id])
        let finalStartCount = await service.startCount(for: query)
        #expect(finalStartCount == 1)
    }

    @MainActor
    @Test
    func testSameContentUpdateDoesNotRestartActiveSearch() async throws {
        let target = makeTestFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let query = SearchNormalizer.normalize("target")
        let service = DelayedFileSearchService(
            delayedQuery: query,
            delayedIDs: [target.id],
            immediateIDsByQuery: [:]
        )
        defer { Task { try? await service.releaseDelayedResults() } }
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        try await service.waitUntilStarted(query)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await service.releaseDelayedResults()
        try await waitForSearchToFinish(model)
        #expect(model.displayedNodes.map(\.id) == [target.id])
        let startCount = await service.startCount(for: query)
        #expect(startCount == 1)
        model.cleanup()
    }

    @MainActor
    @Test
    func testSnapshotChangesPruneSearchIndexes() async throws {
        let firstRoot = makeTestDirectoryNode(id: "/first", name: "first", children: [])
        let firstStore = FileTreeStore(root: firstRoot)
        let firstSnapshot = makeTestSnapshot(root: firstRoot, store: firstStore)
        let secondRoot = makeTestDirectoryNode(id: "/second", name: "second", children: [])
        let secondStore = FileTreeStore(root: secondRoot)
        let secondSnapshot = makeTestSnapshot(root: secondRoot, store: secondStore)
        let service = PruningFileSearchService()
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        defer { model.cleanup() }

        model.updateContent(
            nodes: [],
            contentID: "\(firstSnapshot.id.uuidString)|\(firstRoot.id)",
            snapshot: firstSnapshot,
            fileTreeStore: firstStore
        )
        model.updateContent(
            nodes: [],
            contentID: "\(secondSnapshot.id.uuidString)|\(secondRoot.id)",
            snapshot: secondSnapshot,
            fileTreeStore: secondStore
        )

        try await waitForPruneCount(service, count: 1)
        let retainedSnapshotIDs = await service.retainedSnapshotIDs()
        #expect(retainedSnapshotIDs == [secondSnapshot.id])
    }
}

@MainActor
private func waitForSearchToFinish(
    _ model: FileBrowserModel,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil("file browser search", sourceLocation: sourceLocation) {
        !model.isSearchingEntireScan
    }
}

private func waitForStartCount(
    _ service: DelayedFileSearchService,
    query: String,
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil("file browser search to start", sourceLocation: sourceLocation) {
        await service.startCount(for: query) >= count
    }
}

private func waitForPruneCount(
    _ service: PruningFileSearchService,
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil("file browser search index pruning", sourceLocation: sourceLocation) {
        await service.retainedSnapshotIDs().count >= count
    }
}

private func waitForPruneCancellation(
    _ service: CancellablePruningFileSearchService,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil("file browser search index prune cancellation", sourceLocation: sourceLocation) {
        await service.didCancelPrune()
    }
}

private func assertCancellation<T>(
    of task: Task<T, Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await task.value
        Issue.record("Expected cancellation", sourceLocation: sourceLocation)
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Expected CancellationError, got \(error)", sourceLocation: sourceLocation)
    }
}

private func makeSearchTestFileNode(
    id: String,
    path: String,
    name: String,
    isSynthetic: Bool = false,
    url: URL? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: url ?? URL(filePath: path),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: 1,
        logicalSize: 1,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: isSynthetic,
        isAutoSummarized: false
    )
}

@MainActor
private func waitForCurrentContentsRefreshToFinish(
    _ model: FileBrowserModel,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil("current contents refresh", sourceLocation: sourceLocation) {
        !model.isRefreshingCurrentContents
    }
}

private actor DelayedFileSearchService: FileSearching {
    private let delayedQuery: String
    private let delayedIDs: [FileNodeRecord.ID]
    private let immediateIDsByQuery: [String: [FileNodeRecord.ID]]
    // Deliberately ignore cancellation to exercise rejection of late results.
    private var delayedContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var completedCancellationStates: [Bool] = []
    private var startCountByQuery: [String: Int] = [:]

    init(
        delayedQuery: String,
        delayedIDs: [FileNodeRecord.ID],
        immediateIDsByQuery: [String: [FileNodeRecord.ID]]
    ) {
        self.delayedQuery = delayedQuery
        self.delayedIDs = delayedIDs
        self.immediateIDsByQuery = immediateIDsByQuery
    }

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        let normalizedQuery = query.prepared().normalizedText
        markStarted(normalizedQuery)

        let matchedIDs: [FileNodeRecord.ID]
        if normalizedQuery == delayedQuery {
            await withCheckedContinuation { delayedContinuations.append($0) }
            completedCancellationStates.append(Task.isCancelled)
            matchedIDs = delayedIDs
        } else {
            matchedIDs = immediateIDsByQuery[normalizedQuery] ?? []
        }

        return FileBrowserResults.sorted(
            matchedIDs.compactMap { treeStore.nodesByID[$0] },
            sortOrder: sortOrder,
            fileTreeStore: treeStore
        )
    }

    func releaseDelayedResults() async throws {
        let expected = completedCancellationStates.count + delayedContinuations.count
        let continuations = delayedContinuations
        delayedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        try await waitUntil("released search work returned") {
            await self.completedCancellationStates.count == expected
        }
    }

    func waitUntilStarted(_ query: String) async throws {
        try await waitUntil("search started for \(query)") { await self.startCount(for: query) > 0 }
    }

    func startCount(for query: String) -> Int {
        startCountByQuery[query, default: 0]
    }

    private func markStarted(_ query: String) {
        startCountByQuery[query, default: 0] += 1
    }
}

private actor PruningFileSearchService: FileSearching {
    private var retainedIDs: [UUID?] = []

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        []
    }

    func pruneIndexes(keeping snapshotID: UUID?) {
        retainedIDs.append(snapshotID)
    }

    func retainedSnapshotIDs() -> [UUID?] {
        retainedIDs
    }
}

private actor CancellablePruningFileSearchService: FileSearching {
    private var pruneStarted = false
    private var pruneCancelled = false

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        []
    }

    func pruneIndexes(keeping snapshotID: UUID?) async {
        pruneStarted = true

        let (pending, lifetime) = AsyncStream<Void>.makeStream()
        defer { lifetime.finish() }
        for await _ in pending {}
        pruneCancelled = Task.isCancelled
    }

    func waitUntilPruneStarted() async throws {
        try await waitUntil("search index pruning started") { await self.pruneStarted }
    }

    func didCancelPrune() -> Bool {
        pruneCancelled
    }
}
