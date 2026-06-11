import SwiftUI

struct SelectionInspectorView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    var body: some View {
        let largestChildren = largestSelectedChildren

        Group {
            if let node = navigation.selectedNode {
                Form {
                    InspectorSummarySection(node: node)

                    InspectorStorageSection(
                        node: node,
                        parentName: navigation.selectedNodeParent?.name,
                        percentOfParent: selectedNodePercentOfParentText ?? "—",
                        percentOfScan: selectedNodePercentOfScanText ?? "—"
                    )

                    InspectorActionsSection(
                        availability: selectedActionAvailability,
                        canExpandSummarizedSelection: canExpandSummarizedSelection,
                        canZoomIntoSelection: navigation.canZoomIntoSelection,
                        quickLookAction: { appModel.previewSelectedWithQuickLook() },
                        revealAction: { appModel.revealSelectedInFinder() },
                        expandAction: { expandSummarizedSelection() },
                        zoomAction: { appModel.zoomIntoSelection() },
                        openAction: { appModel.openSelected() },
                        copyPathAction: { appModel.copySelectedPath() },
                        trashAction: { appModel.requestMoveSelectedToTrash() }
                    )

                    if !largestChildren.isEmpty {
                        InspectorLargestChildrenSection(children: largestChildren) { child in
                            appModel.selectAfterViewUpdate(nodeID: child.id)
                        }
                    }

                    if !scanWarningsPreview.isEmpty {
                        InspectorWarningsSection(
                            warnings: scanWarningsPreview,
                            shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                        ) {
                            appModel.prepareAndOpenFullDiskAccessSettings()
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                NoSelectionInspectorState(
                    scanWarningsPreview: scanWarningsPreview,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                ) {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scanWarningsPreview: [ScanWarning] {
        Array((scanState.snapshot?.scanWarnings ?? []).prefix(5))
    }

    private var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(for: scanState.snapshot)
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
            activeTarget: scanState.selectedTarget
        )
    }

    private var canExpandSummarizedSelection: Bool {
        navigation.selectedNode?.isAutoSummarized == true
    }

    private func expandSummarizedSelection() {
        guard let node = navigation.selectedNode else { return }
        appModel.expandSummarizedNode(node) {}
    }
}
