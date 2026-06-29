import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let maxRenderedDepth: Int
    let showFreeSpaceInSunburst: Bool
    let cleanupListHiddenNodeIDs: Set<FileNodeRecord.ID>
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    // Dismissal is scoped to a single target scan: transformed snapshots keep it hidden.
    @State private var dismissedWarningsScanScope: WarningDismissalScope?

    private var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(
            for: snapshot,
            fullDiskAccessStatus: fullDiskAccessStatus
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(
                navigation: navigation,
                snapshot: snapshot,
                focusNode: focusNode,
                actions: actions
            )

            Divider()

            resizableWorkspacePanes
        }
    }

    private var resizableWorkspacePanes: some View {
        WorkspaceSplitView(topMinHeight: 260, bottomMinHeight: 200) {
            visualizationPane
        } bottom: {
            contentsPane
        }
    }

    private var visualizationPane: some View {
        VStack(spacing: 0) {
            chartContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartContent: some View {
        let visualizationInput = cleanupFilteredVisualizationInput(from: sunburstVisualizationInput)

        return SunburstChartView(
            rootNode: visualizationInput.rootNode,
            parentNode: visualizationParentNode(for: visualizationInput),
            treeStore: visualizationInput.treeStore,
            snapshotID: snapshot.id,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource,
            selectedNodeID: navigation.selectedNodeID,
            selectedAncestorIDs: navigation.selectedAncestorIDs,
            depthLimit: maxRenderedDepth,
            layoutID: [
                snapshot.id.uuidString,
                focusNode.id,
                visualizationInput.rootNode.id,
                String(maxRenderedDepth),
                visualizationInput.layoutIDComponent
            ].joined(separator: "|"),
            onSelect: actions.selectNode,
            onZoom: actions.selectAndFocusNode,
            onSegmentClick: actions.recordSunburstSegmentClick,
            onNavigateToParent: actions.navigateToParent,
            onCleanupListDragActiveChange: actions.setCleanupListDragActive
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedWorkspaceTarget, equals: .chart)
    }

    private var contentsPane: some View {
        VStack(spacing: 0) {
            FileBrowserTableView(
                scanState: scanState,
                navigation: navigation,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                hiddenNodeIDs: cleanupListHiddenNodeIDs,
                actions: fileBrowserActions
            )

            if showsWarningFooter {
                Divider()
                WarningFooter(
                    warnings: snapshot.scanWarnings,
                    fullDiskAccessStatus: fullDiskAccessStatus,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess,
                    actions: actions,
                    onDismiss: { dismissedWarningsScanScope = warningDismissalScope }
                )
            }
        }
    }

    private var showsWarningFooter: Bool {
        !snapshot.scanWarnings.isEmpty && dismissedWarningsScanScope != warningDismissalScope
    }

    private var warningDismissalScope: WarningDismissalScope {
        WarningDismissalScope(targetID: snapshot.target.id, startedAt: snapshot.startedAt)
    }

    private var sunburstVisualizationInput: SunburstVisualizationInput {
        SunburstFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: focusNode,
            showFreeSpace: showFreeSpaceInSunburst,
            availableCapacity: freeSpaceAvailableCapacity(snapshot, focusNode)
        )
    }

    private func cleanupFilteredVisualizationInput(
        from input: SunburstVisualizationInput
    ) -> SunburstVisualizationInput {
        guard !cleanupListHiddenNodeIDs.isEmpty else { return input }

        let filteredStore = input.treeStore.removingSubtrees(
            rootedAt: Array(cleanupListHiddenNodeIDs)
        )
        return SunburstVisualizationInput(
            rootNode: filteredStore.node(id: input.rootNode.id) ?? filteredStore.root,
            treeStore: filteredStore,
            layoutIDComponent: [
                input.layoutIDComponent,
                cleanupHiddenLayoutComponent
            ].joined(separator: "|")
        )
    }

    private func visualizationParentNode(for input: SunburstVisualizationInput) -> FileNodeRecord? {
        guard input.rootNode.id == focusNode.id else { return nil }
        return input.treeStore.parent(of: input.rootNode.id)
    }

    private var cleanupHiddenLayoutComponent: String {
        let sortedIDs = cleanupListHiddenNodeIDs.sorted()
        guard !sortedIDs.isEmpty else { return "cleanup-list:0" }
        return sortedIDs.reduce("cleanup-list:\(sortedIDs.count)") { component, id in
            component + ":\(id.count):\(id)"
        }
    }

    private var fileBrowserActions: FileBrowserActions {
        FileBrowserActions(
            selectNode: actions.selectNodeImmediately,
            selectNodeAfterViewUpdate: actions.selectNode,
            selectNodes: actions.selectNodesImmediately,
            selectNodesAfterViewUpdate: actions.selectNodes,
            expandSummarizedNode: actions.expandSummarizedNode,
            zoomIntoSelection: actions.zoomIntoSelection,
            selectedFileActions: actions.selectedFileActions,
            bulkFileActions: actions.bulkFileActions,
            setCleanupListDragActiveAfterThreshold: actions.setCleanupListDragActiveAfterThreshold
        )
    }
}

private struct WarningDismissalScope: Equatable {
    let targetID: String
    let startedAt: Date
}
