import Foundation
import Testing

@testable import RadixCore

@MainActor
struct BackgroundReleaseQueueTests {
    @Test
    func testRetiredOwnershipReleasesOffMainThreadAfterMutationUnwinds() async {
        weak var weakValue: ReleaseProbe?
        await confirmation("Retired value released off the main thread") { released in
            let releases = BackgroundReleaseQueue()
            var value: ReleaseProbe? = ReleaseProbe {
                #expect(!Thread.isMainThread)
                released()
            }
            weakValue = value
            releases.discard(value)
            value = nil
            #expect(weakValue != nil)
            #expect(releases.isReleasing)
            await releases.waitForPendingReleases()
            #expect(weakValue == nil)
            #expect(!releases.isReleasing)
        }
    }

    @Test
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
        #expect(releases.isReleasing)
        #expect(browser.displayedNodes.isEmpty)

        browser.setActiveQuery(FileBrowserQuery())
        navigation.updateScanContext(snapshot: snapshot)
        try await Task.sleep(for: .milliseconds(10))
        #expect(browser.isRefreshingCurrentContents)
        #expect(browser.displayedNodes.isEmpty)
        #expect(navigation.isLoadingTableNodes)
        #expect(navigation.tableNodes.isEmpty)
        // Supersede both requests while cleanup remains blocked.
        browser.setActiveQuery(FileBrowserQuery(itemKind: .folder))
        navigation.reset()
        queue.resume()
        isSuspended = false
        await releases.waitForPendingReleases()
        try await waitUntil { !browser.isRefreshingCurrentContents }
        #expect(browser.displayedNodes.isEmpty)
        #expect(browser.isDisplayingCurrentResults)
        #expect(!(navigation.isLoadingTableNodes))
        #expect(navigation.tableNodes.isEmpty)
    }

    @Test
    func testSmallScopesRetireTheirLargeBackingStore() async throws {
        let siblings = (0..<600).map { makeTestFileNode(id: "/root/\($0)", name: "\($0)") }
        let leaf = makeTestFileNode(id: "/root/small/file", name: "file")
        let folder = makeTestDirectoryNode(id: "/root/small", name: "small", children: [leaf])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder] + siblings)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [folder] + siblings, folder.id: [leaf]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let scope = try #require(snapshot.scoped(to: ScanTarget(url: folder.url)))
        #expect(scope.treeStore.nodeCount == 2)
        #expect(scope.treeStore.backingNodeCapacity == 603)
        let releases = BackgroundReleaseQueue()
        let navigation = WorkspaceNavigationModel(releases: releases)
        let browser = FileBrowserModel(releases: releases)
        navigation.updateScanContext(snapshot: scope)
        browser.updateContent(nodes: [leaf], contentID: folder.id, snapshot: scope, fileTreeStore: scope.treeStore)
        #expect(!(releases.isReleasing))
        navigation.reset()
        #expect(releases.isReleasing)
        await releases.waitForPendingReleases()
        browser.updateContent(nodes: [], contentID: "empty", snapshot: nil, fileTreeStore: nil)
        #expect(releases.isReleasing)
        await releases.waitForPendingReleases()
    }
}

private nonisolated final class ReleaseProbe: Sendable {
    let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}
