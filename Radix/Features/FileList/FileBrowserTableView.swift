import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    @StateObject private var model: FileBrowserModel
    @FocusState private var isSearchFieldFocused: Bool

    init(
        scanState: ScanCoordinator,
        navigation: WorkspaceNavigationModel,
        model: @autoclosure @escaping () -> FileBrowserModel = FileBrowserModel()
    ) {
        self.scanState = scanState
        self.navigation = navigation
        _model = StateObject(wrappedValue: model())
    }

    private var tableSelection: Binding<String?> {
        Binding(
            get: {
                guard let selectedNodeID = navigation.selectedNodeID,
                      model.displayedNode(id: selectedNodeID) != nil else { return nil }
                return selectedNodeID
            },
            set: { newValue in
                if navigation.selectedNodeID != newValue {
                    appModel.select(nodeID: newValue)
                }
            }
        )
    }

    private var sortOrderBinding: Binding<[FileNodeTableComparator]> {
        Binding(
            get: { model.sortOrder },
            set: { newValue in
                model.setSortOrder(newValue)
            }
        )
    }

    private var searchScopeBinding: Binding<FileBrowserFindTarget> {
        Binding(
            get: { model.searchScope },
            set: { model.setSearchScope($0) }
        )
    }

    private var activeSearchText: Binding<String> {
        Binding(
            get: { model.activeSearchText },
            set: { model.setActiveSearchText($0) }
        )
    }

    private var showsTableChrome: Bool {
        !nodes.isEmpty || model.isShowingEntireScanResults
    }

    private var nodes: [FileNodeRecord] {
        navigation.tableNodes
    }

    private var contentID: String {
        navigation.tableContentID
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
                        scope: searchScopeBinding,
                        text: activeSearchText,
                        isLoading: model.isRefreshingCurrentContents,
                        isFocused: $isSearchFieldFocused
                    )

                    Divider()

                    if model.isRefreshingCurrentContents && !model.isDisplayingCurrentResults {
                        VStack {
                            Spacer()
                            ProgressView("Loading Contents…")
                                .controlSize(.small)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.isShowingEntireScanResults &&
                        model.isSearchingEntireScan &&
                        !model.isDisplayingCurrentResults {
                        VStack {
                            Spacer()
                            ProgressView("Searching Entire Scan…")
                                .controlSize(.small)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.displayedNodes.isEmpty {
                        ContentUnavailableView(
                            "No Matching Items",
                            systemImage: "magnifyingglass",
                            description: Text(noResultsDescription)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(model.displayedNodes, selection: tableSelection, sortOrder: sortOrderBinding) {
                            TableColumn("Name", sortUsing: FileNodeTableComparator(field: .name)) { node in
                                NameCell(
                                    node: node,
                                    subtitleOverride: subtitle(for: node)
                                )
                            }
                            .width(min: 260, ideal: 360)

                            TableColumn("Allocated", sortUsing: FileNodeTableComparator(field: .allocatedSize)) { node in
                                Text(model.displayValues(for: node).allocatedSize)
                                    .monospacedDigit()
                            }
                            .width(min: 110, ideal: 130)

                            TableColumn("Kind", sortUsing: FileNodeTableComparator(field: .itemKind)) { node in
                                Text(node.itemKind)
                            }
                            .width(min: 110, ideal: 130)

                            TableColumn("Files") { node in
                                Text(model.displayValues(for: node).descendantCount)
                            }
                            .width(min: 70, ideal: 80)

                            TableColumn("Modified") { node in
                                Text(model.displayValues(for: node).modifiedDate)
                            }
                            .width(min: 150, ideal: 180)
                        }
                        .accessibilityLabel("Contents table")
                        .accessibilityHint("Select a row to inspect it. Double-click a folder to zoom in, or a summarized folder to expand it. Press Space for Quick Look.")
                        .contextMenu(forSelectionType: FileNodeRecord.ID.self) { selectedIDs in
                            if let selectedID = selectedIDs.first,
                               let selectedNode = model.displayedNode(id: selectedID) {
                                let actionAvailability = selectedNode.actionAvailability(activeTarget: scanState.selectedTarget)

                                Button("Quick Look", systemImage: RadixSystemImages.quickLook) {
                                    appModel.select(nodeID: selectedID)
                                    appModel.previewSelectedWithQuickLook()
                                }
                                .disabled(!actionAvailability.canPreviewWithQuickLook)

                                Button("Reveal in Finder", systemImage: RadixSystemImages.revealInFinder) {
                                    appModel.select(nodeID: selectedID)
                                    appModel.revealSelectedInFinder()
                                }
                                .disabled(!actionAvailability.canRevealInFinder)

                                Button("Open", systemImage: "arrow.up.forward.app") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.openSelected()
                                }
                                .disabled(!actionAvailability.canOpen)

                                if selectedNode.isAutoSummarized {
                                    Button("Expand Fully", systemImage: "arrowshape.turn.up.right.circle.fill") {
                                        appModel.select(nodeID: selectedID)
                                        expandSummarizedNode(selectedNode)
                                    }
                                } else {
                                    Button("Zoom In", systemImage: "magnifyingglass") {
                                        appModel.select(nodeID: selectedID)
                                        appModel.zoomIntoSelection()
                                    }
                                    .disabled(!canRequestZoom(for: selectedNode))
                                }

                                Divider()

                                Button("Move to Trash", systemImage: "trash") {
                                    appModel.select(nodeID: selectedID)
                                    appModel.requestMoveSelectedToTrash()
                                }
                                .disabled(!actionAvailability.canMoveToTrash)

                                Button("Copy Path", systemImage: RadixSystemImages.copyPath) {
                                    appModel.select(nodeID: selectedID)
                                    appModel.copySelectedPath()
                                }
                                .disabled(!actionAvailability.canCopyPath)
                            }
                        } primaryAction: { selectedIDs in
                            guard let selectedID = selectedIDs.first,
                                  let selectedNode = model.displayedNode(id: selectedID) else {
                                return
                            }

                            appModel.select(nodeID: selectedID)

                            if selectedNode.isAutoSummarized {
                                expandSummarizedNode(selectedNode)
                            } else if canRequestZoom(for: selectedNode) {
                                appModel.zoomIntoSelection()
                            } else if selectedNode.actionAvailability(activeTarget: scanState.selectedTarget).canOpen {
                                appModel.openSelected()
                            }
                        }
                    }
                }
            }
        }
        .focusedSceneValue(\.fileListFilterAction) { target in
            model.setSearchScope(target)
            isSearchFieldFocused = true
        }
        .onAppear {
            updateModelContent()
        }
        .onChange(of: contentID) { _, _ in
            updateModelContent()
        }
        .onChange(of: scanState.snapshot?.id) { _, _ in
            updateModelContent()
        }
    }

    private var noResultsDescription: String {
        if model.isShowingEntireScanResults {
            return "No items anywhere in this scan match your search."
        }
        return "Try a different filter or clear the current contents filter."
    }

    private func updateModelContent() {
        model.updateContent(
            nodes: nodes,
            contentID: contentID,
            snapshot: scanState.snapshot,
            fileTreeStore: scanState.fileTreeStore
        )
    }

    private func subtitle(for node: FileNodeRecord) -> String? {
        guard model.isShowingEntireScanResults else {
            return node.secondaryStatusText
        }

        guard let fileTreeStore = scanState.fileTreeStore else {
            return node.url.deletingLastPathComponent().path
        }

        return fileTreeStore.parentIDByID[node.id]
            .flatMap { fileTreeStore.nodesByID[$0]?.url.path } ?? node.url.deletingLastPathComponent().path
    }

    private func canZoomInto(node: FileNodeRecord) -> Bool {
        node.isDirectory && scanState.fileTreeStore?.containsChildren(id: node.id) == true
    }

    private func canRequestZoom(for node: FileNodeRecord) -> Bool {
        canZoomInto(node: node) || shouldShowPackageContentsHint(for: node)
    }

    private func shouldShowPackageContentsHint(for node: FileNodeRecord) -> Bool {
        node.isPackage &&
            node.isDirectory &&
            !node.isAutoSummarized &&
            (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0)
    }

    private func expandSummarizedNode(_ node: FileNodeRecord) {
        appModel.expandSummarizedNode(node) {}
    }

}

private struct SearchFilterBar: View {
    @Binding var scope: FileBrowserFindTarget
    @Binding var text: String
    let isLoading: Bool
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

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
                .accessibilityLabel(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct NameCell: View {
    let node: FileNodeRecord
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
    let node: FileNodeRecord
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
        .accessibilityLabel("Expand \(node.name)")
        .accessibilityHint("Scans all \(node.descendantFileCount) files in this summarized folder.")
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
