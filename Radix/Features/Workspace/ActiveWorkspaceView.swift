import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let visualizationMode: ScanVisualizationMode
    let maxRenderedDepth: Int
    let showFreeSpaceInDiskMaps: Bool
    let workspaceHiddenNodeIDs: Set<FileNodeRecord.ID>
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(
                navigation: navigation,
                snapshot: snapshot,
                focusNode: focusNode,
                fullDiskAccessStatus: fullDiskAccessStatus,
                actions: actions
            )

            Divider()

            resizableWorkspacePanes
        }
        .onExitCommand {
            actions.selectNodeImmediately(nil)
        }
    }

    private var resizableWorkspacePanes: some View {
        WorkspaceSplitView(topMinHeight: 260, bottomMinHeight: 200) {
            visualizationPane
        } bottom: {
            contentsPane
                .focusSection()
        }
    }

    private var visualizationPane: some View {
        chartContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
    }

    @ViewBuilder
    private var chartContent: some View {
        let visualizationPresentation = DiscardPileVisualizationPresentation(
            snapshot: snapshot,
            focusNode: focusNode,
            showFreeSpace: showFreeSpaceInDiskMaps,
            availableCapacity: freeSpaceAvailableCapacity(snapshot, focusNode),
            maxRenderedDepth: maxRenderedDepth,
            discardPileRootNodeIDs: discardPileRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs
        )
        let visualizationInput = visualizationPresentation.visualizationInput

        Group {
            switch visualizationMode {
            case .sunburst:
                SunburstChartView(
                    rootNode: visualizationInput.rootNode,
                    parentNode: visualizationParentNode(for: visualizationInput),
                    treeStore: visualizationInput.treeStore,
                    snapshotID: snapshot.id,
                    activeTarget: scanState.selectedTarget,
                    trashSafetyPolicy: scanState.trashSafetyPolicy,
                    snapshotSource: scanState.snapshotSource,
                    focusedWorkspaceTarget: $focusedWorkspaceTarget,
                    selectedNodeID: navigation.selectedNodeID,
                    selectedAncestorIDs: navigation.selectedAncestorIDs,
                    depthLimit: maxRenderedDepth,
                    layoutID: visualizationPresentation.layoutID,
                    discardPileRootNodeIDs: visualizationPresentation.discardPileRootNodeIDs,
                    movingToTrashRootNodeIDs: visualizationPresentation.movingToTrashRootNodeIDs,
                    onSelect: actions.selectNode,
                    onQuickLook: actions.quickLook,
                    onZoom: actions.selectAndFocusNode,
                    onSegmentClick: actions.recordSunburstSegmentClick,
                    onNavigateToParent: actions.navigateToParent,
                    onDiscardPileDragActiveChange: actions.setDiscardPileDragActive
                )
            case .treemap:
                TreemapChartView(
                    rootNode: visualizationInput.rootNode,
                    treeStore: visualizationInput.treeStore,
                    snapshotID: snapshot.id,
                    activeTarget: scanState.selectedTarget,
                    trashSafetyPolicy: scanState.trashSafetyPolicy,
                    snapshotSource: scanState.snapshotSource,
                    focusedWorkspaceTarget: $focusedWorkspaceTarget,
                    selectedNodeID: navigation.selectedNodeID,
                    depthLimit: maxRenderedDepth,
                    layoutID: visualizationPresentation.layoutID,
                    discardPileRootNodeIDs: visualizationPresentation.discardPileRootNodeIDs,
                    movingToTrashRootNodeIDs: visualizationPresentation.movingToTrashRootNodeIDs,
                    onSelect: actions.selectNode,
                    onQuickLook: actions.quickLook,
                    onZoom: actions.selectAndFocusNode,
                    onDiscardPileDragActiveChange: actions.setDiscardPileDragActive
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentsPane: some View {
        FileBrowserTableView(
            scanState: scanState,
            navigation: navigation,
            focusedWorkspaceTarget: $focusedWorkspaceTarget,
            hiddenNodeIDs: workspaceHiddenNodeIDs,
            actions: fileBrowserActions,
            model: actions.makeFileBrowserModel()
        )
    }

    private func visualizationParentNode(for input: DiskMapVisualizationInput) -> FileNodeRecord? {
        guard input.rootNode.id == focusNode.id else { return nil }
        return input.treeStore.parent(of: input.rootNode.id)
    }

    private var fileBrowserActions: FileBrowserActions {
        FileBrowserActions(
            quickLook: actions.quickLook,
            selectNode: actions.selectNodeImmediately,
            selectNodes: actions.selectNodesImmediately,
            selectNodesAfterViewUpdate: actions.selectNodes,
            expandSummarizedNode: actions.expandSummarizedNode,
            zoomIntoSelection: actions.zoomIntoSelection,
            rescanFolder: actions.rescanFolder,
            selectedFileActions: actions.selectedFileActions,
            bulkFileActions: actions.bulkFileActions,
            setDiscardPileDragActiveAfterThreshold: actions.setDiscardPileDragActiveAfterThreshold
        )
    }
}
