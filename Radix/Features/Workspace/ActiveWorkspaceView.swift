import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let maxRenderedDepth: Int
    let showFreeSpaceInSunburst: Bool
    let cleanupListSummary: CleanupListSummary
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
        let visualizationInput = sunburstVisualizationInput

        return SunburstChartView(
            rootNode: visualizationInput.rootNode,
            parentNode: navigation.currentFocusNodeParent,
            treeStore: visualizationInput.treeStore,
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
            onNavigateToParent: actions.navigateToParent
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
                cleanupListSummary: cleanupListSummary,
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
            cleanupListActions: actions.cleanupListActions
        )
    }
}

private struct WarningDismissalScope: Equatable {
    let targetID: String
    let startedAt: Date
}
