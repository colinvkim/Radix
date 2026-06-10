import Combine
import XCTest
@testable import RadixCore

final class FileBrowserModelTests: XCTestCase {
    @MainActor
    func testCurrentContentsSortsFiltersAndBuildsSelectionLookup() {
        let small = makeBrowserFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeBrowserFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let nested = makeBrowserFileNode(id: "/root/Folder/nested.txt", name: "nested.txt", size: 20)
        let folder = makeBrowserDirectoryNode(id: "/root/Folder", name: "Folder", children: [nested])
        let model = FileBrowserModel()

        model.updateContent(
            nodes: [small, large, folder],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        XCTAssertEqual(model.displayedNodes.map(\.id), [large.id, folder.id, small.id])
        XCTAssertEqual(model.displayedNodeLookup[large.id]?.name, "large.log")

        model.setActiveSearchText("small")
        XCTAssertEqual(model.displayedNodes.map(\.id), [small.id])

        model.setActiveSearchText("")
        model.setSortOrder([FileNodeTableComparator(field: .name)])
        XCTAssertEqual(model.displayedNodes.map(\.id), [folder.id, large.id, small.id])
    }

    func testCurrentContentsFiltersBeforeReturningSortedMatches() {
        let smallMatch = makeBrowserFileNode(id: "/root/matches/small.txt", name: "small.txt", size: 10)
        let largeMatch = makeBrowserFileNode(id: "/root/matches/large.txt", name: "large.txt", size: 30)
        let ignored = makeBrowserFileNode(id: "/root/ignored.bin", name: "ignored.bin", size: 100)

        let result = FileBrowserResults.filteredAndSortedCurrentContents(
            [smallMatch, ignored, largeMatch],
            searchText: "matches",
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )

        XCTAssertEqual(result.map(\.id), [largeMatch.id, smallMatch.id])
    }

    @MainActor
    func testLargeCurrentContentsFilterDebouncesAndIgnoresStaleQuery() async throws {
        let small = makeBrowserFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeBrowserFileNode(id: "/root/large.log", name: "large.log", size: 30)
        let other = makeBrowserFileNode(id: "/root/other.bin", name: "other.bin", size: 20)
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
    func testLargeCurrentContentsUpdateWithSameContentIDMarksRowsStale() async throws {
        let old = makeBrowserFileNode(id: "/root/old.txt", name: "old.txt", size: 10)
        let new = makeBrowserFileNode(id: "/root/new.txt", name: "new.txt", size: 20)
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
    func testContentUpdatePublishesRowsAndLookupTogether() {
        let small = makeBrowserFileNode(id: "/root/small.txt", name: "small.txt", size: 10)
        let large = makeBrowserFileNode(id: "/root/large.log", name: "large.log", size: 30)
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
        XCTAssertEqual(model.displayedNodeLookup[small.id]?.name, small.name)
        XCTAssertEqual(publishCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testDisplayStateBuildsRowPresentationValues() {
        let modifiedDate = Date(timeIntervalSince1970: 1_234_567)
        let file = makeBrowserFileNode(
            id: "/root/file.txt",
            name: "file.txt",
            size: 1_024,
            lastModified: modifiedDate
        )
        let folder = makeBrowserDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [
                makeBrowserFileNode(id: "/root/folder/a.txt", name: "a.txt", size: 1),
                makeBrowserFileNode(id: "/root/folder/b.txt", name: "b.txt", size: 1),
            ]
        )
        let model = FileBrowserModel()

        model.updateContent(
            nodes: [file, folder],
            contentID: "snapshot|/root",
            snapshot: nil,
            fileTreeStore: nil
        )

        let fileValues = model.displayValues(for: file)
        let folderValues = model.displayValues(for: folder)

        XCTAssertEqual(fileValues.allocatedSize, "1 KB")
        XCTAssertEqual(fileValues.descendantCount, "1")
        XCTAssertEqual(fileValues.modifiedDate, RadixFormatters.date(modifiedDate))
        XCTAssertEqual(folderValues.descendantCount, "2")
    }

    func testSearchServiceMatchesNameKindAndPathOnlyForPathQueries() async throws {
        let photo = makeBrowserFileNode(id: "/root/photos/vacation.jpg", name: "vacation.jpg", size: 20)
        let cache = makeBrowserFileNode(id: "/root/Library/Caches/cache.db", name: "cache.db", size: 10)
        let photos = makeBrowserDirectoryNode(id: "/root/photos", name: "photos", children: [photo])
        let library = makeBrowserDirectoryNode(id: "/root/Library", name: "Library", children: [cache])
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [photos, library])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [photos, library],
            photos.id: [photo],
            library.id: [cache],
        ])
        let service = FileSearchService()
        let snapshotID = UUID()

        let photoMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            normalizedQuery: SearchNormalizer.normalize("vacation"),
            includesPath: false,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertEqual(photoMatches.map(\.id), [photo.id])

        let nonPathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            normalizedQuery: SearchNormalizer.normalize("/Library/Caches"),
            includesPath: false,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertTrue(nonPathMatches.isEmpty)

        let pathMatches = try await service.search(
            snapshotID: snapshotID,
            treeStore: store,
            normalizedQuery: SearchNormalizer.normalize("/Library/Caches"),
            includesPath: true,
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )
        XCTAssertEqual(pathMatches.map(\.id), [cache.id])
    }

    @MainActor
    func testModelRunsEntireScanSearchThroughService() async throws {
        let smallTarget = makeBrowserFileNode(id: "/root/target-small.txt", name: "target-small.txt", size: 5)
        let largeTarget = makeBrowserFileNode(id: "/root/target-large.txt", name: "target-large.txt", size: 50)
        let other = makeBrowserFileNode(id: "/root/other.log", name: "other.log", size: 10)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [smallTarget, largeTarget, other])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [smallTarget, largeTarget, other]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url),
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
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
    func testDelayedEntireScanResultCannotReplaceNewerQuery() async throws {
        let slow = makeBrowserFileNode(id: "/root/slow.txt", name: "slow.txt", size: 5)
        let fast = makeBrowserFileNode(id: "/root/fast.txt", name: "fast.txt", size: 10)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [slow, fast])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [slow, fast]])
        let snapshot = makeBrowserSnapshot(root: root, store: store)
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
        let current = makeBrowserFileNode(id: "/root/current.log", name: "current.log", size: 10)
        let wholeScanOnly = makeBrowserFileNode(id: "/root/archive/target.txt", name: "target.txt", size: 20)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [current, wholeScanOnly])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [current, wholeScanOnly]])
        let snapshot = makeBrowserSnapshot(root: root, store: store)
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
    func testCancelSearchClearsLoadingState() async throws {
        let target = makeBrowserFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeBrowserSnapshot(root: root, store: store)
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

        model.cancelSearch()

        XCTAssertFalse(model.isSearchingEntireScan)
    }

    @MainActor
    func testForceRefreshRestartsCanceledSearchForSameContent() async throws {
        let target = makeBrowserFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeBrowserSnapshot(root: root, store: store)
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
        model.cancelSearch()

        model.updateContent(
            nodes: store.children(of: root.id),
            contentID: contentID,
            snapshot: snapshot,
            fileTreeStore: store,
            forceRefresh: true
        )

        try await waitForStartCount(service, query: query, count: 2)
        XCTAssertTrue(model.isSearchingEntireScan)
        model.cancelSearch()
    }

    @MainActor
    func testSameContentUpdateDoesNotRestartActiveSearch() async throws {
        let target = makeBrowserFileNode(id: "/root/target.txt", name: "target.txt", size: 20)
        let root = makeBrowserDirectoryNode(id: "/root", name: "root", children: [target])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [target]])
        let snapshot = makeBrowserSnapshot(root: root, store: store)
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
        model.cancelSearch()
    }

    @MainActor
    func testSnapshotChangesPruneSearchIndexes() async throws {
        let firstRoot = makeBrowserDirectoryNode(id: "/first", name: "first", children: [])
        let firstStore = FileTreeStore(root: firstRoot)
        let firstSnapshot = makeBrowserSnapshot(root: firstRoot, store: firstStore)
        let secondRoot = makeBrowserDirectoryNode(id: "/second", name: "second", children: [])
        let secondStore = FileTreeStore(root: secondRoot)
        let secondSnapshot = makeBrowserSnapshot(root: secondRoot, store: secondStore)
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
    for _ in 0..<100 {
        if !model.isSearchingEntireScan {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for file browser search.", file: file, line: line)
}

private func waitForStartCount(
    _ service: DelayedFileSearchService,
    query: String,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if await service.startCount(for: query) >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for file browser search to start.", file: file, line: line)
}

private func waitForPruneCount(
    _ service: PruningFileSearchService,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if await service.retainedSnapshotIDs().count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for file browser search index pruning.", file: file, line: line)
}

@MainActor
private func waitForCurrentContentsRefreshToFinish(
    _ model: FileBrowserModel,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if !model.isRefreshingCurrentContents {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for current contents refresh.", file: file, line: line)
}

private func makeBrowserFileNode(
    id: String,
    name: String,
    size: Int64,
    lastModified: Date? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        isPackage: false,
        isAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private func makeBrowserDirectoryNode(id: String, name: String, children: [FileNodeRecord]) -> FileNodeRecord {
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

private func makeBrowserSnapshot(root: FileNodeRecord, store: FileTreeStore) -> ScanSnapshot {
    ScanSnapshot(
        target: ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: [],
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
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
        normalizedQuery: String,
        includesPath: Bool,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        markStarted(normalizedQuery)

        let matchedIDs: [FileNodeRecord.ID]
        if normalizedQuery == delayedQuery {
            try? await Task.sleep(for: .milliseconds(40))
            matchedIDs = delayedIDs
        } else {
            matchedIDs = immediateIDsByQuery[normalizedQuery] ?? []
        }

        return matchedIDs
            .compactMap { treeStore.nodesByID[$0] }
            .sorted(using: sortOrder)
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
        normalizedQuery: String,
        includesPath: Bool,
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
