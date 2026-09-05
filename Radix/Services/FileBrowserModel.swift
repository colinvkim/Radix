//
//  FileBrowserModel.swift
//  Radix
//

import Combine
import Foundation

enum FileBrowserFindTarget: Equatable, Sendable {
    case currentContents
    case entireScan
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var currentContentsQuery = FileBrowserQuery()
    @Published private(set) var entireScanQuery = FileBrowserQuery()
    @Published private(set) var searchScope: FileBrowserFindTarget = .currentContents
    @Published private(set) var sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
    @Published private(set) var isSearchingEntireScan = false
    @Published private(set) var isRefreshingCurrentContents = false
    @Published private var displayState = FileBrowserDisplayState()

    private let searchService: any FileSearching
    private let displayService = FileBrowserDisplayService()
    private let searchDebounceDuration: Duration
    private let currentContentsAsyncThreshold: Int
    private let releases: BackgroundReleaseQueue
    private var searchTask: Task<Void, Never>?
    private var searchIndexPruneTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var nodes: [FileNodeRecord] = []
    private var contentID = ""
    private var contentRevision = 0
    private var snapshotID: UUID?
    private var fileTreeStore: FileTreeStore?
    private var hiddenNodeIDs: Set<FileNodeRecord.ID> = []
    private var needsRefreshAfterCleanup = false

    init(
        searchService: any FileSearching = FileSearchService(),
        searchDebounceDuration: Duration = .milliseconds(180),
        currentContentsAsyncThreshold: Int = 512,
        releases: BackgroundReleaseQueue = .shared
    ) {
        self.searchService = searchService
        self.searchDebounceDuration = searchDebounceDuration
        self.currentContentsAsyncThreshold = currentContentsAsyncThreshold
        self.releases = releases
    }

    deinit {
        searchTask?.cancel()
        searchIndexPruneTask?.cancel()
    }

    var activeQuery: FileBrowserQuery {
        switch searchScope {
        case .currentContents:
            currentContentsQuery
        case .entireScan:
            entireScanQuery
        }
    }

    var displayedNodes: [FileNodeRecord] {
        displayState.nodes
    }

    var isDisplayingCurrentResults: Bool {
        displayState.context == currentDisplayContext
    }

    func displayedNode(id: FileNodeRecord.ID) -> FileNodeRecord? {
        displayState.node(id: id)
    }

    func displayedNodes(ids: Set<FileNodeRecord.ID>) -> [FileNodeRecord] {
        displayState.nodes(ids: ids)
    }

    func displayValues(
        for node: FileNodeRecord,
        hidesPackageContents: Bool = false
    ) -> FileBrowserNodeDisplayValues {
        displayState.displayValues(for: node, hidesPackageContents: hidesPackageContents)
    }

    func packageContentsAreHidden(for node: FileNodeRecord) -> Bool {
        FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
    }

    var isShowingEntireScanResults: Bool {
        searchScope == .entireScan && entireScanQuery.isActive
    }

    var isFilteringCurrentContents: Bool {
        searchScope == .currentContents && currentContentsQuery.isActive
    }

    func updateContent(
        nodes: [FileNodeRecord],
        contentID: String,
        snapshot: ScanSnapshot?,
        fileTreeStore: FileTreeStore?,
        hiddenNodeIDs: Set<FileNodeRecord.ID> = [],
        forceRefresh: Bool = false
    ) {
        let nextSnapshotID = snapshot?.id
        let previousSnapshotID = snapshotID
        guard forceRefresh ||
            needsRefreshAfterCleanup ||
            self.contentID != contentID ||
            snapshotID != nextSnapshotID ||
            self.fileTreeStore?.contentID != fileTreeStore?.contentID ||
            self.hiddenNodeIDs != hiddenNodeIDs ||
            self.nodes != nodes else {
            return
        }

        needsRefreshAfterCleanup = false
        contentRevision += 1
        if self.nodes.count > 512 { releases.discard(self.nodes) }
        if self.fileTreeStore?.contentID != fileTreeStore?.contentID,
           let oldStore = self.fileTreeStore, oldStore.backingNodeCapacity > 512 {
            releases.discard(oldStore)
        }
        self.nodes = nodes
        self.contentID = contentID
        snapshotID = nextSnapshotID
        self.fileTreeStore = fileTreeStore
        self.hiddenNodeIDs = hiddenNodeIDs
        pruneSearchIndexesIfNeeded(previousSnapshotID: previousSnapshotID, nextSnapshotID: nextSnapshotID)
        refreshDisplayedNodes()
    }

