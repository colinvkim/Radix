import Combine
import XCTest
@testable import RadixCore

private extension FileBrowserModel {
    @MainActor
    func setActiveSearchText(_ text: String) {
        var query = activeQuery
        query.text = text
        setActiveQuery(query)
    }
}

final class FileBrowserModelTests: XCTestCase {
    @MainActor
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

        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, folder.id, small.id])
        XCTAssertEqual(model.displayedNode(id: large.id)?.name, "large.log")

        model.setActiveSearchText("small")
        XCTAssertEqual(model.displayedNodes.map(\.id), [small.id])

        model.setActiveSearchText("")
        model.setSortOrder([FileNodeTableComparator(field: .name)])
        XCTAssertEqual(model.displayedNodes.map(\.id), [folder.id, large.id, small.id])
    }

    @MainActor
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
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, small.id])
        XCTAssertEqual(model.displayedNode(id: small.id)?.allocatedSize, 10)

        let resizedSmall = makeTestFileNode(id: small.id, name: small.name, size: 100)
        model.updateContent(
            nodes: [resizedSmall, large],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        XCTAssertEqual(model.displayedNodes.map(\.id), [small.id, large.id])
        XCTAssertEqual(model.displayedNode(id: small.id)?.allocatedSize, 100)
    }

    func testCurrentContentsFiltersBeforeReturningSortedMatches() {
        let smallMatch = makeTestFileNode(id: "/root/matches/small.txt", name: "small-match.txt", size: 10)
        let largeMatch = makeTestFileNode(id: "/root/matches/large.txt", name: "large-match.txt", size: 30)
        let ignored = makeTestFileNode(id: "/root/ignored.bin", name: "ignored.bin", size: 100)

        let result = FileBrowserResults.filteredAndSortedCurrentContents(
            [smallMatch, ignored, largeMatch],
            query: FileBrowserQuery(text: "match"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )

        XCTAssertEqual(result.map(\.id), [largeMatch.id, smallMatch.id])
    }

    func testCurrentContentsSearchNormalizesCaseAccentsAndPathQueries() {
        let resume = makeTestFileNode(id: "/root/docs/resume.pdf", name: "Résumé.pdf", size: 10)
        let report = makeTestFileNode(id: "/root/reports/quarterly.pdf", name: "REPORT.PDF", size: 20)
        let cache = makeTestFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 30)
        let ignored = makeTestFileNode(id: "/root/other.bin", name: "other.bin", size: 40)
        let nodes = [resume, report, cache, ignored]
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]

        XCTAssertEqual(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "resume"),
                sortOrder: sortOrder
            ).map(\.id),
            [resume.id]
        )
        XCTAssertEqual(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "report"),
                sortOrder: sortOrder
            ).map(\.id),
            [report.id]
        )
        XCTAssertEqual(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "/library/caches"),
                sortOrder: sortOrder
            ).map(\.id),
            [cache.id]
        )
        XCTAssertTrue(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: "Library"),
                sortOrder: sortOrder
            ).isEmpty
        )
    }

    func testCurrentContentsAndEntireScanSearchUseSameNormalizedRules() async throws {
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
        let cases: [(query: String, expectedIDs: [String])] = [
            ("resume", [resume.id]),
            ("report", [report.id]),
            ("/library/caches", [cache.id]),
            ("\\library\\caches", [cache.id]),
            ("Library", [])
        ]

        for searchCase in cases {
            let currentContentsResults = FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                query: FileBrowserQuery(text: searchCase.query),
                sortOrder: sortOrder,
                fileTreeStore: store
            )
            let entireScanResults = try await service.search(
                snapshotID: snapshotID,
                treeStore: store,
                query: FileBrowserQuery(text: searchCase.query),
                sortOrder: sortOrder
            )

            XCTAssertEqual(
                currentContentsResults.map(\.id),
                searchCase.expectedIDs,
                "Current contents query: \(searchCase.query)"
            )
            XCTAssertEqual(
                entireScanResults.map(\.id),
                searchCase.expectedIDs,
                "Entire scan query: \(searchCase.query)"
            )
        }
    }

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
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: rootChildren,
            home.id: [visible],
        ])
        let scope = try XCTUnwrap(store.logicalScope(rootedAt: home.id))
        let service = await FileSearchService()
        let snapshotID = UUID()

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

        XCTAssertEqual(visibleResults.map(\.id), [visible.id])
        XCTAssertTrue(siblingResults.isEmpty)
        XCTAssertNil(scope.node(id: outside.id))
    }

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
        let store = FileTreeStore(root: root, childrenByID: [
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

        XCTAssertEqual(currentContentsResults.map(\.id), [largeTarget.id])
        XCTAssertEqual(entireScanResults.map(\.id), [largeTarget.id])
    }

    func testAllocatedSizeRelationsHandleExactBoundary() {
        let boundary: Int64 = 500_000_000

        XCTAssertFalse(FileBrowserAllocatedSizeFilter(relation: .greaterThan, bytes: boundary).matches(boundary))
        XCTAssertTrue(FileBrowserAllocatedSizeFilter(relation: .atLeast, bytes: boundary).matches(boundary))
        XCTAssertFalse(FileBrowserAllocatedSizeFilter(relation: .lessThan, bytes: boundary).matches(boundary))
        XCTAssertTrue(FileBrowserAllocatedSizeFilter(relation: .atMost, bytes: boundary).matches(boundary))
    }

    func testSizeUnitsPreserveEditablePrecisionAndRejectInvalidByteCounts() {
        let fractionalKilobytes: Int64 = 1_500
        let unit = FileBrowserSizeUnit.bestUnit(for: fractionalKilobytes)
        let reopenedValue = Double(fractionalKilobytes) / Double(unit.bytes)

        XCTAssertEqual(unit, .kilobytes)
        XCTAssertEqual(unit.byteCount(for: reopenedValue), fractionalKilobytes)
        XCTAssertEqual(FileBrowserSizeUnit.bestUnit(for: 500_000_000), .megabytes)
        XCTAssertEqual(FileBrowserSizeUnit.bestUnit(for: 1_500_000_000), .gigabytes)
        XCTAssertEqual(FileBrowserSizeUnit.bestUnit(for: 1_234_560), .kilobytes)
        XCTAssertEqual(FileBrowserSizeUnit.kilobytes.byteCount(for: 1.234), 1_234)
        XCTAssertNil(FileBrowserSizeUnit.megabytes.byteCount(for: -.infinity))
        XCTAssertNil(FileBrowserSizeUnit.megabytes.byteCount(for: -1))
        XCTAssertNil(
            FileBrowserSizeUnit.kilobytes.byteCount(
                for: Double(Int64.max) / Double(FileBrowserSizeUnit.kilobytes.bytes)
            )
        )
    }

    func testStructuredKindClassificationDistinguishesSearchableItemTypes() {
        let file = makeTestFileNode(id: "/root/file", name: "file")
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [])
        let package = makeTestDirectoryNode(id: "/root/app", name: "app", children: [], isPackage: true)
        let symbolicLink = makeTestFileNode(id: "/root/link", name: "link", isSymbolicLink: true)
        let synthetic = makeTestFileNode(id: "/root/system-data", name: "system-data", isSynthetic: true)

        XCTAssertEqual(FileBrowserItemKindFilter.classification(for: file), .file)
        XCTAssertEqual(FileBrowserItemKindFilter.classification(for: folder), .folder)
        XCTAssertEqual(FileBrowserItemKindFilter.classification(for: package), .package)
        XCTAssertNil(FileBrowserItemKindFilter.classification(for: symbolicLink))
        XCTAssertNil(FileBrowserItemKindFilter.classification(for: synthetic))
    }

    @MainActor
    func testEntireScanSupportsStructuredFilterWithoutSearchText() async throws {
        let small = makeTestFileNode(id: "/root/small.bin", name: "small.bin", size: 100)
        let large = makeTestFileNode(id: "/root/large.bin", name: "large.bin", size: 1_000)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [large])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [small, folder])
        let store = FileTreeStore(root: root, childrenByID: [
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

        XCTAssertTrue(model.isShowingEntireScanResults)
        try await waitForSearchToFinish(model)
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id])
    }

    @MainActor
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
        XCTAssertEqual(model.activeQuery, FileBrowserQuery())

        model.setActiveQuery(entireScanQuery)
        model.setSearchScope(.currentContents)
        XCTAssertEqual(model.activeQuery, currentContentsQuery)

        model.clearActiveQuery()
        XCTAssertEqual(model.activeQuery, FileBrowserQuery())

        model.setSearchScope(.entireScan)
        XCTAssertEqual(model.activeQuery, entireScanQuery)
    }

    @MainActor
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
        XCTAssertEqual(model.displayedNodes.map(\.id), [visibleFile.id])

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await waitForCurrentContentsRefreshToFinish(model)
        XCTAssertEqual(model.displayedNodes.map(\.id), [hiddenFile.id, visibleFile.id])
    }

    func testHiddenNodeFilteringChecksCancellation() {
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: nodes)
        let store = FileTreeStore(root: root, childrenByID: [root.id: nodes])
        let probe = CancellationProbe(throwOnCheck: 3)

        XCTAssertThrowsError(
            try FileBrowserResults.visibleNodes(
                nodes,
                hiddenNodeIDs: [nodes[0].id],
                fileTreeStore: store,
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 3)
    }

    @MainActor
    func testEntireScanSearchHidesDiscardPileQueuedDescendants() async throws {
        let hiddenTarget = makeTestFileNode(id: "/root/folder/target-hidden.txt", name: "target-hidden.txt", size: 40)
        let hiddenFolder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [hiddenTarget])
        let visibleTarget = makeTestFileNode(id: "/root/target-visible.txt", name: "target-visible.txt", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hiddenFolder, visibleTarget])
        let store = FileTreeStore(root: root, childrenByID: [
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

        XCTAssertEqual(model.displayedNodes.map(\.id), [visibleTarget.id])
    }

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
        XCTAssertEqual(currentContents.map(\.id), [alphaA.id, alphaB.id, beta.id])

        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [beta, alphaB, alphaA])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [beta, alphaB, alphaA]])
        let service = await FileSearchService()
        let searchResults = try await service.search(
            snapshotID: UUID(),
            treeStore: store,
            query: FileBrowserQuery(text: "txt"),
            sortOrder: sortOrder
        )

        XCTAssertEqual(searchResults.map(\.id), [alphaA.id, alphaB.id, beta.id])
    }

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
                makeTestFileNode(id: "/root/small/a.txt", name: "a.txt", lastModified: older),
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
        XCTAssertEqual(fileCountResults.map(\.id), [largeFolder.id, oldFile.id, smallFolder.id, hiddenPackage.id])

        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [hiddenPackage, largeFolder, oldFile]
        )
        let visiblePackageStore = FileTreeStore(root: root, childrenByID: [
            root.id: [hiddenPackage, largeFolder, oldFile],
            hiddenPackage.id: packagePayloads,
        ])
        let visibleFileCountResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [largeFolder, hiddenPackage, oldFile],
            query: FileBrowserQuery(),
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)],
            fileTreeStore: visiblePackageStore
        )
        XCTAssertEqual(visibleFileCountResults.map(\.id), [hiddenPackage.id, largeFolder.id, oldFile.id])

        let modifiedResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [newFile, unknownFile, oldFile],
            query: FileBrowserQuery(),
            sortOrder: [FileNodeTableComparator(field: .lastModified)]
        )
        XCTAssertEqual(modifiedResults.map(\.id), [unknownFile.id, oldFile.id, newFile.id])
    }

    func testDisplayProjectionChecksCancellationDuringIndexing() {
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }
        let probe = CancellationProbe(throwOnCheck: 3)

        XCTAssertThrowsError(
            try FileBrowserDisplayProjection(
                nodes: nodes,
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 3)
    }

    func testCancellableSortThrowsBeforeSort() {
        let probe = CancellationProbe(throwOnCheck: 1)
        let node = makeTestFileNode(id: "/root/file.txt", name: "file.txt")

        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                [node],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 1)
    }

    func testCancellableSortThrowsDuringPreparation() {
        let probe = CancellationProbe(throwOnCheck: 3)
        let nodes = (0..<600).map { index in
            makeTestFileNode(id: "/root/file-\(index).txt", name: "file-\(index).txt")
        }

        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 3)
    }

    func testCancellableSortThrowsDuringResultProjection() {
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

        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .allocatedSize)],
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, secondProjectionCheck)
    }

    func testCancellableSortChecksBeforeEmptyProjectionAndAfterFinalChunk() {
        let emptyProbe = CancellationProbe(throwOnCheck: 3)
        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                [],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: emptyProbe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(emptyProbe.checkCount, 3)

        let node = makeTestFileNode(
            id: "/root/file.txt",
            name: "file.txt",
            size: 1
        )
        let finalChunkProbe = CancellationProbe(throwOnCheck: 5)
        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                [node],
                sortOrder: [FileNodeTableComparator(field: .name)],
                cancellationCheck: finalChunkProbe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(finalChunkProbe.checkCount, 5)
    }

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

        XCTAssertEqual(sortedNodes.map(\.id), nodes.reversed().map(\.id))

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
            return false // Allocated sizes are unique in this fixture.
        }
        XCTAssertEqual(
            FileBrowserResults.sorted(nodes, sortOrder: sortOrder).map(\.id),
            expected.map(\.id)
        )
    }

    func testCancellableSortChecksCancellationBetweenLargeRuns() {
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

        XCTAssertThrowsError(
            try FileBrowserResults.sorted(
                nodes,
                sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)],
                cancellationCheck: probe.check
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, firstCheckAfterOneSortedRun)
    }

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
        XCTAssertEqual(nameResults.map(\.id), [alpha.id, beta.id, folder.id])

        let sizeResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertEqual(sizeResults.map(\.id), [beta.id, folder.id, alpha.id])

        let kindResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .itemKind)]
        )
        XCTAssertEqual(kindResults.map(\.id), [alpha.id, beta.id, folder.id])

        let countResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)]
        )
        XCTAssertEqual(countResults.map(\.id), [folder.id, alpha.id, beta.id])

        let modifiedResults = FileBrowserResults.sorted(
            nodes,
            sortOrder: [FileNodeTableComparator(field: .lastModified)]
        )
        XCTAssertEqual(modifiedResults.map(\.id), [beta.id, folder.id, alpha.id])
    }

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
                FileNodeTableComparator(field: .allocatedSize, order: .reverse),
            ]
        )

        XCTAssertEqual(secondaryResult.map(\.id), [zeta.id, alpha.id])
        XCTAssertEqual(fallbackResult.map(\.id), [alpha.id, zeta.id])
    }

    @MainActor
    func testLargeCurrentContentsFilterDebouncesAndIgnoresStaleQuery() async throws {
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
        XCTAssertFalse(model.isDisplayingCurrentResults)
        try await waitForCurrentContentsRefreshToFinish(model)
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, other.id, small.id])

        model.setActiveSearchText("small")
        XCTAssertTrue(model.isRefreshingCurrentContents)
        XCTAssertFalse(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, other.id, small.id])

        model.setActiveSearchText("large")

        try await waitForCurrentContentsRefreshToFinish(model)
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id])

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id])
    }

    @MainActor
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

        XCTAssertTrue(model.isRefreshingCurrentContents)
        try await waitForCurrentContentsRefreshToFinish(model)
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, other.id, small.id])
    }

    @MainActor
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
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [old.id])

        model.updateContent(
            nodes: [new],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        XCTAssertTrue(model.isRefreshingCurrentContents)
        XCTAssertFalse(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [old.id])

        try await waitForCurrentContentsRefreshToFinish(model)
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [new.id])
    }

    @MainActor
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

        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, small.id])
        XCTAssertEqual(model.displayedNode(id: small.id)?.name, small.name)
        XCTAssertEqual(publishCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
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
                makeTestFileNode(id: "/root/Sample.app/Contents/MacOS/Sample", name: "Sample", size: 1),
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

        XCTAssertEqual(fileValues.allocatedSize, "1 KB")
        XCTAssertEqual(fileValues.descendantCount, "1")
        XCTAssertEqual(fileValues.modifiedDate, RadixFormatters.date(modifiedDate))
        XCTAssertEqual(folderValues.descendantCount, "2")
        XCTAssertEqual(visiblePackageValues.descendantCount, "1")
        XCTAssertEqual(hiddenPackageValues.descendantCount, "—")
    }

    func testSearchServiceMatchesNameKindAndPathOnlyForPathQueries() async throws {
        let photo = makeTestFileNode(id: "/root/photos/vacation.jpg", name: "vacation.jpg", size: 20)
        let cache = makeTestFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 10)
        let photos = makeTestDirectoryNode(id: "/root/photos", name: "photos", children: [photo])
        let library = makeTestDirectoryNode(id: "/root/Library", name: "Library", children: [cache])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [photos, library])
        let store = FileTreeStore(root: root, childrenByID: [
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
        XCTAssertEqual(photoMatches.map(\.id), [photo.id])

        let nonPathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: "Caches"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertTrue(nonPathMatches.isEmpty)

        let pathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            query: FileBrowserQuery(text: "/Library/Caches"),
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertEqual(pathMatches.map(\.id), [cache.id])
    }

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
        let store = FileTreeStore(root: root, childrenByID: [
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

            XCTAssertEqual(
                Set(results.map(\.id)),
                searchCase.expectedIDs,
                "Query: \(searchCase.query)"
            )
            XCTAssertEqual(results.count, searchCase.expectedIDs.count)
        }
    }

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

        XCTAssertEqual(originalMatches.map(\.name), ["alpha.txt"])
        XCTAssertEqual(replacementMatches.map(\.name), ["beta.txt"])
        XCTAssertTrue(stalePathMatches.isEmpty)
        XCTAssertEqual(restoredOriginalMatches.map(\.name), ["alpha.txt"])
    }

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
        XCTAssertEqual(repeated, baseline)

        await service.pruneIndexes(keeping: snapshotID)
        let retained = try await resultIDs()
        XCTAssertEqual(retained, baseline)

        await service.pruneIndexes(keeping: UUID())
        let rebuiltAfterSnapshotPrune = try await resultIDs()
        XCTAssertEqual(rebuiltAfterSnapshotPrune, baseline)

        await service.pruneIndexes(keeping: nil)
        let rebuiltAfterFullPrune = try await resultIDs()
        XCTAssertEqual(rebuiltAfterFullPrune, baseline)
    }

    func testSearchServiceHonorsPreCancellationAndRemainsReusable() async throws {
        let target = makeTestFileNode(id: "/root/target.txt", name: "target.txt")
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let service = await FileSearchService()
        let snapshotID = UUID()
        let query = FileBrowserQuery(text: "target")

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
        XCTAssertEqual(warmedResults.map(\.id), [target.id])

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
        XCTAssertEqual(repeatedResults, warmedResults)
    }

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
        let store = FileTreeStore(root: root, childrenByID: [
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

            XCTAssertEqual(results.map(\.id), expectedIDs, "Query: \(queryText)")
        }
    }

    @MainActor
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
        XCTAssertFalse(model.isDisplayingCurrentResults)

        try await waitForSearchToFinish(model)
        XCTAssertTrue(model.isDisplayingCurrentResults)
        XCTAssertEqual(model.displayedNodes.map(\.id), [largeTarget.id, smallTarget.id])
    }

    @MainActor
    func testEntireScanSearchRefreshesForNewTreeContentWithSameSnapshotAndVisibleRows() async throws {
        let visible = makeTestFileNode(id: "/root/visible.txt", name: "visible.txt", size: 10)
        let alpha = makeTestFileNode(id: "/root/archive/alpha.txt", name: "alpha.txt", size: 20)
        let archive = makeTestDirectoryNode(id: "/root/archive", name: "archive", children: [alpha])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [archive, visible])
        let store = FileTreeStore(root: root, childrenByID: [
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
        XCTAssertEqual(model.displayedNodes.map(\.id), [alpha.id])

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
        let updatedSnapshot = try XCTUnwrap(
            snapshot.replacingNode(id: archive.id, with: replacementStore)
        )

        model.updateContent(
            nodes: [visible],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: updatedSnapshot,
            fileTreeStore: updatedSnapshot.treeStore
        )
        try await waitForSearchToFinish(model)
        XCTAssertTrue(model.displayedNodes.isEmpty)

        model.setActiveSearchText("beta")
        try await waitForSearchToFinish(model)
        XCTAssertEqual(model.displayedNodes.map(\.id), [beta.id])
    }

    @MainActor
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("slow")
        await service.waitUntilStarted(slowQuery)

        model.setActiveSearchText("fast")

        try await waitForSearchToFinish(model)
        XCTAssertEqual(model.displayedNodes.map(\.id), [fast.id])

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.displayedNodes.map(\.id), [fast.id])
    }

    @MainActor
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)

        model.updateContent(
            nodes: [current],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)
        XCTAssertTrue(model.isSearchingEntireScan)

        model.setSearchScope(.currentContents)

        XCTAssertFalse(model.isSearchingEntireScan)
        XCTAssertEqual(model.displayedNodes.map(\.id), [current.id])

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.displayedNodes.map(\.id), [current.id])
    }

    @MainActor
    func testCleanupClearsLoadingState() async throws {
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)
        XCTAssertTrue(model.isSearchingEntireScan)

        model.cleanup()

        XCTAssertFalse(model.isSearchingEntireScan)
    }

    @MainActor
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)

        model.updateContent(
            nodes: [current],
            contentID: "\(snapshot.id.uuidString)|\(root.id)",
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)

        model.cleanup()

        XCTAssertFalse(model.isSearchingEntireScan)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.displayedNodes.map(\.id), [current.id])
    }

    @MainActor
    func testCleanupCancelsSearchIndexPruneTask() async throws {
        let service = CancellablePruningFileSearchService()
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
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
        await service.waitUntilPruneStarted()

        model.cleanup()

        try await waitForPruneCancellation(service)
    }

    @MainActor
    func testForceRefreshRestartsCanceledSearchForSameContent() async throws {
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)
        model.cleanup()

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store,
            forceRefresh: true
        )

        try await waitForStartCount(service, query: query, count: 2)
        XCTAssertTrue(model.isSearchingEntireScan)
        model.cleanup()
    }

    @MainActor
    func testSameContentUpdateRestartsCanceledSearchAfterCleanup() async throws {
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)
        model.cleanup()

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await waitForStartCount(service, query: query, count: 2)
        XCTAssertTrue(model.isSearchingEntireScan)
        model.cleanup()
    }

    @MainActor
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
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
        XCTAssertEqual(initialStartCount, 1)

        model.cleanup()
        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await Task.sleep(for: .milliseconds(20))
        let finalStartCount = await service.startCount(for: query)
        XCTAssertEqual(finalStartCount, 1)
    }

    @MainActor
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
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)
        let contentID = "\(snapshot.id.uuidString)|\(root.id)"

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )
        model.setSearchScope(.entireScan)
        model.setActiveSearchText("target")
        await service.waitUntilStarted(query)

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store
        )

        try await Task.sleep(for: .milliseconds(20))
        let startCount = await service.startCount(for: query)
        XCTAssertEqual(startCount, 1)
        model.cleanup()
    }

    @MainActor
    func testSnapshotChangesPruneSearchIndexes() async throws {
        let firstRoot = makeTestDirectoryNode(id: "/first", name: "first", children: [])
        let firstStore = FileTreeStore(root: firstRoot)
        let firstSnapshot = makeTestSnapshot(root: firstRoot, store: firstStore)
        let secondRoot = makeTestDirectoryNode(id: "/second", name: "second", children: [])
        let secondStore = FileTreeStore(root: secondRoot)
        let secondSnapshot = makeTestSnapshot(root: secondRoot, store: secondStore)
        let service = PruningFileSearchService()
        let model = FileBrowserModel(searchService: service, searchDebounceDuration: .zero)

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
        XCTAssertEqual(retainedSnapshotIDs, [secondSnapshot.id])
    }
}

