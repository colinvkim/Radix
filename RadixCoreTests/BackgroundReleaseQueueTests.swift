import XCTest
@testable import RadixCore

@MainActor
final class BackgroundReleaseQueueTests: XCTestCase {
    func testRetiredOwnershipReleasesOffMainThreadAfterMutationUnwinds() async {
        let releases = BackgroundReleaseQueue()
        let released = expectation(description: "Retired value released")
        var value: ReleaseProbe? = ReleaseProbe {
            XCTAssertFalse(Thread.isMainThread)
            released.fulfill()
        }
        weak var weakValue = value
        releases.discard(value)
        value = nil
        XCTAssertNotNil(weakValue)
        XCTAssertTrue(releases.isReleasing)
        await releases.waitForPendingReleases()
        await fulfillment(of: [released], timeout: 1)
        XCTAssertNil(weakValue)
        XCTAssertFalse(releases.isReleasing)
    }

    func testNavigationAndBrowserWaitForRetiredBuffersBeforePreparingMore() async throws {
        let queue = DispatchQueue(label: "blocked-buffer-release")
        let releases = BackgroundReleaseQueue(queue: queue)
        let files = (0..<600).map { makeTestFileNode(id: "/root/\($0)", name: "\($0)") }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: files)
        let store = FileTreeStore(root: root, childrenByID: [root.id: files])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let navigation = WorkspaceNavigationModel(releases: releases)
        let browser = FileBrowserModel(searchDebounceDuration: .zero, releases: releases)
        browser.updateContent(nodes: files, contentID: root.id, snapshot: snapshot, fileTreeStore: store)
        try await waitUntil { !browser.isRefreshingCurrentContents }
        queue.suspend()
        var isSuspended = true
        defer { if isSuspended { queue.resume() } }
        browser.setActiveQuery(FileBrowserQuery(itemKind: .folder))
        try await waitUntil { !browser.isRefreshingCurrentContents }
        XCTAssertTrue(releases.isReleasing)
        XCTAssertTrue(browser.displayedNodes.isEmpty)

        browser.setActiveQuery(FileBrowserQuery())
        navigation.updateScanContext(snapshot: snapshot)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(browser.isRefreshingCurrentContents)
        XCTAssertTrue(browser.displayedNodes.isEmpty)
        XCTAssertTrue(navigation.isLoadingTableNodes)
        XCTAssertTrue(navigation.tableNodes.isEmpty)
        // Supersede both requests while cleanup remains blocked.
        browser.setActiveQuery(FileBrowserQuery(itemKind: .folder))
        navigation.reset()
        queue.resume()
        isSuspended = false
        await releases.waitForPendingReleases()
        try await waitUntil { !browser.isRefreshingCurrentContents }
        XCTAssertTrue(browser.displayedNodes.isEmpty)
        XCTAssertTrue(browser.isDisplayingCurrentResults)
        XCTAssertFalse(navigation.isLoadingTableNodes)
        XCTAssertTrue(navigation.tableNodes.isEmpty)
    }

    func testSmallScopesRetireTheirLargeBackingStore() async throws {
        let siblings = (0..<600).map { makeTestFileNode(id: "/root/\($0)", name: "\($0)") }
        let leaf = makeTestFileNode(id: "/root/small/file", name: "file")
        let folder = makeTestDirectoryNode(id: "/root/small", name: "small", children: [leaf])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder] + siblings)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [folder] + siblings, folder.id: [leaf]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let scope = try XCTUnwrap(snapshot.scoped(to: ScanTarget(url: folder.url)))
        XCTAssertEqual(scope.treeStore.nodeCount, 2)
        XCTAssertEqual(scope.treeStore.backingNodeCapacity, 603)
        let releases = BackgroundReleaseQueue()
        let navigation = WorkspaceNavigationModel(releases: releases)
        let browser = FileBrowserModel(releases: releases)
        navigation.updateScanContext(snapshot: scope)
        browser.updateContent(nodes: [leaf], contentID: folder.id, snapshot: scope, fileTreeStore: scope.treeStore)
        XCTAssertFalse(releases.isReleasing)
        navigation.reset()
        XCTAssertTrue(releases.isReleasing)
        await releases.waitForPendingReleases()
        browser.updateContent(nodes: [], contentID: "empty", snapshot: nil, fileTreeStore: nil)
        XCTAssertTrue(releases.isReleasing)
        await releases.waitForPendingReleases()
    }
}

private nonisolated final class ReleaseProbe: Sendable {
    let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}
