import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserActions {
    let quickLook: () -> Bool
    let selectNode: (String?) -> Void
    let selectNodes: (Set<String>, String?) -> Void
    let selectNodesAfterViewUpdate: (Set<String>, String?) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let zoomIntoSelection: () -> Void
    let rescanFolder: (FileNodeRecord.ID) -> Void
    let selectedFileActions: SelectedFileActions
    let bulkFileActions: BulkFileActions
    let setDiscardPileDragActive: (Bool) -> Void
}

private struct FileBrowserContentRefreshID: Hashable {
    let tableContentID: String
    let tableContentRevision: Int
    let snapshotID: UUID?
    let treeContentID: UUID?
    let hiddenNodeIDs: Set<FileNodeRecord.ID>
}

struct FileBrowserTableView: View {
    @Environment(\.isReadOnlyMode) private var isReadOnlyMode
    @EnvironmentObject private var tour: WorkspaceTourController
    @EnvironmentObject private var tourPresentation: WorkspaceTourPresentation
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let hiddenNodeIDs: Set<FileNodeRecord.ID>
    let fileDragController: FileDragController
    let actions: FileBrowserActions

    @StateObject private var model: FileBrowserModel
    @FocusState private var isSearchFieldFocused: Bool
    @State private var presentedSharedStorageNodeID: FileNodeRecord.ID?

