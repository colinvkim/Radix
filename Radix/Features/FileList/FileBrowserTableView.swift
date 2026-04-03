import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?
    @Binding var entireScanSearchText: String
    @FocusState.Binding var isEntireScanSearchFieldFocused: Bool

    @FocusState private var isCurrentContentsSearchFieldFocused: Bool
    @State private var currentContentsSearchText = ""
    @State private var sortOrder = [KeyPathComparator(\FileNode.allocatedSize, order: .reverse)]
    @State private var displayedNodes: [FileNode] = []
    @State private var displayedNodeLookup: [FileNode.ID: FileNode] = [:]
    @State private var entireScanSearchEntries: [EntireScanSearchEntry] = []
    @State private var entireScanParentPathLookup: [FileNode.ID: String] = [:]
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

    private var sortOrderBinding: Binding<[KeyPathComparator<FileNode>]> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                sortOrder = newValue
                refreshDisplayedNodes()
            }
        )
    }

    private var isShowingEntireScanResults: Bool {
        !entireScanSearchText.isEmpty
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
                    CurrentContentsFilterBar(
                        text: $currentContentsSearchText,
                        isFocused: $isCurrentContentsSearchFieldFocused,
                        isDisabled: isShowingEntireScanResults
                    )

                    if isShowingEntireScanResults {
                        Divider()
                        EntireScanSearchBanner(
                            searchText: entireScanSearchText,
                            resultCount: displayedNodes.count,
                            isSearching: isSearchingEntireScan
                        ) {
                            entireScanSearchText = ""
                            refreshDisplayedNodes()
                        }
                    }

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
                            TableColumn("Name", value: \.name) { node in
                                NameCell(
                                    node: node,
                                    subtitleOverride: subtitle(for: node)
                                )
                            }
                            .width(min: 260, ideal: 360)

                            TableColumn("Allocated", value: \.allocatedSize) { node in
                                Text(RadixFormatters.size(node.allocatedSize))
                                    .monospacedDigit()
                            }
                            .width(min: 110, ideal: 130)

                            TableColumn("Kind", value: \.itemKind) { node in
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
                                Button("Reveal in Finder") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.revealSelectedInFinder()
                                }
                                .disabled(!selectedNode.supportsFileActions)

                                Button("Open") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.openSelected()
                                }
                                .disabled(!selectedNode.supportsFileActions)

                                Button("Zoom In") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.zoomIntoSelection()
                                }
                                .disabled(!selectedNode.isDirectory)

                                Divider()

                                Button("Move to Trash") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.requestMoveSelectedToTrash()
                                }
                                .disabled(!selectedNode.supportsMoveToTrash)

                                Button("Copy Path") {
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
            switch target {
            case .currentContents:
                isCurrentContentsSearchFieldFocused = true
            case .entireScan:
                isEntireScanSearchFieldFocused = true
            }
        }
        .onAppear {
            rebuildEntireScanSearchIndex()
            refreshDisplayedNodes()
        }
        .onChange(of: nodes) { _, _ in
            refreshDisplayedNodes()
        }
        .onChange(of: currentContentsSearchText) { _, _ in
            refreshDisplayedNodes()
        }
        .onChange(of: entireScanSearchText) { _, _ in
            refreshDisplayedNodes()
        }
        .onChange(of: appModel.snapshot?.id) { _, _ in
            rebuildEntireScanSearchIndex()
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

    private func subtitle(for node: FileNode) -> String? {
        guard isShowingEntireScanResults else {
            return node.secondaryStatusText
        }

        return entireScanParentPathLookup[node.id] ?? node.url.deletingLastPathComponent().path
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
            scheduleEntireScanSearch()
        } else {
            isSearchingEntireScan = false
            rebuildCurrentContentsResults()
        }
    }

    private func rebuildCurrentContentsResults() {
        let sortedNodes = nodes.sorted(using: sortOrder)
        let searchText = currentContentsSearchText
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

    private func rebuildEntireScanSearchIndex() {
        entireScanIndexTask?.cancel()

        let snapshotID = appModel.snapshot?.id
        let nodesByID = appModel.fileTreeIndex.nodesByID
        let parentByID = appModel.fileTreeIndex.parentByID
        let rootID = appModel.fileTreeIndex.rootID

        guard snapshotID != nil else {
            entireScanSearchEntries = []
            return
        }

        if isShowingEntireScanResults {
            isSearchingEntireScan = true
            applyDisplayedNodes([])
        }

        entireScanIndexTask = Task {
            let entries: [EntireScanSearchEntry] = await Task.detached(priority: .userInitiated) { () -> [EntireScanSearchEntry] in
                Array(nodesByID.values).compactMap { node -> EntireScanSearchEntry? in
                    guard node.id != rootID else {
                        return nil
                    }

                    let parentPath = parentByID[node.id]
                        .flatMap { nodesByID[$0]?.url.path } ?? node.url.deletingLastPathComponent().path
                    let haystack = SearchNormalizer.normalize(
                        [node.name, node.url.path, node.itemKind].joined(separator: "\n")
                    )

                    return EntireScanSearchEntry(
                        node: node,
                        parentPath: parentPath,
                        searchHaystack: haystack
                    )
                }
            }.value

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                entireScanSearchEntries = entries
                entireScanParentPathLookup = Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.node.id, $0.parentPath) }
                )

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

        let searchEntries = entireScanSearchEntries
        let normalizedSearchText = SearchNormalizer.normalize(searchText)
        let snapshotID = appModel.snapshot?.id

        if searchEntries.isEmpty {
            isSearchingEntireScan = true
            applyDisplayedNodes([])
            return
        }

        isSearchingEntireScan = true

        entireScanSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))

            let filteredNodes = await Task.detached(priority: .userInitiated) {
                searchEntries.compactMap { entry in
                    entry.searchHaystack.contains(normalizedSearchText) ? entry.node : nil
                }
            }.value

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard self.appModel.snapshot?.id == snapshotID,
                      SearchNormalizer.normalize(self.entireScanSearchText) == normalizedSearchText else {
                    return
                }

                let sortedNodes = filteredNodes.sorted(using: sortOrder)
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

private struct EntireScanSearchEntry: Sendable {
    let node: FileNode
    let parentPath: String
    let searchHaystack: String
}

private enum SearchNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct CurrentContentsFilterBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label("Current Contents", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Filter current contents", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .disabled(isDisabled)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear current contents filter")
                .disabled(isDisabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct EntireScanSearchBanner: View {
    let searchText: String
    let resultCount: Int
    let isSearching: Bool
    let clearSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Entire Scan", systemImage: "magnifyingglass")
                .font(.caption.weight(.semibold))

            Text("Showing results for “\(searchText)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if isSearching {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                Text(resultCount == 1 ? "1 match" : "\(resultCount) matches")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Clear") {
                clearSearch()
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
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
