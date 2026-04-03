import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var searchScope: FileBrowserSearchScope = .currentContents
    @State private var isSearchPresented = false
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
            text: $searchText,
            isPresented: $isSearchPresented,
            prompt: searchPrompt
        )
        .searchScopes($searchScope) {
            Text(FileBrowserSearchScope.currentContents.title)
                .tag(FileBrowserSearchScope.currentContents)
            Text(FileBrowserSearchScope.entireScan.title)
                .tag(FileBrowserSearchScope.entireScan)
        }
        .focusedSceneValue(\.fileListFilterAction) { scope in
            searchScope = scope
            isSearchPresented = true
        }
        .onAppear(perform: rebuildDisplayedNodes)
        .onChange(of: nodes) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: searchText) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: searchScope) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: appModel.snapshot?.id) { _, _ in
            rebuildDisplayedNodes()
        }
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

    private var searchPrompt: Text {
        Text(searchScope == .currentContents ? "Filter current contents" : "Search entire scan")
    }

    private var noResultsDescription: String {
        switch searchScope {
        case .currentContents:
            return "Try a different filter or clear the current search."
        case .entireScan:
            return "No items in this scan match your search."
        }
    }

    private var searchCandidates: [FileNode] {
        switch searchScope {
        case .currentContents:
            return nodes
        case .entireScan:
            return appModel.fileTreeIndex.nodesByID.values
                .filter { $0.id != appModel.fileTreeIndex.rootID }
        }
    }

    private func subtitle(for node: FileNode) -> String? {
        guard searchScope == .entireScan, !searchText.isEmpty else {
            return node.secondaryStatusText
        }

        let parentPath = appModel.fileTreeIndex.parent(of: node.id)?.url.path
        return parentPath ?? node.url.deletingLastPathComponent().path
    }

    private func rebuildDisplayedNodes() {
        let sortedNodes = searchCandidates.sorted(using: sortOrder)
        let filteredNodes: [FileNode]

        if searchText.isEmpty {
            filteredNodes = searchScope == .currentContents ? sortedNodes : nodes.sorted(using: sortOrder)
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
