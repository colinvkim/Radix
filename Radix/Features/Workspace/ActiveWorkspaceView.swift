import SwiftUI

struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    let maxRenderedDepth: Int
    let fullDiskAccessStatus: FullDiskAccessStatus
    let actions: WorkspaceActions

    // Dismissal is scoped to a single scan: a new snapshot re-shows the footer.
    @State private var dismissedWarningsSnapshotID: ScanSnapshot.ID?

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
        SunburstChartView(
            rootNode: focusNode,
            treeStore: snapshot.treeStore,
            selectedNodeID: navigation.selectedNodeID,
            selectedAncestorIDs: navigation.selectedAncestorIDs,
            depthLimit: maxRenderedDepth,
            layoutID: "\(snapshot.id.uuidString)|\(focusNode.id)|\(maxRenderedDepth)",
            onSelect: actions.selectNode,
            onZoom: actions.selectAndFocusNode
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private var contentsPane: some View {
        VStack(spacing: 0) {
            FileBrowserTableView(
                scanState: scanState,
                navigation: navigation,
                actions: fileBrowserActions
            )

            if showsWarningFooter {
                Divider()
                WarningFooter(
                    warnings: snapshot.scanWarnings,
                    fullDiskAccessStatus: fullDiskAccessStatus,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess,
                    actions: actions,
                    onDismiss: { dismissedWarningsSnapshotID = snapshot.id }
                )
            }
        }
    }

    private var showsWarningFooter: Bool {
        !snapshot.scanWarnings.isEmpty && dismissedWarningsSnapshotID != snapshot.id
    }

    private var fileBrowserActions: FileBrowserActions {
        FileBrowserActions(
            selectNode: actions.selectNodeImmediately,
            selectNodeAfterViewUpdate: actions.selectNode,
            expandSummarizedNode: actions.expandSummarizedNode,
            zoomIntoSelection: actions.zoomIntoSelection,
            selectedFileActions: actions.selectedFileActions
        )
    }
}
