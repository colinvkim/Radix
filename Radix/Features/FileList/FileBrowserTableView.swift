import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?

    @FocusState private var isSearchFieldFocused: Bool
    @State private var currentContentsSearchText = ""
    @State private var entireScanSearchText = ""
    @State private var searchScope: FileBrowserFindTarget = .currentContents
    @State private var sortOrder = [FileNodeTableComparator(field: .allocatedSize, order: .reverse)]
    @State private var displayedNodes: [FileNode] = []
    @State private var displayedNodeLookup: [FileNode.ID: FileNode] = [:]
    @State private var indexedEntireScanSnapshotID: UUID?
    @State private var entireScanNodeIDs: [FileNode.ID] = []
    @State private var entireScanNormalizedHaystacks: [FileNode.ID: String] = [:]
    @State private var isSearchingEntireScan = false
    @State private var entireScanIndexTask: Task<Void, Never>?
    @State private var entireScanSearchTask: Task<Void, Never>?
    private var tableSelection: Binding<String?> {
        Binding(
            get: {
                guard let selection, displayedNodeLookup[selection] != nil else { return nil }
                return selection
            },
            set: { newValue in
                if selection != newValue {
                    selection = newValue
                }
            }
        )
    }

    private var sortOrderBinding: Binding<[FileNodeTableComparator]> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                sortOrder = newValue
                refreshDisplayedNodes()
            }
        )
    }

    private var isShowingEntireScanResults: Bool {
        searchScope == .entireScan && !entireScanSearchText.isEmpty
    }

    private var isFilteringCurrentContents: Bool {
        searchScope == .currentContents && !currentContentsSearchText.isEmpty
    }

    private var activeSearchText: Binding<String> {
        Binding(
            get: {
                switch searchScope {
                case .currentContents:
                    currentContentsSearchText
                case .entireScan:
                    entireScanSearchText
                }
            },
            set: { newValue in
                switch searchScope {
                case .currentContents:
                    currentContentsSearchText = newValue
                case .entireScan:
                    entireScanSearchText = newValue
                }
            }
        )
    }

    private var showsTableChrome: Bool {
        !nodes.isEmpty || isShowingEntireScanResults
    }

    var body: some View {
        Group {
            if !showsTableChrome {
                ContentUnavailableView(
                    "Nothing to Show",
                    systemImage: "folder",
                    description: Text("Zoom into a directory with contents to populate this table.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    SearchFilterBar(
                        scope: $searchScope,
                        text: activeSearchText,
                        isFocused: $isSearchFieldFocused
                    )

                    Divider()

                    if isShowingEntireScanResults && isSearchingEntireScan && displayedNodes.isEmpty {
                        VStack {
                            Spacer()
                            ProgressView("Searching Entire Scan…")
                                .controlSize(.small)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if displayedNodes.isEmpty {
                        ContentUnavailableView(
                            "No Matching Items",
                            systemImage: "magnifyingglass",
                            description: Text(noResultsDescription)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(displayedNodes, selection: tableSelection, sortOrder: sortOrderBinding) {
                            TableColumn("Name", sortUsing: FileNodeTableComparator(field: .name)) { node in
                                NameCell(
                                    node: node,
                                    subtitleOverride: subtitle(for: node)
                                )
                            }
                            .width(min: 260, ideal: 360)

                            TableColumn("Allocated", sortUsing: FileNodeTableComparator(field: .allocatedSize)) { node in
                                Text(RadixFormatters.size(node.allocatedSize))
                                    .monospacedDigit()
                            }
                            .width(min: 110, ideal: 130)

                            TableColumn("Kind", sortUsing: FileNodeTableComparator(field: .itemKind)) { node in
                                Text(node.itemKind)
                            }
                            .width(min: 110, ideal: 130)

                            TableColumn("Files") { node in
                                Text(descendantCountText(for: node))
                            }
                            .width(min: 70, ideal: 80)

                            TableColumn("Modified") { node in
                                Text(RadixFormatters.date(node.lastModified))
                            }
                            .width(min: 150, ideal: 180)
                        }
                        .accessibilityLabel("Contents table")
                        .accessibilityHint("Select a row to inspect it. Double-click a folder to zoom in.")
                        .contextMenu(forSelectionType: FileNode.ID.self) { selectedIDs in
                            if let selectedID = selectedIDs.first,
                               let selectedNode = displayedNodeLookup[selectedID] {
                                Button("Reveal in Finder", systemImage: "finder") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.revealSelectedInFinder()
                                }
                                .disabled(!selectedNode.supportsFileActions)

                                Button("Open", systemImage: "arrow.up.forward.app") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.openSelected()
                                }
                                .disabled(!selectedNode.supportsFileActions)

                                Button("Zoom In", systemImage: "magnifyingglass") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.zoomIntoSelection()
                                }
                                .disabled(!selectedNode.isDirectory)

                                Divider()

                                Button("Move to Trash", systemImage: "trash") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.requestMoveSelectedToTrash()
                                }
                                .disabled(!selectedNode.supportsMoveToTrash)

                                Button("Copy Path", systemImage: "document.on.document") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.copySelectedPath()
                                }
                                .disabled(!selectedNode.supportsFileActions)
                            }
                        } primaryAction: { selectedIDs in
                            guard let selectedID = selectedIDs.first,
                                  let selectedNode = displayedNodeLookup[selectedID] else {
                                return
                            }

                            appModel.select(nodeID: selectedID)

                            if selectedNode.isDirectory {
                                appModel.zoomIntoSelection()
                            } else if selectedNode.supportsFileActions {
                                appModel.openSelected()
                            }
                        }
                    }
                }
            }
        }
        .focusedSceneValue(\.fileListFilterAction) { target in
            searchScope = target
            isSearchFieldFocused = true
        }
        .onAppear {
            refreshDisplayedNodes()
        }
        .onChange(of: nodes, updateFilter)
        .onChange(of: currentContentsSearchText, updateFilter)
        .onChange(of: entireScanSearchText, updateFilter)
        .onChange(of: searchScope, updateFilter)
        .onChange(of: appModel.snapshot?.id) { _, _ in
            indexedEntireScanSnapshotID = nil
            entireScanNodeIDs = []
            entireScanNormalizedHaystacks = [:]
            refreshDisplayedNodes()
        }
        .onDisappear {
            entireScanIndexTask?.cancel()
            entireScanSearchTask?.cancel()
        }
    }

    private var noResultsDescription: String {
        if isShowingEntireScanResults {
            return "No items anywhere in this scan match your search."
        }
        return "Try a different filter or clear the current contents filter."
    }

    private func updateFilter() {
        refreshDisplayedNodes()
    }

    private func subtitle(for node: FileNode) -> String? {
        guard isShowingEntireScanResults else {
            return node.secondaryStatusText
        }

        let parentByID = appModel.fileTreeIndex.parentByID
        let nodesByID = appModel.fileTreeIndex.nodesByID
        return parentByID[node.id]
            .flatMap { nodesByID[$0]?.url.path } ?? node.url.deletingLastPathComponent().path
    }

    private func descendantCountText(for node: FileNode) -> String {
        if node.isDirectory {
            return "\(node.descendantFileCount)"
        }
        if node.isSynthetic || node.isSymbolicLink {
            return "—"
        }
        return "1"
    }

    private func refreshDisplayedNodes() {
        entireScanSearchTask?.cancel()

        if isShowingEntireScanResults {
            ensureEntireScanIndexThenSearch()
        } else {
            isSearchingEntireScan = false
            rebuildCurrentContentsResults()
        }
    }

    private func rebuildCurrentContentsResults() {
        let sortedNodes = nodes.sorted(using: sortOrder)
        let searchText = isFilteringCurrentContents ? currentContentsSearchText : ""
        let filteredNodes: [FileNode]

        if searchText.isEmpty {
            filteredNodes = sortedNodes
        } else {
            filteredNodes = sortedNodes.filter { node in
                node.name.localizedStandardContains(searchText) ||
                    node.url.path.localizedStandardContains(searchText) ||
                    node.itemKind.localizedStandardContains(searchText)
            }
        }

        applyDisplayedNodes(filteredNodes)
    }

    private func ensureEntireScanIndexThenSearch() {
        let snapshotID = appModel.snapshot?.id

        guard let snapshotID else {
            indexedEntireScanSnapshotID = nil
            entireScanNodeIDs = []
            isSearchingEntireScan = false
            applyDisplayedNodes([])
            return
        }

        if indexedEntireScanSnapshotID == snapshotID {
            scheduleEntireScanSearch()
            return
        }

        rebuildEntireScanSearchIndex(for: snapshotID)
    }

    private func rebuildEntireScanSearchIndex(for snapshotID: UUID) {
        entireScanIndexTask?.cancel()
        let nodesByID = appModel.fileTreeIndex.nodesByID
        let rootID = appModel.fileTreeIndex.rootID

        if isShowingEntireScanResults {
            isSearchingEntireScan = true
            applyDisplayedNodes([])
        }

        entireScanIndexTask = Task {
            let nodeIDs: [FileNode.ID] = await Task.detached(priority: .userInitiated) { () -> [FileNode.ID] in
                nodesByID.keys.filter { $0 != rootID }
            }.value

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                indexedEntireScanSnapshotID = snapshotID
                entireScanNodeIDs = nodeIDs
                if self.appModel.snapshot?.id != snapshotID {
                    self.entireScanNormalizedHaystacks = [:]
                }

                if self.appModel.snapshot?.id == snapshotID, self.isShowingEntireScanResults {
                    scheduleEntireScanSearch()
                }
            }
        }
    }

    private func scheduleEntireScanSearch() {
        let searchText = entireScanSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !searchText.isEmpty else {
            isSearchingEntireScan = false
            rebuildCurrentContentsResults()
            return
        }

        let nodeIDs = entireScanNodeIDs
        let normalizedSearchText = SearchNormalizer.normalize(searchText)
        let snapshotID = appModel.snapshot?.id
        let nodesByID = appModel.fileTreeIndex.nodesByID
        let cachedHaystacks = entireScanNormalizedHaystacks

        if nodeIDs.isEmpty {
            isSearchingEntireScan = false
            applyDisplayedNodes([])
            return
        }

        isSearchingEntireScan = true

        entireScanSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))

            let searchResult = await Task.detached(priority: .userInitiated) {
                var updatedHaystacks = cachedHaystacks
                var matchedIDs: [FileNode.ID] = []

                for id in nodeIDs {
                    guard let node = nodesByID[id] else { continue }

                    let haystack: String
                    if let cached = updatedHaystacks[id] {
                        haystack = cached
                    } else {
                        haystack = SearchNormalizer.normalize(
                            [node.name, node.url.path, node.itemKind].joined(separator: "\n")
                        )
                        updatedHaystacks[id] = haystack
                    }

                    if haystack.contains(normalizedSearchText) {
                        matchedIDs.append(id)
                    }
                }

                return EntireScanSearchResult(
                    matchedIDs: matchedIDs,
                    normalizedHaystacks: updatedHaystacks
                )
            }.value

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard self.appModel.snapshot?.id == snapshotID,
                      SearchNormalizer.normalize(self.entireScanSearchText) == normalizedSearchText else {
                    return
                }

                self.entireScanNormalizedHaystacks = searchResult.normalizedHaystacks
                let matchedNodes = searchResult.matchedIDs.compactMap { nodesByID[$0] }
                let sortedNodes = matchedNodes.sorted(using: sortOrder)
                applyDisplayedNodes(sortedNodes)
                isSearchingEntireScan = false
            }
        }
    }

    private func applyDisplayedNodes(_ nodes: [FileNode]) {
        displayedNodes = nodes
        displayedNodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
}

