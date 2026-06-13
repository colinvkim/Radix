import SwiftUI

struct FileBrowserActions {
    let selectNode: (String?) -> Void
    let selectNodeAfterViewUpdate: (String?) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let zoomIntoSelection: () -> Void
    let selectedFileActions: SelectedFileActions
}

struct FileBrowserTableView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    let actions: FileBrowserActions

    @StateObject private var model: FileBrowserModel
    @FocusState private var isSearchFieldFocused: Bool

    init(
        scanState: ScanCoordinator,
        navigation: WorkspaceNavigationModel,
        actions: FileBrowserActions,
        model: @autoclosure @escaping () -> FileBrowserModel = FileBrowserModel()
    ) {
        self.scanState = scanState
        self.navigation = navigation
        self.actions = actions
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
                    actions.selectNodeAfterViewUpdate(newValue)
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

    private var isSearchBarLoading: Bool {
        model.isRefreshingCurrentContents || model.isSearchingEntireScan
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
                    FileBrowserSearchFilterBar(
                        scope: searchScopeBinding,
                        text: activeSearchText,
                        isLoading: isSearchBarLoading,
                        isFocused: $isSearchFieldFocused
                    )

                    Divider()

                    tableContent
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
        .onDisappear {
            model.cleanup()
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

    @ViewBuilder
    private var tableContent: some View {
        if model.isRefreshingCurrentContents && !model.isDisplayingCurrentResults {
            loadingContent("Loading Contents…")
        } else if model.isShowingEntireScanResults &&
            model.isSearchingEntireScan &&
            !model.isDisplayingCurrentResults {
            loadingContent("Searching Entire Scan…")
        } else if model.displayedNodes.isEmpty {
            ContentUnavailableView(
                "No Matching Items",
                systemImage: "magnifyingglass",
                description: Text(noResultsDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            contentsTable
        }
    }

    private var contentsTable: some View {
        Table(model.displayedNodes, selection: tableSelection, sortOrder: sortOrderBinding) {
            TableColumn("Name", sortUsing: FileNodeTableComparator(field: .name)) { node in
                FileBrowserNameCell(
                    node: node,
                    subtitleOverride: subtitle(for: node),
                    isExpanding: isExpanding(node),
                    expandAction: { expandSummarizedNode(node) }
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

            TableColumn("Files", sortUsing: FileNodeTableComparator(field: .descendantFileCount)) { node in
                Text(model.displayValues(for: node).descendantCount)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Modified", sortUsing: FileNodeTableComparator(field: .lastModified)) { node in
                Text(model.displayValues(for: node).modifiedDate)
            }
            .width(min: 150, ideal: 180)
        }
        .accessibilityLabel("Contents table")
        .accessibilityHint("Select a row to inspect it. Double-click a folder to zoom in, or a summarized folder to expand it. Press Space for Quick Look.")
        .contextMenu(forSelectionType: FileNodeRecord.ID.self) { selectedIDs in
            fileContextMenu(for: selectedIDs)
        } primaryAction: { selectedIDs in
            performPrimaryAction(for: selectedIDs)
        }
    }

    private func loadingContent(_ title: String) -> some View {
        VStack {
            Spacer()
            ProgressView(title)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func isExpanding(_ node: FileNodeRecord) -> Bool {
        scanState.expandingNodeID == node.id
    }

    private func shouldShowPackageContentsHint(for node: FileNodeRecord) -> Bool {
        node.isPackage &&
            node.isDirectory &&
            !node.isAutoSummarized &&
            (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0)
    }

    private func expandSummarizedNode(_ node: FileNodeRecord) {
        guard !isExpanding(node) else { return }
        actions.expandSummarizedNode(node)
    }

    @ViewBuilder
    private func fileContextMenu(for selectedIDs: Set<FileNodeRecord.ID>) -> some View {
        if let selection = selectionContext(for: selectedIDs) {
            fileActionButton(.quickLook, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.revealInFinder, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.open, availability: selection.actionAvailability, selectedID: selection.id)

            if selection.node.isAutoSummarized {
                let expansionIsActive = isExpanding(selection.node)
                Button(
                    expansionIsActive ? "Expanding…" : "Expand Fully",
                    systemImage: "arrowshape.turn.up.right.circle.fill"
                ) {
                    actions.selectNode(selection.id)
                    expandSummarizedNode(selection.node)
                }
                .disabled(expansionIsActive)
            } else {
                Button("Zoom In", systemImage: "magnifyingglass") {
                    actions.selectNode(selection.id)
                    actions.zoomIntoSelection()
                }
                .disabled(!canRequestZoom(for: selection.node))
            }

            Divider()

            fileActionButton(.moveToTrash, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.copyPath, availability: selection.actionAvailability, selectedID: selection.id)
        }
    }

    private func performPrimaryAction(for selectedIDs: Set<FileNodeRecord.ID>) {
        guard let selection = selectionContext(for: selectedIDs) else { return }

        actions.selectNode(selection.id)

        if selection.node.isAutoSummarized && !isExpanding(selection.node) {
            expandSummarizedNode(selection.node)
        } else if canRequestZoom(for: selection.node) {
            actions.zoomIntoSelection()
        } else if selection.actionAvailability.canOpen {
            actions.selectedFileActions.perform(.open)
        }
    }

    private func selectionContext(for selectedIDs: Set<FileNodeRecord.ID>) -> FileBrowserSelectionContext? {
        guard let selectedID = selectedIDs.first,
              let selectedNode = model.displayedNode(id: selectedID) else {
            return nil
        }

        return FileBrowserSelectionContext(
            id: selectedID,
            node: selectedNode,
            actionAvailability: selectedNode.actionAvailability(
                activeTarget: scanState.selectedTarget,
                trashSafetyPolicy: scanState.trashSafetyPolicy
            )
        )
    }

    @ViewBuilder
    private func fileActionButton(
        _ action: FileNodeAction,
        availability: FileNodeActionAvailability,
        selectedID: FileNodeRecord.ID
    ) -> some View {
        Button(action.title, systemImage: action.systemImageName) {
            actions.selectNode(selectedID)
            actions.selectedFileActions.perform(action)
        }
        .disabled(!action.isEnabled(in: availability))
    }
}

private struct FileBrowserSelectionContext {
    let id: FileNodeRecord.ID
    let node: FileNodeRecord
    let actionAvailability: FileNodeActionAvailability
}