    func setSearchScope(_ scope: FileBrowserFindTarget) {
        guard searchScope != scope else { return }
        searchScope = scope
        refreshDisplayedNodes()
    }

    func setActiveQuery(_ query: FileBrowserQuery) {
        switch searchScope {
        case .currentContents:
            guard currentContentsQuery != query else { return }
            currentContentsQuery = query
        case .entireScan:
            guard entireScanQuery != query else { return }
            entireScanQuery = query
        }
        refreshDisplayedNodes()
    }

    func clearActiveQuery() {
        setActiveQuery(FileBrowserQuery())
    }

    func setSortOrder(_ order: [FileNodeTableComparator]) {
        guard sortOrder != order else { return }
        sortOrder = order
        refreshDisplayedNodes()
    }

    func cleanup() {
        let canceledDisplayRefresh = isSearchingEntireScan || isRefreshingCurrentContents
        cancelPendingSearch(clearLoading: true)
        needsRefreshAfterCleanup = needsRefreshAfterCleanup || canceledDisplayRefresh
        searchIndexPruneTask?.cancel()
        searchIndexPruneTask = nil
    }

    private func pruneSearchIndexesIfNeeded(previousSnapshotID: UUID?, nextSnapshotID: UUID?) {
        guard previousSnapshotID != nil,
              previousSnapshotID != nextSnapshotID else { return }

        searchIndexPruneTask?.cancel()
        searchIndexPruneTask = Task { [searchService] in
            guard !Task.isCancelled else { return }
            await searchService.pruneIndexes(keeping: nextSnapshotID)
        }
    }

    private func cancelPendingSearch(clearLoading: Bool) {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        if clearLoading {
            setIsSearchingEntireScan(false)
            setIsRefreshingCurrentContents(false)
        }
    }

    private var currentDisplayContext: FileBrowserDisplayContext {
        FileBrowserDisplayContext(
            contentID: contentID,
            contentRevision: contentRevision,
            snapshotID: snapshotID,
            searchScope: searchScope,
            query: activeQuery,
            sortOrder: sortOrder,
            hiddenNodeIDs: hiddenNodeIDs
        )
    }

    private func refreshDisplayedNodes() {
        cancelPendingSearch(clearLoading: false)

        if isShowingEntireScanResults {
            setIsRefreshingCurrentContents(false)
            scheduleEntireScanSearch()
        } else {
            setIsSearchingEntireScan(false)
            rebuildCurrentContentsResults()
        }
    }

    private func rebuildCurrentContentsResults() {
        let query = isFilteringCurrentContents ? currentContentsQuery : FileBrowserQuery()
        let displayContext = currentDisplayContext

        guard shouldRefreshCurrentContentsAsynchronously(nodes) else {
            let visibleNodes = FileBrowserResults.visibleNodes(
                nodes,
                hiddenNodeIDs: hiddenNodeIDs,
                fileTreeStore: fileTreeStore
            )
            setIsRefreshingCurrentContents(false)
            applyDisplayedNodes(
                FileBrowserResults.filteredAndSortedCurrentContents(
                    visibleNodes,
                    query: query,
                    sortOrder: sortOrder,
                    fileTreeStore: fileTreeStore
                ),
                context: displayContext
            )
            return
        }

        scheduleCurrentContentsRefresh(
            nodes: nodes,
            query: query,
            displayContext: displayContext
        )
    }

    private func shouldRefreshCurrentContentsAsynchronously(_ nodes: [FileNodeRecord]) -> Bool {
        !nodes.isEmpty && nodes.count >= currentContentsAsyncThreshold
    }