private struct EntireScanSearchResult {
    let matchedIDs: [FileNode.ID]
    let normalizedHaystacks: [FileNode.ID: String]
}

private struct FileNodeTableComparator: SortComparator, Sendable {
    enum Field: Sendable {
        case name
        case allocatedSize
        case itemKind
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FileNode, _ rhs: FileNode) -> ComparisonResult {
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

private enum SearchNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct SearchFilterBar: View {
    @Binding var scope: FileBrowserFindTarget
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    private var scopeLabel: String {
        switch scope {
        case .currentContents:
            "Current Contents"
        case .entireScan:
            "Entire Scan"
        }
    }

    private var prompt: String {
        switch scope {
        case .currentContents:
            "Filter current contents"
        case .entireScan:
            "Search entire scan"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Current Contents") {
                    scope = .currentContents
                    isFocused = true
                }

                Button("Entire Scan") {
                    scope = .entireScan
                    isFocused = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scope == .currentContents ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                    Text(scopeLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct NameCell: View {
    let node: FileNode
    let subtitleOverride: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory || node.isSynthetic ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)

                if let statusText = subtitleOverride ?? node.secondaryStatusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(searchSubtitleColor)
                        .lineLimit(1)
                }
            }

            if node.isAutoSummarized {
                ExpandSummarizedButton(node: node)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var searchSubtitleColor: Color {
        if subtitleOverride != nil {
            return .secondary
        }
        return node.isSynthetic ? .secondary : .orange
    }
}

/// Button that appears next to auto-summarized directories, allowing users to expand them fully.
private struct ExpandSummarizedButton: View {
    let node: FileNode
    @EnvironmentObject private var appModel: AppModel
    @State private var isExpanding = false

    var body: some View {
        Button(action: expandFolder) {
            Image(systemName: "arrowshape.turn.up.right.circle.fill")
                .foregroundStyle(.blue)
                .help("Expand '\(node.name)' to scan all \(node.descendantFileCount) files")
        }
        .buttonStyle(.plain)
        .disabled(isExpanding)
        .overlay {
            if isExpanding {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func expandFolder() {
        isExpanding = true
        appModel.expandSummarizedNode(node) {
            isExpanding = false
        }
    }
}
