import SwiftUI

struct FileBrowserActions {
    let selectNode: (String?) -> Void
    let selectNodeAfterViewUpdate: (String?) -> Void
    let selectNodes: (Set<String>, String?) -> Void
    let selectNodesAfterViewUpdate: (Set<String>, String?) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let zoomIntoSelection: () -> Void
    let selectedFileActions: SelectedFileActions
    let bulkFileActions: BulkFileActions
    let setCleanupListDragActive: (Bool) -> Void
}

struct FileBrowserTableView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let actions: FileBrowserActions

    @StateObject private var model: FileBrowserModel
    @FocusState private var isSearchFieldFocused: Bool

    init(
        scanState: ScanCoordinator,
        navigation: WorkspaceNavigationModel,
        focusedWorkspaceTarget: FocusState<WorkspaceFocusTarget?>.Binding,
        actions: FileBrowserActions,
        model: @autoclosure @escaping () -> FileBrowserModel = FileBrowserModel()
    ) {
        self.scanState = scanState
        self.navigation = navigation
        self._focusedWorkspaceTarget = focusedWorkspaceTarget
        self.actions = actions
        _model = StateObject(wrappedValue: model())
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: {
                let displayedIDs = Set(model.displayedNodes.map(\.id))
                return navigation.selectedNodeIDs.intersection(displayedIDs)
            },
            set: { newValue in
                let displayedIDs = Set(model.displayedNodes.map(\.id))
                let selectedIDs = newValue.intersection(displayedIDs)
                let primaryID = primarySelectionID(in: selectedIDs)

                if navigation.selectedNodeIDs != selectedIDs || navigation.selectedNodeID != primaryID {
                    actions.selectNodesAfterViewUpdate(selectedIDs, primaryID)
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

    private var contentRevision: Int {
        navigation.tableContentRevision
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
        .onExitCommand(perform: exitCommandHandler)
        .onAppear {
            updateModelContent()
        }
        .onDisappear {
            model.cleanup()
        }
        .onChange(of: contentID) { _, _ in
            updateModelContent()
        }
        .onChange(of: contentRevision) { _, _ in
            updateModelContent()
        }
        .onChange(of: scanState.snapshot?.id) { _, _ in
            updateModelContent()
        }
        .onChange(of: focusedWorkspaceTarget) { _, target in
            if target != nil {
                isSearchFieldFocused = false
            }
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
        Table(of: FileNodeRecord.self, selection: tableSelection, sortOrder: sortOrderBinding) {
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
                Text(
                    model.displayValues(
                        for: node,
                        hidesPackageContents: packageContentsAreHidden(for: node)
                    ).descendantCount
                )
            }
            .width(min: 70, ideal: 80)

            TableColumn("Modified", sortUsing: FileNodeTableComparator(field: .lastModified)) { node in
                Text(model.displayValues(for: node).modifiedDate)
            }
            .width(min: 150, ideal: 180)
        } rows: {
            ForEach(model.displayedNodes) { node in
                TableRow(node)
                    .draggable(cleanupListDragPayload(for: node))
            }
        }
        .accessibilityLabel("Contents table")
        .accessibilityHint("Select a row to inspect it. Double-click a folder to zoom in, or a summarized folder to expand it. Press Space for Quick Look.")
        .contextMenu(forSelectionType: FileNodeRecord.ID.self) { selectedIDs in
            fileContextMenu(for: selectedIDs)
        } primaryAction: { selectedIDs in
            performPrimaryAction(for: selectedIDs)
        }
        .focused($focusedWorkspaceTarget, equals: .contents)
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
        if packageContentsAreHidden(for: node) {
            var subtitleParts = ["Package contents hidden"]
            if let secondaryStatusText = node.secondaryStatusText {
                subtitleParts.append(secondaryStatusText)
            }
            guard model.isShowingEntireScanResults else {
                return subtitleParts.joined(separator: " - ")
            }

            subtitleParts.append(parentPath(for: node))
            return subtitleParts.joined(separator: " - ")
        }

        guard model.isShowingEntireScanResults else {
            return node.secondaryStatusText
        }

        return parentPath(for: node)
    }

    private func parentPath(for node: FileNodeRecord) -> String {
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

    private func packageContentsAreHidden(for node: FileNodeRecord) -> Bool {
        model.packageContentsAreHidden(for: node)
    }

    private func expandSummarizedNode(_ node: FileNodeRecord) {
        guard !isExpanding(node) else { return }
        actions.expandSummarizedNode(node)
    }

    @ViewBuilder
    private func fileContextMenu(for selectedIDs: Set<FileNodeRecord.ID>) -> some View {
        if let selection = selectionContext(for: selectedIDs) {
            if selection.nodes.count > 1 {
                bulkFileContextMenu(for: selection)
            } else {
                singleFileContextMenu(for: selection)
            }
        }
    }

    @ViewBuilder
    private func singleFileContextMenu(for selection: FileBrowserSelectionContext) -> some View {
        if let node = selection.primaryNode,
           let id = selection.primaryID {
            fileActionButton(.quickLook, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.revealInFinder, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.open, availability: selection.actionAvailability, selectedID: selection.id)

            if node.isAutoSummarized {
                let expansionIsActive = isExpanding(node)
                Button(
                    expansionIsActive ? "Expanding…" : "Expand Fully",
                    systemImage: "arrowshape.turn.up.right.circle.fill"
                ) {
                    actions.selectNode(id)
                    expandSummarizedNode(node)
                }
                .disabled(expansionIsActive)
            } else {
                Button("Zoom In", systemImage: "magnifyingglass") {
                    actions.selectNode(id)
                    actions.zoomIntoSelection()
                }
                .disabled(!canRequestZoom(for: node))
            }

            Divider()

            fileActionButton(.moveToTrash, availability: selection.actionAvailability, selectedID: selection.id)

            fileActionButton(.copyPath, availability: selection.actionAvailability, selectedID: selection.id)
        }
    }

    @ViewBuilder
    private func bulkFileContextMenu(for selection: FileBrowserSelectionContext) -> some View {
        Button("Reveal in Finder", systemImage: FileNodeAction.revealInFinder.systemImageName) {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.revealInFinder(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canRevealInFinder)

        Button("Copy Paths", systemImage: FileNodeAction.copyPath.systemImageName) {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.copyPaths(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canCopyPath)

        Divider()

        Button("Move \(selection.nodes.count) Items to Trash", systemImage: FileNodeAction.moveToTrash.systemImageName, role: .destructive) {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.moveToTrash(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canMoveToTrash)
    }

    private func performPrimaryAction(for selectedIDs: Set<FileNodeRecord.ID>) {
        guard let selection = selectionContext(for: selectedIDs) else { return }
        guard selection.nodes.count == 1,
              let node = selection.primaryNode,
              let id = selection.primaryID else { return }

        actions.selectNode(id)

        if node.isAutoSummarized && !isExpanding(node) {
            expandSummarizedNode(node)
        } else if canRequestZoom(for: node) {
            actions.zoomIntoSelection()
        } else if selection.actionAvailability.canOpen {
            actions.selectedFileActions.perform(.open)
        }
    }

    private func selectionContext(for selectedIDs: Set<FileNodeRecord.ID>) -> FileBrowserSelectionContext? {
        let nodes = selectedNodes(for: selectedIDs)
        guard !nodes.isEmpty else {
            return nil
        }

        let ids = Set(nodes.map(\.id))
        let primaryID = primarySelectionID(in: ids)
        let primaryNode = primaryID.flatMap { model.displayedNode(id: $0) } ?? nodes.first

        return FileBrowserSelectionContext(
            ids: ids,
            nodes: nodes,
            primaryID: primaryNode?.id,
            primaryNode: primaryNode,
            actionAvailability: FileNodeActionAvailability(
                nodes: nodes,
                activeTarget: scanState.selectedTarget,
                trashSafetyPolicy: scanState.trashSafetyPolicy,
                snapshotSource: scanState.snapshotSource
            )
        )
    }

    private func selectedNodes(for selectedIDs: Set<FileNodeRecord.ID>) -> [FileNodeRecord] {
        model.displayedNodes.filter { selectedIDs.contains($0.id) }
    }

    private func cleanupListDragPayload(for node: FileNodeRecord) -> CleanupListDragPayload {
        actions.setCleanupListDragActive(true)

        guard tableSelection.wrappedValue.contains(node.id) else {
            return CleanupListDragPayload(
                snapshotID: scanState.snapshot?.id,
                nodeIDs: [node.id]
            )
        }

        return CleanupListDragPayload(
            snapshotID: scanState.snapshot?.id,
            nodeIDs: selectedNodes(for: tableSelection.wrappedValue).map(\.id)
        )
    }

    private func primarySelectionID(in selectedIDs: Set<FileNodeRecord.ID>) -> FileNodeRecord.ID? {
        if let currentID = navigation.selectedNodeID,
           selectedIDs.contains(currentID) {
            return currentID
        }

        return model.displayedNodes.first(where: { selectedIDs.contains($0.id) })?.id
    }

    private var exitCommandHandler: (() -> Void)? {
        guard isSearchFieldFocused || !model.activeSearchText.isEmpty else { return nil }
        return handleExitCommand
    }

    private func handleExitCommand() {
        if !model.activeSearchText.isEmpty {
            model.setActiveSearchText("")
        } else {
            isSearchFieldFocused = false
        }
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
    let ids: Set<FileNodeRecord.ID>
    let nodes: [FileNodeRecord]
    let primaryID: FileNodeRecord.ID?
    let primaryNode: FileNodeRecord?
    let actionAvailability: FileNodeActionAvailability

    var id: FileNodeRecord.ID {
        primaryID ?? ids.sorted().first ?? ""
    }
}