    private func scheduleCurrentContentsRefresh(
        nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        displayContext: FileBrowserDisplayContext
    ) {
        let sortOrder = sortOrder
        let fileTreeStore = fileTreeStore
        let hiddenNodeIDs = hiddenNodeIDs
        let request = FileBrowserDisplayRequest(
            generation: searchGeneration,
            displayContext: displayContext
        )
        let debounceDuration = query.hasText ? searchDebounceDuration : Duration.zero

        setIsRefreshingCurrentContents(true)
        searchTask = Task.detached(priority: .userInitiated) { [weak self, displayService, releases] in
            do {
                await releases.waitForPendingReleases()
                try Task.checkCancellation()
                let projection = try await displayService.currentContentsProjection(
                    nodes,
                    query: query,
                    sortOrder: sortOrder,
                    hiddenNodeIDs: hiddenNodeIDs,
                    fileTreeStore: fileTreeStore,
                    debounceDuration: debounceDuration
                )
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrent(request) else {
                        return
                    }

                    applyDisplayedProjection(projection, context: request.displayContext)
                    setIsRefreshingCurrentContents(false)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrent(request) else {
                        return
                    }

                    setIsRefreshingCurrentContents(false)
                }
            }
        }
    }

    private func scheduleEntireScanSearch() {
        guard let snapshotID, let fileTreeStore else {
            setIsSearchingEntireScan(false)
            applyDisplayedNodes([], context: currentDisplayContext)
            return
        }

        let query = entireScanQuery
        guard query.isActive else {
            setIsSearchingEntireScan(false)
            rebuildCurrentContentsResults()
            return
        }

        let sortOrder = sortOrder
        let debounceDuration = query.hasText ? searchDebounceDuration : Duration.zero
        let hiddenNodeIDs = hiddenNodeIDs
        let request = FileBrowserDisplayRequest(
            generation: searchGeneration,
            displayContext: currentDisplayContext
        )

        setIsSearchingEntireScan(true)
        searchTask = Task.detached(priority: .userInitiated) { [weak self, searchService, displayService, releases] in
            do {
                try await Task.sleep(for: debounceDuration)
                await releases.waitForPendingReleases()
                try Task.checkCancellation()
                let matchedNodes = try await searchService.search(
                    snapshotID: snapshotID,
                    treeStore: fileTreeStore,
                    query: query,
                    sortOrder: sortOrder
                )
                let projection = try await displayService.projection(
                    matchedNodes,
                    hiddenNodeIDs: hiddenNodeIDs,
                    fileTreeStore: fileTreeStore
                )
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrent(request) else {
                        return
                    }

                    applyDisplayedProjection(projection, context: request.displayContext)
                    setIsSearchingEntireScan(false)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrent(request) else {
                        return
                    }

                    setIsSearchingEntireScan(false)
                    applyDisplayedNodes([], context: request.displayContext)
                }
            }
        }
    }

    private func isCurrent(_ request: FileBrowserDisplayRequest) -> Bool {
        searchGeneration == request.generation &&
            currentDisplayContext == request.displayContext
    }

    private func applyDisplayedNodes(
        _ nodes: [FileNodeRecord],
        context: FileBrowserDisplayContext
    ) {
        applyDisplayedProjection(
            FileBrowserDisplayProjection(nodes: nodes),
            context: context
        )
    }

    private func applyDisplayedProjection(
        _ projection: FileBrowserDisplayProjection,
        context: FileBrowserDisplayContext
    ) {
        if displayState.nodes.count > 512 {
            releases.discard((displayState.nodes, displayState.indexesByNodeID, displayState.displayValueCache))
        }
        displayState = FileBrowserDisplayState(projection: projection, context: context)
    }

    private func setIsSearchingEntireScan(_ isSearching: Bool) {
        guard isSearchingEntireScan != isSearching else { return }
        isSearchingEntireScan = isSearching
    }

    private func setIsRefreshingCurrentContents(_ isRefreshing: Bool) {
        guard isRefreshingCurrentContents != isRefreshing else { return }
        isRefreshingCurrentContents = isRefreshing
    }
}
