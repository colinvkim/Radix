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

protocol FileSearching: Sendable {
    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        normalizedQuery: String,
        includesPath: Bool,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord]

    func pruneIndexes(keeping snapshotID: UUID?) async
}

extension FileSearching {
    func pruneIndexes(keeping snapshotID: UUID?) async {}
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var currentContentsSearchText = ""
    @Published private(set) var entireScanSearchText = ""
    @Published private(set) var searchScope: FileBrowserFindTarget = .currentContents
    @Published private(set) var sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
    @Published private(set) var isSearchingEntireScan = false
    @Published private(set) var isRefreshingCurrentContents = false
    @Published private var displayState = FileBrowserDisplayState()

    private let searchService: any FileSearching
    private let currentContentsService = CurrentContentsSearchService()
    private let searchDebounceDuration: Duration
    private let currentContentsAsyncThreshold: Int
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
        currentContentsAsyncThreshold: Int = 512
    ) {
        self.searchService = searchService
        self.searchDebounceDuration = searchDebounceDuration
        self.currentContentsAsyncThreshold = currentContentsAsyncThreshold
    }

    deinit {
        searchTask?.cancel()
        searchIndexPruneTask?.cancel()
    }

    var activeSearchText: String {
        switch searchScope {
        case .currentContents:
            currentContentsSearchText
        case .entireScan:
            entireScanSearchText
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
        searchScope == .entireScan && !trimmedEntireScanSearchText.isEmpty
    }

    var isFilteringCurrentContents: Bool {
        searchScope == .currentContents && !trimmedCurrentContentsSearchText.isEmpty
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
            self.hiddenNodeIDs != hiddenNodeIDs ||
            !self.nodes.haveSameIDs(as: nodes) else {
            return
        }

        needsRefreshAfterCleanup = false
        contentRevision += 1
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

    func setActiveSearchText(_ text: String) {
        switch searchScope {
        case .currentContents:
            guard currentContentsSearchText != text else { return }
            currentContentsSearchText = text
        case .entireScan:
            guard entireScanSearchText != text else { return }
            entireScanSearchText = text
        }
        refreshDisplayedNodes()
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

    private var trimmedCurrentContentsSearchText: String {
        currentContentsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEntireScanSearchText: String {
        entireScanSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentDisplayContext: FileBrowserDisplayContext {
        FileBrowserDisplayContext(
            contentID: contentID,
            contentRevision: contentRevision,
            snapshotID: snapshotID,
            searchScope: searchScope,
            searchText: activeTrimmedSearchText,
            sortOrder: sortOrder,
            hiddenNodeIDs: hiddenNodeIDs
        )
    }

    private var activeTrimmedSearchText: String {
        switch searchScope {
        case .currentContents:
            trimmedCurrentContentsSearchText
        case .entireScan:
            trimmedEntireScanSearchText
        }
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
        let searchText = isFilteringCurrentContents ? trimmedCurrentContentsSearchText : ""
        let displayContext = currentDisplayContext
        let visibleNodes = Self.visibleNodes(
            nodes,
            hiddenNodeIDs: hiddenNodeIDs,
            fileTreeStore: fileTreeStore
        )

        guard shouldRefreshCurrentContentsAsynchronously(visibleNodes) else {
            setIsRefreshingCurrentContents(false)
            applyDisplayedNodes(
                FileBrowserResults.filteredAndSortedCurrentContents(
                    visibleNodes,
                    searchText: searchText,
                    sortOrder: sortOrder,
                    fileTreeStore: fileTreeStore
                ),
                context: displayContext
            )
            return
        }

        scheduleCurrentContentsRefresh(
            nodes: visibleNodes,
            searchText: searchText,
            displayContext: displayContext
        )
    }

    private func shouldRefreshCurrentContentsAsynchronously(_ nodes: [FileNodeRecord]) -> Bool {
        !nodes.isEmpty && nodes.count >= currentContentsAsyncThreshold
    }

    private func scheduleCurrentContentsRefresh(
        nodes: [FileNodeRecord],
        searchText: String,
        displayContext: FileBrowserDisplayContext
    ) {
        let sortOrder = sortOrder
        let fileTreeStore = fileTreeStore
        let request = FileBrowserDisplayRequest(
            generation: searchGeneration,
            displayContext: displayContext
        )
        let debounceDuration = searchText.isEmpty ? Duration.zero : searchDebounceDuration

        setIsRefreshingCurrentContents(true)
        searchTask = Task { [currentContentsService] in
            do {
                let refreshedNodes = try await currentContentsService.filteredAndSortedCurrentContents(
                    nodes,
                    searchText: searchText,
                    sortOrder: sortOrder,
                    fileTreeStore: fileTreeStore,
                    debounceDuration: debounceDuration
                )
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrent(request) else {
                        return
                    }

                    applyDisplayedNodes(refreshedNodes, context: request.displayContext)
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

        let searchText = trimmedEntireScanSearchText
        guard !searchText.isEmpty else {
            setIsSearchingEntireScan(false)
            rebuildCurrentContentsResults()
            return
        }

        let normalizedSearchText = SearchNormalizer.normalize(searchText)
        let includesPath = SearchNormalizer.queryIncludesPath(searchText)
        let sortOrder = sortOrder
        let debounceDuration = searchDebounceDuration
        let hiddenNodeIDs = hiddenNodeIDs
        let request = FileBrowserDisplayRequest(
            generation: searchGeneration,
            displayContext: currentDisplayContext
        )

        setIsSearchingEntireScan(true)
        searchTask = Task { [searchService] in
            do {
                try await Task.sleep(for: debounceDuration)
                let matchedNodes = try await searchService.search(
                    snapshotID: snapshotID,
                    treeStore: fileTreeStore,
                    normalizedQuery: normalizedSearchText,
                    includesPath: includesPath,
                    sortOrder: sortOrder
                )
                let visibleMatchedNodes = Self.visibleNodes(
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

                    applyDisplayedNodes(visibleMatchedNodes, context: request.displayContext)
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
        displayState = FileBrowserDisplayState(nodes: nodes, context: context)
    }

    private func setIsSearchingEntireScan(_ isSearching: Bool) {
        guard isSearchingEntireScan != isSearching else { return }
        isSearchingEntireScan = isSearching
    }

    private func setIsRefreshingCurrentContents(_ isRefreshing: Bool) {
        guard isRefreshingCurrentContents != isRefreshing else { return }
        isRefreshingCurrentContents = isRefreshing
    }

    private nonisolated static func visibleNodes(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?
    ) -> [FileNodeRecord] {
        guard !hiddenNodeIDs.isEmpty,
              let fileTreeStore else {
            return nodes
        }

        return nodes.filter { node in
            !fileTreeStore.isNodeOrDescendant(node.id, of: hiddenNodeIDs)
        }
    }
}

private struct FileBrowserDisplayRequest: Sendable {
    let generation: Int
    let displayContext: FileBrowserDisplayContext
}

private struct FileBrowserDisplayContext: Equatable, Sendable {
    let contentID: String
    let contentRevision: Int
    let snapshotID: UUID?
    let searchScope: FileBrowserFindTarget
    let searchText: String
    let sortOrder: [FileNodeTableComparator]
    let hiddenNodeIDs: Set<FileNodeRecord.ID>

    static let empty = FileBrowserDisplayContext(
        contentID: "",
        contentRevision: 0,
        snapshotID: nil,
        searchScope: .currentContents,
        searchText: "",
        sortOrder: [],
        hiddenNodeIDs: []
    )
}

private actor CurrentContentsSearchService {
    func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        searchText: String,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore?,
        debounceDuration: Duration
    ) async throws -> [FileNodeRecord] {
        try await Task.sleep(for: debounceDuration)
        return try FileBrowserResults.filteredAndSortedCurrentContents(
            nodes,
            searchText: searchText,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

private struct FileBrowserDisplayState {
    var nodes: [FileNodeRecord]
    var context: FileBrowserDisplayContext
    var indexesByNodeID: [FileNodeRecord.ID: Int]
    var displayValueCache: FileBrowserDisplayValueCache

    init(
        nodes: [FileNodeRecord] = [],
        context: FileBrowserDisplayContext = .empty
    ) {
        var uniqueNodes: [FileNodeRecord] = []
        var indexesByNodeID: [FileNodeRecord.ID: Int] = [:]
        uniqueNodes.reserveCapacity(nodes.count)
        indexesByNodeID.reserveCapacity(nodes.count)

        for node in nodes where indexesByNodeID[node.id] == nil {
            indexesByNodeID[node.id] = uniqueNodes.count
            uniqueNodes.append(node)
        }

        self.nodes = uniqueNodes
        self.context = context
        self.indexesByNodeID = indexesByNodeID
        self.displayValueCache = FileBrowserDisplayValueCache()
    }

    func node(id: FileNodeRecord.ID) -> FileNodeRecord? {
        guard let index = indexesByNodeID[id],
              nodes.indices.contains(index) else {
            return nil
        }
        return nodes[index]
    }

    func displayValues(
        for node: FileNodeRecord,
        hidesPackageContents: Bool = false
    ) -> FileBrowserNodeDisplayValues {
        let cacheKey = FileBrowserDisplayValueCacheKey(
            nodeID: node.id,
            hidesPackageContents: hidesPackageContents
        )
        if let cachedValues = displayValueCache.valuesByKey[cacheKey] {
            return cachedValues
        }

        let values = FileBrowserNodeDisplayValues(
            node: node,
            hidesPackageContents: hidesPackageContents
        )
        displayValueCache.valuesByKey[cacheKey] = values
        return values
    }

}

private final class FileBrowserDisplayValueCache {
    var valuesByKey: [FileBrowserDisplayValueCacheKey: FileBrowserNodeDisplayValues] = [:]
}

private struct FileBrowserDisplayValueCacheKey: Hashable {
    let nodeID: FileNodeRecord.ID
    let hidesPackageContents: Bool
}

enum FileBrowserPackageContents {
    nonisolated static func areHidden(
        for node: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> Bool {
        node.isPackage &&
            node.isDirectory &&
            !node.isAutoSummarized &&
            (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0) &&
            fileTreeStore?.containsChildren(id: node.id) != true
    }
}

struct FileBrowserNodeDisplayValues: Equatable, Sendable {
    let allocatedSize: String
    let descendantCount: String
    let modifiedDate: String

    init(node: FileNodeRecord, hidesPackageContents: Bool = false) {
        allocatedSize = RadixFormatters.size(node.allocatedSize)
        descendantCount = Self.descendantCountText(
            for: node,
            hidesPackageContents: hidesPackageContents
        )
        modifiedDate = RadixFormatters.date(node.lastModified)
    }

    private static func descendantCountText(
        for node: FileNodeRecord,
        hidesPackageContents: Bool
    ) -> String {
        if hidesPackageContents && node.isPackage {
            return "—"
        }
        if node.isDirectory {
            return "\(node.descendantFileCount)"
        }
        if node.isSynthetic || node.isSymbolicLink {
            return "—"
        }
        return "1"
    }
}

private extension [FileNodeRecord] {
    func haveSameIDs(as other: [FileNodeRecord]) -> Bool {
        guard count == other.count else { return false }

        for index in indices where self[index].id != other[index].id {
            return false
        }

        return true
    }
}

actor FileSearchService: FileSearching {
    private var indexes: [UUID: FileSearchIndex] = [:]

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        normalizedQuery: String,
        includesPath: Bool,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        guard !normalizedQuery.isEmpty else { return [] }

        var index: FileSearchIndex
        if let cachedIndex = indexes[snapshotID] {
            index = cachedIndex
        } else {
            index = try await makeIndex(treeStore: treeStore)
            indexes = [snapshotID: index]
        }

        var matchedNodes: [FileNodeRecord] = []
        matchedNodes.reserveCapacity(min(index.entries.count, 256))

        for (offset, entry) in index.entries.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            if entry.normalizedNameKindHaystack.contains(normalizedQuery) {
                if let node = treeStore.nodesByID[entry.id] {
                    matchedNodes.append(node)
                }
                continue
            }

            guard includesPath else { continue }

            let normalizedPath: String
            if let cachedPath = index.normalizedPathsByID[entry.id] {
                normalizedPath = cachedPath
            } else {
                normalizedPath = SearchNormalizer.normalize(treeStore.nodesByID[entry.id]?.url.path ?? "")
                index.normalizedPathsByID[entry.id] = normalizedPath
            }

            if normalizedPath.contains(normalizedQuery) {
                if let node = treeStore.nodesByID[entry.id] {
                    matchedNodes.append(node)
                }
            }
        }

        if includesPath {
            indexes[snapshotID] = index
        }

        try Task.checkCancellation()
        let sortedNodes = try FileBrowserResults.sorted(
            matchedNodes,
            sortOrder: sortOrder,
            fileTreeStore: treeStore,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
        try Task.checkCancellation()
        return sortedNodes
    }

    func pruneIndexes(keeping snapshotID: UUID?) {
        guard let snapshotID else {
            indexes.removeAll()
            return
        }

        indexes = indexes.filter { $0.key == snapshotID }
    }

    private func makeIndex(treeStore: FileTreeStore) async throws -> FileSearchIndex {
        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(max(treeStore.nodeCount - 1, 0))

        var offset = 0
        try treeStore.forEachIndexedNodeID(excludingRoot: true) { id in
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            offset += 1

            guard let node = treeStore.nodesByID[id] else { return }
            entries.append(FileSearchEntry(
                id: id,
                normalizedNameKindHaystack: SearchNormalizer.normalize(
                    [node.name, node.itemKind].joined(separator: "\n")
                )
            ))
        }

        return FileSearchIndex(
            entries: entries,
            normalizedPathsByID: [:]
        )
    }
}

struct FileNodeTableComparator: Equatable, SortComparator, Sendable {
    enum Field: Equatable, Sendable {
        case name
        case allocatedSize
        case itemKind
        case descendantFileCount
        case lastModified
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> ComparisonResult {
        compare(lhs, rhs, fileTreeStore: nil)
    }

    func compare(
        _ lhs: FileNodeRecord,
        _ rhs: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .allocatedSize:
            FileNodeSortComparison.compare(lhs.allocatedSize, rhs.allocatedSize)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        case .descendantFileCount:
            FileNodeSortComparison.compare(
                displayedDescendantFileCount(for: lhs, fileTreeStore: fileTreeStore),
                displayedDescendantFileCount(for: rhs, fileTreeStore: fileTreeStore)
            )
        case .lastModified:
            FileNodeSortComparison.compareOptional(lhs.lastModified, rhs.lastModified)
        }

        let orderedResult = FileNodeSortComparison.applying(order, to: result)
        switch orderedResult {
        case .orderedSame:
            return FileNodeSortComparison.fallback(
                lhsName: lhs.name,
                lhsID: lhs.id,
                rhsName: rhs.name,
                rhsID: rhs.id
            )
        default:
            return orderedResult
        }
    }

    private func displayedDescendantFileCount(
        for node: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> Int {
        FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
            ? 0
            : node.descendantFileCount
    }
}

private enum FileNodeSortComparison {
    nonisolated static func applying(_ order: SortOrder, to result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }

        return switch result {
        case .orderedAscending:
            .orderedDescending
        case .orderedDescending:
            .orderedAscending
        case .orderedSame:
            .orderedSame
        @unknown default:
            result
        }
    }

    nonisolated static func fallback(
        lhsName: String,
        lhsID: String,
        rhsName: String,
        rhsID: String
    ) -> ComparisonResult {
        let nameResult = lhsName.localizedStandardCompare(rhsName)
        switch nameResult {
        case .orderedSame:
            return lhsID.localizedStandardCompare(rhsID)
        default:
            return nameResult
        }
    }

    nonisolated static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }

    nonisolated static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return compare(lhs, rhs)
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedAscending
        case (_?, nil):
            return .orderedDescending
        }
    }
}

enum FileBrowserResults {
    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        searchText: String,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        (try? filteredAndSortedCurrentContents(
            nodes,
            searchText: searchText,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        searchText: String,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [FileNodeRecord] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearchText.isEmpty else {
            try cancellationCheck()
            return try sorted(
                nodes,
                sortOrder: sortOrder,
                fileTreeStore: fileTreeStore,
                cancellationCheck: cancellationCheck
            )
        }

        var filteredNodes: [FileNodeRecord] = []
        filteredNodes.reserveCapacity(min(nodes.count, 256))

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }

            if node.name.localizedStandardContains(trimmedSearchText) ||
                node.url.path.localizedStandardContains(trimmedSearchText) ||
                node.itemKind.localizedStandardContains(trimmedSearchText) {
                filteredNodes.append(node)
            }
        }

        try cancellationCheck()
        return try sorted(
            filteredNodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        (try? sorted(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )) ?? nodes
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [FileNodeRecord] {
        try cancellationCheck()
        guard !sortOrder.isEmpty else { return nodes }

        let preparedNodes = try preparedSortNodes(
            nodes,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        let sortedNodes = preparedNodes.sorted { lhs, rhs in
            for comparator in sortOrder {
                switch lhs.compare(rhs, using: comparator) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                @unknown default:
                    continue
                }
            }
            return false
        }
        try cancellationCheck()
        return sortedNodes.map(\.node)
    }

    private nonisolated static func preparedSortNodes(
        _ nodes: [FileNodeRecord],
        fileTreeStore: FileTreeStore?,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [PreparedSortNode] {
        var preparedNodes: [PreparedSortNode] = []
        preparedNodes.reserveCapacity(nodes.count)

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            preparedNodes.append(PreparedSortNode(node: node, fileTreeStore: fileTreeStore))
        }

        return preparedNodes
    }

    private struct PreparedSortNode {
        let node: FileNodeRecord
        let name: String
        let id: String
        let allocatedSize: Int64
        let itemKind: String
        let descendantFileCount: Int
        let lastModified: Date?

        nonisolated init(node: FileNodeRecord, fileTreeStore: FileTreeStore?) {
            self.node = node
            self.name = node.name
            self.id = node.id
            self.allocatedSize = node.allocatedSize
            self.itemKind = node.itemKind
            self.descendantFileCount = FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
                ? 0
                : node.descendantFileCount
            self.lastModified = node.lastModified
        }

        nonisolated func compare(_ rhs: PreparedSortNode, using comparator: FileNodeTableComparator) -> ComparisonResult {
            let result: ComparisonResult = switch comparator.field {
            case .name:
                name.localizedStandardCompare(rhs.name)
            case .allocatedSize:
                FileNodeSortComparison.compare(allocatedSize, rhs.allocatedSize)
            case .itemKind:
                itemKind.localizedStandardCompare(rhs.itemKind)
            case .descendantFileCount:
                FileNodeSortComparison.compare(descendantFileCount, rhs.descendantFileCount)
            case .lastModified:
                FileNodeSortComparison.compareOptional(lastModified, rhs.lastModified)
            }

            let orderedResult = FileNodeSortComparison.applying(comparator.order, to: result)
            switch orderedResult {
            case .orderedSame:
                return FileNodeSortComparison.fallback(
                    lhsName: name,
                    lhsID: id,
                    rhsName: rhs.name,
                    rhsID: rhs.id
                )
            default:
                return orderedResult
            }
        }
    }
}

enum SearchNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    nonisolated static func queryIncludesPath(_ query: String) -> Bool {
        query.contains("/") || query.contains("\\")
    }
}

private struct FileSearchIndex {
    let entries: [FileSearchEntry]
    var normalizedPathsByID: [FileNodeRecord.ID: String]
}

private struct FileSearchEntry {
    let id: FileNodeRecord.ID
    let normalizedNameKindHaystack: String
}
