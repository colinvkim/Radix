import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?

    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchText = ""
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
            } else if displayedNodes.isEmpty {
                ContentUnavailableView(
                    "No Matching Items",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different filter or clear the current search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        TextField("Filter current contents", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .focused($isSearchFieldFocused)
                            .frame(maxWidth: 260)

                        Spacer(minLength: 8)

                        Text("\(displayedNodes.count) shown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                    .controlSize(.small)

                    Table(displayedNodes, selection: tableSelection, sortOrder: sortOrderBinding) {
                        TableColumn("Name", value: \.name) { node in
                            NameCell(node: node)
                        }
                        .width(min: 260, ideal: 360)

                        TableColumn("Size", value: \.allocatedSize) { node in
                            Text(RadixFormatters.size(node.allocatedSize))
                                .monospacedDigit()
                        }
                        .width(min: 110, ideal: 130)

                        TableColumn("Kind", value: \.itemKind) { node in
                            Text(node.itemKind)
                        }
                        .width(min: 110, ideal: 130)

                        TableColumn("Modified") { node in
                            Text(RadixFormatters.date(node.lastModified))
                        }
                        .width(min: 150, ideal: 180)
                    }
                    .controlSize(.small)
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
        .focusedSceneValue(\.fileListFilterAction) {
            isSearchFieldFocused = true
        }
        .onAppear(perform: rebuildDisplayedNodes)
        .onChange(of: nodes) { _, _ in
            rebuildDisplayedNodes()
        }
        .onChange(of: searchText) { _, _ in
            rebuildDisplayedNodes()
        }
    }

    private func rebuildDisplayedNodes() {
        let sortedNodes = nodes.sorted(using: sortOrder)
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

private struct NameCell: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory || node.isSynthetic ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                    .font(.body)

                if let statusText = node.secondaryStatusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(node.isSynthetic ? Color.secondary : Color.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
