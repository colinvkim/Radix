import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?

    @FocusState private var isCurrentContentsSearchFieldFocused: Bool
    @State private var currentContentsSearchText = ""
    @State private var entireScanSearchText = ""
    @State private var isEntireScanSearchPresented = false
    @State private var sortOrder = [KeyPathComparator(\FileNode.allocatedSize, order: .reverse)]
    @State private var displayedNodes: [FileNode] = []
    @State private var displayedNodeLookup: [FileNode.ID: FileNode] = [:]

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
                rebuildDisplayedNodes()
            }
        )
    }

    private var isShowingEntireScanResults: Bool {
        !entireScanSearchText.isEmpty
    }

    var body: some View {
        Group {
            if nodes.isEmpty {
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
                            resultCount: displayedNodes.count
                        ) {
                            entireScanSearchText = ""
                            isEntireScanSearchPresented = true
                            rebuildDisplayedNodes()
                        }
                    }

                    Divider()

                    if displayedNodes.isEmpty {
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
        .searchable(
            text: $entireScanSearchText,
            isPresented: $isEntireScanSearchPresented,
            prompt: Text("Search entire scan")
        )
        .focusedSceneValue(\.fileListFilterAction) { target in
            switch target {
            case .currentContents:
                isCurrentContentsSearchFieldFocused = true
            case .entireScan:
                isEntireScanSearchPresented = true
            }
        }
        .onAppear(perform: rebuildDisplayedNodes)
        .onChange(of: nodes) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: currentContentsSearchText) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: entireScanSearchText) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: appModel.snapshot?.id) { _, _ in
            rebuildDisplayedNodes()
        }
    }

    private var noResultsDescription: String {
        if isShowingEntireScanResults {
            return "No items anywhere in this scan match your search."
        }
        return "Try a different filter or clear the current contents filter."
    }

    private var searchCandidates: [FileNode] {
        if isShowingEntireScanResults {
            return appModel.fileTreeIndex.nodesByID.values
                .filter { $0.id != appModel.fileTreeIndex.rootID }
        }
        return nodes
    }

    private func subtitle(for node: FileNode) -> String? {
        guard isShowingEntireScanResults else {
            return node.secondaryStatusText
        }

        let parentPath = appModel.fileTreeIndex.parent(of: node.id)?.url.path
        return parentPath ?? node.url.deletingLastPathComponent().path
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

    private func rebuildDisplayedNodes() {
        let sortedNodes = searchCandidates.sorted(using: sortOrder)
        let searchText = isShowingEntireScanResults ? entireScanSearchText : currentContentsSearchText
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

        displayedNodes = filteredNodes
        displayedNodeLookup = Dictionary(uniqueKeysWithValues: filteredNodes.map { ($0.id, $0) })
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

            Text(resultCount == 1 ? "1 match" : "\(resultCount) matches")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

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
