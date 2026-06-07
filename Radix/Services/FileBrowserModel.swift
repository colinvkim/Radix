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
        includesPath: Bool
    ) async throws -> [FileNodeRecord.ID]
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var currentContentsSearchText = ""
    @Published private(set) var entireScanSearchText = ""
    @Published private(set) var searchScope: FileBrowserFindTarget = .currentContents
    @Published private(set) var sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
    @Published private(set) var isSearchingEntireScan = false
    @Published private var displayState = FileBrowserDisplayState()

    private let searchService: any FileSearching
    private let searchDebounceDuration: Duration
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var nodes: [FileNodeRecord] = []
    private var contentID = ""
    private var snapshotID: UUID?
    private var fileTreeStore: FileTreeStore?

    init(
        searchService: any FileSearching = FileSearchService(),
        searchDebounceDuration: Duration = .milliseconds(180)
    ) {
        self.searchService = searchService
        self.searchDebounceDuration = searchDebounceDuration
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

    var displayedNodeLookup: [FileNodeRecord.ID: FileNodeRecord] {
        displayState.lookup
    }

    func displayValues(for node: FileNodeRecord) -> FileBrowserNodeDisplayValues {
        displayState.displayValuesByID[node.id] ?? FileBrowserNodeDisplayValues(node: node)
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
        forceRefresh: Bool = false
    ) {
        let nextSnapshotID = snapshot?.id
        guard forceRefresh || self.contentID != contentID || snapshotID != nextSnapshotID || !self.nodes.haveSameIDs(as: nodes) else {
            return
        }

        self.nodes = nodes
        self.contentID = contentID
        snapshotID = nextSnapshotID
        self.fileTreeStore = fileTreeStore
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

    func cancelSearch() {
        cancelPendingSearch(clearLoading: true)
    }

    private func cancelPendingSearch(clearLoading: Bool) {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        if clearLoading {
            setIsSearchingEntireScan(false)
        }
    }

    private var trimmedCurrentContentsSearchText: String {
        currentContentsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEntireScanSearchText: String {
        entireScanSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshDisplayedNodes() {
        cancelPendingSearch(clearLoading: false)

        if isShowingEntireScanResults {
            scheduleEntireScanSearch()
        } else {
            setIsSearchingEntireScan(false)
            rebuildCurrentContentsResults()
        }
    }

    private func rebuildCurrentContentsResults() {
        let searchText = isFilteringCurrentContents ? trimmedCurrentContentsSearchText : ""
        applyDisplayedNodes(
            FileBrowserResults.filteredAndSortedCurrentContents(
                nodes,
                searchText: searchText,
                sortOrder: sortOrder
            )
        )
    }

    private func scheduleEntireScanSearch() {
        guard let snapshotID, let fileTreeStore else {
            setIsSearchingEntireScan(false)
            applyDisplayedNodes([])
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
        let generation = searchGeneration
        let debounceDuration = searchDebounceDuration

        setIsSearchingEntireScan(true)
        searchTask = Task { [searchService] in
            do {
                try await Task.sleep(for: debounceDuration)
                let matchedIDs = try await searchService.search(
                    snapshotID: snapshotID,
                    treeStore: fileTreeStore,
                    normalizedQuery: normalizedSearchText,
                    includesPath: includesPath
                )
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrentEntireScanSearch(
                            generation: generation,
                            snapshotID: snapshotID,
                            normalizedSearchText: normalizedSearchText,
                            sortOrder: sortOrder
                          ) else {
                        return
                    }

                    let matchedNodes = matchedIDs.compactMap { fileTreeStore.nodesByID[$0] }
                    applyDisplayedNodes(matchedNodes.sorted(using: sortOrder))
                    setIsSearchingEntireScan(false)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          isCurrentEntireScanSearch(
                            generation: generation,
                            snapshotID: snapshotID,
                            normalizedSearchText: normalizedSearchText,
                            sortOrder: sortOrder
                          ) else {
                        return
                    }

                    setIsSearchingEntireScan(false)
                    applyDisplayedNodes([])
                }
            }
        }
    }

    private func isCurrentEntireScanSearch(
        generation: Int,
        snapshotID: UUID,
        normalizedSearchText: String,
        sortOrder: [FileNodeTableComparator]
    ) -> Bool {
        searchGeneration == generation &&
            self.snapshotID == snapshotID &&
            searchScope == .entireScan &&
            SearchNormalizer.normalize(trimmedEntireScanSearchText) == normalizedSearchText &&
            self.sortOrder == sortOrder
    }

    private func applyDisplayedNodes(_ nodes: [FileNodeRecord]) {
        displayState = FileBrowserDisplayState(nodes: nodes)
    }

    private func setIsSearchingEntireScan(_ isSearching: Bool) {
        guard isSearchingEntireScan != isSearching else { return }
        isSearchingEntireScan = isSearching
    }
}

private struct FileBrowserDisplayState {
    var nodes: [FileNodeRecord]
    var lookup: [FileNodeRecord.ID: FileNodeRecord]
    var displayValuesByID: [FileNodeRecord.ID: FileBrowserNodeDisplayValues]

    init(nodes: [FileNodeRecord] = []) {
        var uniqueNodes: [FileNodeRecord] = []
        var lookup: [FileNodeRecord.ID: FileNodeRecord] = [:]
        var displayValuesByID: [FileNodeRecord.ID: FileBrowserNodeDisplayValues] = [:]
        uniqueNodes.reserveCapacity(nodes.count)
        lookup.reserveCapacity(nodes.count)
        displayValuesByID.reserveCapacity(nodes.count)

        for node in nodes where lookup[node.id] == nil {
            lookup[node.id] = node
            displayValuesByID[node.id] = FileBrowserNodeDisplayValues(node: node)
            uniqueNodes.append(node)
        }

        self.nodes = uniqueNodes
        self.lookup = lookup
        self.displayValuesByID = displayValuesByID
    }
}

struct FileBrowserNodeDisplayValues: Equatable, Sendable {
    let allocatedSize: String
    let descendantCount: String
    let modifiedDate: String

    init(node: FileNodeRecord) {
        allocatedSize = RadixFormatters.size(node.allocatedSize)
        descendantCount = Self.descendantCountText(for: node)
        modifiedDate = RadixFormatters.date(node.lastModified)
    }

    private static func descendantCountText(for node: FileNodeRecord) -> String {
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
        includesPath: Bool
    ) async throws -> [FileNodeRecord.ID] {
        guard !normalizedQuery.isEmpty else { return [] }

        var index: FileSearchIndex
        if let cachedIndex = indexes[snapshotID] {
            index = cachedIndex
        } else {
            index = try await makeIndex(treeStore: treeStore)
            indexes = [snapshotID: index]
        }

        var matchedIDs: [FileNodeRecord.ID] = []
        matchedIDs.reserveCapacity(min(index.entries.count, 256))

        for (offset, entry) in index.entries.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            if entry.normalizedNameKindHaystack.contains(normalizedQuery) {
                matchedIDs.append(entry.id)
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
                matchedIDs.append(entry.id)
            }
        }

        if includesPath {
            indexes[snapshotID] = index
        }

        return matchedIDs
    }

    private func makeIndex(treeStore: FileTreeStore) async throws -> FileSearchIndex {
        let indexedNodeIDs = treeStore.indexedNodeIDs(excludingRoot: true)
        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(indexedNodeIDs.count)

        for (offset, id) in indexedNodeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard let node = treeStore.nodesByID[id] else { continue }
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
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .allocatedSize:
            compare(lhs.allocatedSize, rhs.allocatedSize)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        }

        if order == .forward {
            return result
        }

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

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}

enum FileBrowserResults {
    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        searchText: String,
        sortOrder: [FileNodeTableComparator]
    ) -> [FileNodeRecord] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearchText.isEmpty else {
            return nodes.sorted(using: sortOrder)
        }

        return nodes.filter { node in
            node.name.localizedStandardContains(trimmedSearchText) ||
                node.url.path.localizedStandardContains(trimmedSearchText) ||
                node.itemKind.localizedStandardContains(trimmedSearchText)
        }
        .sorted(using: sortOrder)
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
