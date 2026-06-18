import SwiftUI

struct SelectionInspectorActions {
    let selectNodeAfterViewUpdate: (String?) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let zoomIntoSelection: () -> Void
    let selectedFileActions: SelectedFileActions
    let openFullDiskAccessSettings: () -> Void
}

struct SelectionInspectorView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    let fullDiskAccessStatus: FullDiskAccessStatus
    let actions: SelectionInspectorActions

    var body: some View {
        let largestChildren = largestSelectedChildren

        Group {
            if let node = navigation.selectedNode {
                Form {
                    InspectorSummarySection(node: node)

                    InspectorDetailsSections(
                        node: node,
                        parentName: navigation.selectedNodeParent?.name,
                        percentOfParent: selectedNodePercentOfParentText ?? "—",
                        percentOfScan: selectedNodePercentOfScanText ?? "—"
                    )

                    InspectorActionsSection(
                        availability: selectedActionAvailability,
                        canExpandSummarizedSelection: canExpandSummarizedSelection,
                        canZoomIntoSelection: navigation.canZoomIntoSelection,
                        fileActions: actions.selectedFileActions,
                        expandAction: { expandSummarizedSelection() },
                        zoomAction: actions.zoomIntoSelection
                    )

                    if !largestChildren.isEmpty {
                        InspectorLargestChildrenSection(children: largestChildren) { child in
                            actions.selectNodeAfterViewUpdate(child.id)
                        }
                    }

                    if !scanWarningsPreview.isEmpty {
                        InspectorWarningsSection(
                            warnings: scanWarningsPreview,
                            shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                        ) {
                            actions.openFullDiskAccessSettings()
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                InspectorNoSelectionView(
                    scanWarningsPreview: scanWarningsPreview,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                ) {
                    actions.openFullDiskAccessSettings()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scanWarningsPreview: [ScanWarning] {
        Array((scanState.snapshot?.scanWarnings ?? []).prefix(5))
    }

    private var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(
            for: scanState.snapshot,
            fullDiskAccessStatus: fullDiskAccessStatus
        )
    }

    private var largestSelectedChildren: [FileNodeRecord] {
        guard let fileTreeStore = scanState.fileTreeStore,
              let selectedNode = navigation.selectedNode,
              selectedNode.isDirectory else { return [] }
        return fileTreeStore.childrenPrefix(of: selectedNode.id, maxCount: 8)
    }

    private var selectedNodePercentOfParentText: String? {
        guard let selectedNode = navigation.selectedNode,
              let parent = navigation.selectedNodeParent else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    private var selectedNodePercentOfScanText: String? {
        guard let selectedNode = navigation.selectedNode,
              let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }

    private var selectedActionAvailability: FileNodeActionAvailability {
        FileNodeActionAvailability(
            node: navigation.selectedNode,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy
        )
    }

    private var canExpandSummarizedSelection: Bool {
        navigation.selectedNode?.isAutoSummarized == true
    }

    private func expandSummarizedSelection() {
        guard let node = navigation.selectedNode else { return }
        actions.expandSummarizedNode(node)
    }
}