    init(
        scanState: ScanCoordinator,
        navigation: WorkspaceNavigationModel,
        focusedWorkspaceTarget: FocusState<WorkspaceFocusTarget?>.Binding,
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileDragController: FileDragController,
        actions: FileBrowserActions,
        model: @autoclosure @escaping () -> FileBrowserModel = FileBrowserModel()
    ) {
        self.scanState = scanState
        self.navigation = navigation
        self._focusedWorkspaceTarget = focusedWorkspaceTarget
        self.hiddenNodeIDs = hiddenNodeIDs
        self.fileDragController = fileDragController
        self.actions = actions
        _model = StateObject(wrappedValue: model())
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: {
                navigation.selectedNodeIDs.filter { model.displayedNode(id: $0) != nil }
            },
            set: { newValue in
                let currentVisibleSelection = navigation.selectedNodeIDs.filter {
                    model.displayedNode(id: $0) != nil
                }
                let selectedIDs = newValue.filter { model.displayedNode(id: $0) != nil }
                let primaryID = primarySelectionID(in: selectedIDs)
                let currentVisiblePrimary = navigation.selectedNodeID.flatMap {
                    currentVisibleSelection.contains($0) ? $0 : nil
                }

                if currentVisibleSelection != selectedIDs || currentVisiblePrimary != primaryID {
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

    private var activeQuery: Binding<FileBrowserQuery> {
        Binding(
            get: { model.activeQuery },
            set: { model.setActiveQuery($0) }
        )
    }

    private var showsTableChrome: Bool {
        navigation.isLoadingTableNodes || !nodes.isEmpty || model.isShowingEntireScanResults
    }

    private var isSearchBarLoading: Bool {
        navigation.isLoadingTableNodes || model.isRefreshingCurrentContents || model.isSearchingEntireScan
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

    private var contentRefreshID: FileBrowserContentRefreshID {
        FileBrowserContentRefreshID(
            tableContentID: contentID,
            tableContentRevision: contentRevision,
            snapshotID: scanState.snapshot?.id,
            treeContentID: scanState.fileTreeStore?.contentID,
            hiddenNodeIDs: hiddenNodeIDs
        )
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
                        query: activeQuery,
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
        .focusedSceneValue(
            \.isFileListSearchActive,
            isSearchFieldFocused || model.activeQuery.isActive
        )
        .onExitCommand(perform: handleExitCommand)
        .task(id: contentRefreshID) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            updateModelContent()
        }
        .onDisappear {
            presentedSharedStorageNodeID = nil
            model.cleanup()
        }
    }

    private var noResultsDescription: String {
        if model.isShowingEntireScanResults {
            return String(localized: "No items anywhere in this scan match your search.", comment: "Empty state shown when an entire-scan search has no results.")
        }
        return String(localized: "Try a different search or adjust the filters.", comment: "Empty state guidance shown when searching the current contents has no results.")
    }

    @ViewBuilder
    private var tableContent: some View {
        if navigation.isLoadingTableNodes ||
            (model.isRefreshingCurrentContents && !model.isDisplayingCurrentResults) {
            loadingContent(String(localized: "Loading Contents…", comment: "Progress message while the current directory contents load."))
        } else if model.isShowingEntireScanResults &&
            model.isSearchingEntireScan &&
            !model.isDisplayingCurrentResults {
            loadingContent(String(localized: "Searching Entire Scan…", comment: "Progress message while the entire scan is searched."))
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
        let tourFolderID = tourFolder?.id
        let tour = self.tour
        let tourPresentation = self.tourPresentation

        return Table(of: FileNodeRecord.self, selection: tableSelection, sortOrder: sortOrderBinding) {
            TableColumn("Name", sortUsing: FileNodeTableComparator(field: .name)) { node in
                FileBrowserNameCell(
                    node: node,
                    subtitleOverride: subtitle(for: node),
                    isExpanding: isExpanding(node),
                    expandAction: { expandSummarizedNode(node) },
                    presentedSharedStorageNodeID: $presentedSharedStorageNodeID
                )
                .workspaceTourAnchor(.folder, enabled: node.id == tourFolderID)
                // Table drag previews host cells outside the workspace hierarchy.
                .environmentObject(tour)
                .environmentObject(tourPresentation)
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
                    // SwiftUI requires a registered type to enable row dragging.
                    // The native adapter supplies the validated pasteboard items.
                    .itemProvider {
                        NSItemProvider(
                            item: Data() as NSData,
                            typeIdentifier: DiscardPileDragPayload.contentType.identifier
                        )
                    }
            }
        }
        .background {
            FileBrowserDragAdapter(
                nodes: model.displayedNodes,
                controller: fileDragController,
                onDragActiveChange: actions.setDiscardPileDragActive
            )
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .accessibilityLabel("Contents table")
        .accessibilityHint("Select a row to inspect it. Double-click a folder to zoom in, or a summarized folder to expand it. Press Space for Quick Look.")
        .contextMenu(forSelectionType: FileNodeRecord.ID.self) { selectedIDs in
            fileContextMenu(for: selectedIDs)
        } primaryAction: { selectedIDs in
            performPrimaryAction(for: selectedIDs)
        }
        .tableKeyboardFocus($focusedWorkspaceTarget, equals: .contents)
        .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            return actions.quickLook() ? .handled : .ignored
        }
    }

    private var tourFolder: FileNodeRecord? {
        guard tour.isActive else { return nil }
        if let selected = navigation.selectedNode,
           model.displayedNode(id: selected.id) != nil, canZoomInto(node: selected) {
            return selected
        }
        return model.displayedNodes.first { canZoomInto(node: $0) }
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
            fileTreeStore: scanState.fileTreeStore,
            hiddenNodeIDs: hiddenNodeIDs
        )
    }

    private func subtitle(for node: FileNodeRecord) -> String? {
        if packageContentsAreHidden(for: node) {
            var subtitleParts = [String(localized: "Package Contents Hidden")]
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

        return fileTreeStore.parent(of: node.id)?.url.path
            ?? node.url.deletingLastPathComponent().path
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
                .labelStyle(.titleOnly)

            fileActionButton(
                .openInTerminal,
                availability: selection.actionAvailability,
                selectedID: selection.id,
                node: node
            )

            if node.isAutoSummarized {
                let expansionIsActive = isExpanding(node)
                Button(expansionIsActive ? "Expanding…" : "Expand Fully") {
                    actions.selectNode(id)
                    expandSummarizedNode(node)
                }
                .disabled(expansionIsActive)
            } else {
                Button("Zoom In") {
                    actions.selectNode(id)
                    actions.zoomIntoSelection()
                }
                .disabled(!canRequestZoom(for: node))
            }

            if node.isDirectory {
                Button("Rescan Folder") {
                    actions.rescanFolder(id)
                }
                .disabled(!scanState.canRescanFolder(id: id))
            }

            Divider()

            Button("Add to Discard Pile", systemImage: "checklist") {
                actions.selectNode(id)
                actions.bulkFileActions.addToDiscardPile([node])
            }
            .disabled(!selection.actionAvailability.canMoveToTrash)

            Button(
                FileNodeAction.moveToTrash.title,
                systemImage: FileNodeAction.moveToTrash.systemImageName,
                role: .destructive
            ) {
                actions.selectNode(id)
                actions.bulkFileActions.moveToTrash([node])
            }
            .disabled(!FileNodeAction.moveToTrash.isEnabled(in: selection.actionAvailability))

            fileActionButton(.copyPath, availability: selection.actionAvailability, selectedID: selection.id)
                .labelStyle(.titleOnly)
        }
    }

    @ViewBuilder
    private func bulkFileContextMenu(for selection: FileBrowserSelectionContext) -> some View {
        Button(FileNodeAction.quickLook.title, systemImage: FileNodeAction.quickLook.systemImageName) {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.selectedFileActions.quickLook()
        }
        .disabled(!selection.actionAvailability.canPreviewWithQuickLook)

        Button("Reveal in Finder", systemImage: FileNodeAction.revealInFinder.systemImageName) {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.revealInFinder(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canRevealInFinder)

        Button("Copy Paths") {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.copyPaths(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canCopyPath)

        Divider()

        Button("Add \(selection.nodes.count) Items to Discard Pile", systemImage: "checklist") {
            actions.selectNodes(selection.ids, selection.primaryID)
            actions.bulkFileActions.addToDiscardPile(selection.nodes)
        }
        .disabled(!selection.actionAvailability.canMoveToTrash)

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
                snapshotSource: scanState.snapshotSource,
                isReadOnlyMode: isReadOnlyMode
            )
        )
    }

    private func selectedNodes(for selectedIDs: Set<FileNodeRecord.ID>) -> [FileNodeRecord] {
        model.displayedNodes.filter { selectedIDs.contains($0.id) }
    }

    private func primarySelectionID(in selectedIDs: Set<FileNodeRecord.ID>) -> FileNodeRecord.ID? {
        if let currentID = navigation.selectedNodeID,
           selectedIDs.contains(currentID) {
            return currentID
        }

        return model.displayedNodes.first(where: { selectedIDs.contains($0.id) })?.id
    }

    private func handleExitCommand() {
        if model.activeQuery != FileBrowserQuery() {
            model.clearActiveQuery()
        } else if isSearchFieldFocused {
            focusedWorkspaceTarget = .contents
        } else {
            actions.selectNode(nil)
        }
    }

    @ViewBuilder
    private func fileActionButton(
        _ action: FileNodeAction,
        availability: FileNodeActionAvailability,
        selectedID: FileNodeRecord.ID,
        node: FileNodeRecord? = nil
    ) -> some View {
        Button(action.title(for: node), systemImage: action.systemImageName) {
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
