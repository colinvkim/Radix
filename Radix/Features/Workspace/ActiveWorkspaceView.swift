import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let maxRenderedDepth: Int
    let showFreeSpaceInSunburst: Bool
    let discardPileHiddenNodeIDs: Set<FileNodeRecord.ID>
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    // Dismissal is scoped to a single target scan: transformed snapshots keep it hidden.
    @State private var dismissedWarningsScanScope: WarningDismissalScope?
    @StateObject private var visualizationFilter = SunburstVisualizationFilterModel()

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
        let baseVisualizationInput = sunburstVisualizationInput
        let visualizationInput = visualizationFilter.input(
            baseInput: baseVisualizationInput,
            snapshotID: snapshot.id,
            focusNodeID: focusNode.id,
            hiddenNodeIDs: discardPileHiddenNodeIDs
        )
        let filterUpdateToken = VisualizationFilterUpdateToken(
            baseInput: baseVisualizationInput,
            snapshotID: snapshot.id,
            focusNodeID: focusNode.id,
            hiddenNodeIDs: discardPileHiddenNodeIDs
        )

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
            onDiscardPileDragActiveChange: actions.setDiscardPileDragActive
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedWorkspaceTarget, equals: .chart)
        .onChange(of: filterUpdateToken, initial: true) { _, _ in
            visualizationFilter.update(
                baseInput: baseVisualizationInput,
                snapshotID: snapshot.id,
                focusNodeID: focusNode.id,
                hiddenNodeIDs: discardPileHiddenNodeIDs
            )
        }
    }

    private var contentsPane: some View {
        VStack(spacing: 0) {
            FileBrowserTableView(
                scanState: scanState,
                navigation: navigation,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                hiddenNodeIDs: discardPileHiddenNodeIDs,
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

    private func visualizationParentNode(for input: SunburstVisualizationInput) -> FileNodeRecord? {
        guard input.rootNode.id == focusNode.id else { return nil }
        return input.treeStore.parent(of: input.rootNode.id)
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
            setDiscardPileDragActiveAfterThreshold: actions.setDiscardPileDragActiveAfterThreshold
        )
    }
}

private struct WarningDismissalScope: Equatable {
    let targetID: String
    let startedAt: Date
}

private struct VisualizationFilterUpdateToken: Equatable {
    let snapshotID: UUID
    let focusNodeID: FileNodeRecord.ID
    let rootNodeID: FileNodeRecord.ID
    let baseLayoutIDComponent: String
    let hiddenNodeIDs: [FileNodeRecord.ID]

    init(
        baseInput: SunburstVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) {
        self.snapshotID = snapshotID
        self.focusNodeID = focusNodeID
        rootNodeID = baseInput.rootNode.id
        baseLayoutIDComponent = baseInput.layoutIDComponent
        self.hiddenNodeIDs = hiddenNodeIDs.sorted()
    }
}
