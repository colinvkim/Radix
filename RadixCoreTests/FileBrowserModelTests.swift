import Combine
import XCTest
@testable import RadixCore

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

    func testCurrentContentsFiltersBeforeReturningSortedMatches() {
        let smallMatch = makeTestFileNode(id: "/root/matches/small.txt", name: "small.txt", size: 10)
        let largeMatch = makeTestFileNode(id: "/root/matches/large.txt", name: "large.txt", size: 30)
        let ignored = makeTestFileNode(id: "/root/ignored.bin", name: "ignored.bin", size: 100)

        let result = FileBrowserResults.filteredAndSortedCurrentContents(
            [smallMatch, ignored, largeMatch],
            searchText: "matches",
            sortOrder: [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
        )

        XCTAssertEqual(result.map(\.id), [largeMatch.id, smallMatch.id])
    }

    func testEqualSortValuesFallBackToNameAndID() async throws {
        let beta = makeTestFileNode(id: "/root/beta.txt", name: "Beta.txt", size: 10)
        let alphaB = makeTestFileNode(id: "/root/b-alpha.txt", name: "Alpha.txt", size: 10)
        let alphaA = makeTestFileNode(id: "/root/a-alpha.txt", name: "Alpha.txt", size: 10)
        let sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]

        let currentContents = FileBrowserResults.filteredAndSortedCurrentContents(
            [beta, alphaB, alphaA],
            searchText: "",
            sortOrder: sortOrder
        )
        XCTAssertEqual(currentContents.map(\.id), [alphaA.id, alphaB.id, beta.id])

        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [beta, alphaB, alphaA])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [beta, alphaB, alphaA]])
        let service = FileSearchService()
        let searchResults = try await service.search(
            snapshotID: UUID(),
            treeStore: store,
            normalizedQuery: SearchNormalizer.normalize("txt"),
            includesPath: false,
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
            searchText: "",
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
            searchText: "",
            sortOrder: [FileNodeTableComparator(field: .descendantFileCount, order: .reverse)],
            fileTreeStore: visiblePackageStore
        )
        XCTAssertEqual(visibleFileCountResults.map(\.id), [hiddenPackage.id, largeFolder.id, oldFile.id])

        let modifiedResults = FileBrowserResults.filteredAndSortedCurrentContents(
            [newFile, unknownFile, oldFile],
            searchText: "",
            sortOrder: [FileNodeTableComparator(field: .lastModified)]
        )
        XCTAssertEqual(modifiedResults.map(\.id), [unknownFile.id, oldFile.id, newFile.id])
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

private func waitForPruneCancellation(
    _ service: CancellablePruningFileSearchService,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if await service.didCancelPrune() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for file browser search index prune cancellation.", file: file, line: line)
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

private actor CancellablePruningFileSearchService: FileSearching {
    private var pruneStarted = false
    private var pruneCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        normalizedQuery: String,
        includesPath: Bool,
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