@MainActor
private func waitForSearchToFinish(
    _ model: FileBrowserModel,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await waitUntil("file browser search", file: file, line: line) {
        !model.isSearchingEntireScan
    }
}

private func waitForStartCount(
    _ service: DelayedFileSearchService,
    query: String,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await waitUntil("file browser search to start", file: file, line: line) {
        await service.startCount(for: query) >= count
    }
}

private func waitForPruneCount(
    _ service: PruningFileSearchService,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await waitUntil("file browser search index pruning", file: file, line: line) {
        await service.retainedSnapshotIDs().count >= count
    }
}

private func waitForPruneCancellation(
    _ service: CancellablePruningFileSearchService,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await waitUntil("file browser search index prune cancellation", file: file, line: line) {
        await service.didCancelPrune()
    }
}

private func assertCancellation<T>(
    of task: Task<T, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
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
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await waitUntil("current contents refresh", file: file, line: line) {
        !model.isRefreshingCurrentContents
    }
}

private actor DelayedFileSearchService: FileSearching {
    private let delayedQuery: String
    private let delayedIDs: [FileNodeRecord.ID]
    private let immediateIDsByQuery: [String: [FileNodeRecord.ID]]
    private var startedQueries: Set<String> = []
    private var startCountByQuery: [String: Int] = [:]
    private var waitersByQuery: [String: [CheckedContinuation<Void, Never>]] = [:]

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
            try? await Task.sleep(for: .milliseconds(40))
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

    func waitUntilStarted(_ query: String) async {
        guard !startedQueries.contains(query) else { return }

        await withCheckedContinuation { continuation in
            waitersByQuery[query, default: []].append(continuation)
        }
    }

    func startCount(for query: String) -> Int {
        startCountByQuery[query, default: 0]
    }

    private func markStarted(_ query: String) {
        startCountByQuery[query, default: 0] += 1
        startedQueries.insert(query)
        waitersByQuery.removeValue(forKey: query)?.forEach { $0.resume() }
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
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

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
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            pruneCancelled = true
        }
    }

    func waitUntilPruneStarted() async {
        guard !pruneStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func didCancelPrune() -> Bool {
        pruneCancelled
    }
}
