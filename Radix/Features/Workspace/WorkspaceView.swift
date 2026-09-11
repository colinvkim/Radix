import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiscardPileDragPayload: Codable, Hashable, Transferable {
    static let contentType = UTType(exportedAs: "dev.colinkim.radix.discard-pile-drag-payload")

    let snapshotID: UUID
    let nodeIDs: [FileNodeRecord.ID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

struct WorkspaceActions {
    let makeFileBrowserModel: () -> FileBrowserModel
    let chooseFolder: () -> Void
    let startScan: (ScanTarget) -> Void
    let stopScan: () -> Void
    let rescan: () -> Void
    let rescanFolder: (FileNodeRecord.ID) -> Void
    let canRescanCurrentFolder: () -> Bool
    let compareScans: () -> Void
    let canCompareScans: () -> Bool
    let handleDroppedURLs: ([URL]) -> Bool
    let selectNodeImmediately: (String?) -> Void
    let selectNode: (String?) -> Void
    let selectNodesImmediately: (Set<String>, String?) -> Void
    let selectNodes: (Set<String>, String?) -> Void
    let focusNode: (String?) -> Void
    let selectAndFocusNode: (String) -> Void
    let navigateBack: () -> Void
    let navigateForward: () -> Void
    let navigateToParent: () -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let zoomIntoSelection: () -> Void
    let recordSunburstSegmentClick: () -> Void
    let selectedFileActions: SelectedFileActions
    let bulkFileActions: BulkFileActions
    let openFullDiskAccessSettings: () -> Void
    let setDiscardPileDragActive: (Bool) -> Void
    let setDiscardPileDragActiveAfterThreshold: (Bool) -> Void
}

struct SelectedFileActions {
    let quickLook: () -> Void
    let revealInFinder: () -> Void
    let open: () -> Void
    let openInTerminal: () -> Void
    let copyPath: () -> Void
    let moveToTrash: () -> Void

    func perform(_ action: FileNodeAction) {
        switch action {
        case .quickLook:
            quickLook()
        case .revealInFinder:
            revealInFinder()
        case .open:
            open()
        case .openInTerminal:
            openInTerminal()
        case .copyPath:
            copyPath()
        case .moveToTrash:
            moveToTrash()
        }
    }
}

struct BulkFileActions {
    let revealInFinder: ([FileNodeRecord]) -> Void
    let copyPaths: ([FileNodeRecord]) -> Void
    let addToDiscardPile: ([FileNodeRecord]) -> Void
    let moveToTrash: ([FileNodeRecord]) -> Void
}

struct WorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @Binding var isInspectorPresented: Bool
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    @Binding var visualizationMode: ScanVisualizationMode

    let maxRenderedDepth: Int
    let showFreeSpaceInDiskMaps: Bool
    let workspaceHiddenNodeIDs: Set<FileNodeRecord.ID>
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    let startupDiskTarget: ScanTarget?
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    var body: some View {
        Group {
            if let snapshot = scanState.snapshot,
               let focusNode = navigation.currentFocusNode {
                ActiveWorkspaceView(
                    scanState: scanState,
                    navigation: navigation,
                    snapshot: snapshot,
                    focusNode: focusNode,
                    focusedWorkspaceTarget: $focusedWorkspaceTarget,
                    visualizationMode: visualizationMode,
                    maxRenderedDepth: maxRenderedDepth,
                    showFreeSpaceInDiskMaps: showFreeSpaceInDiskMaps,
                    workspaceHiddenNodeIDs: workspaceHiddenNodeIDs,
                    discardPileRootNodeIDs: discardPileRootNodeIDs,
                    movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
                    fullDiskAccessStatus: fullDiskAccessStatus,
                    freeSpaceAvailableCapacity: freeSpaceAvailableCapacity,
                    actions: actions
                )
            } else if scanState.isScanning {
                ScanningWorkspaceState(
                    progress: scanState.progress,
                    selectedTarget: scanState.selectedTarget,
                    actions: actions
                )
            } else {
                EmptyWorkspaceState(
                    startupDiskTarget: startupDiskTarget,
                    actions: actions
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if let folderRescanState = scanState.folderRescanState {
                FolderRescanProgressBanner(
                    state: folderRescanState,
                    progress: scanState.progress,
                    cancel: actions.stopScan
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .topBannerTransition()
            } else if let notice = scanState.scanCompletionNotice {
                ScanCompletionNoticeBanner(
                    notice: notice,
                    dismiss: scanState.dismissScanCompletionNotice
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .topBannerTransition()
            }
        }
        .animation(
            TopBannerPresentation.animation(reduceMotion: reduceMotion),
            value: scanState.folderRescanState
        )
        .animation(
            TopBannerPresentation.animation(reduceMotion: reduceMotion),
            value: scanState.scanCompletionNotice
        )
        .hidingWindowToolbarBackgroundWhenAvailable()
        .toolbar {
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    actions.chooseFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .disabled(scanState.isScanOperationInProgress)
                .help("Choose Folder")

                if scanState.canStopScan {
                    Button {
                        actions.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop Scan")
                } else {
                    Button {
                        actions.rescan()
                    } label: {
                        Label(rescanButtonTitle, systemImage: "arrow.clockwise")
                    }
                    .disabled(!actions.canRescanCurrentFolder())
                    .help(rescanButtonTitle)
                    .workspaceTourAnchor(.rescan)

                    Button {
                        actions.compareScans()
                    } label: {
                        Label("Compare Scans", systemImage: "rectangle.split.2x1")
                    }
                    .disabled(!actions.canCompareScans())
                    .help("Compare Scans")
                }
            }
            ToolbarItem(placement: .automatic) { Spacer() }
            if scanState.snapshot != nil {
                ToolbarItem(placement: .automatic) {
                    visualizationModePicker
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Label(inspectorToggleTitle, systemImage: "sidebar.trailing")
                    }
                    .labelStyle(.iconOnly)
                    .help(inspectorToggleTitle)
                    .workspaceTourAnchor(.inspector)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.handleDroppedURLs(urls)
        }
    }
}

private extension WorkspaceView {
    var rescanButtonTitle: String {
        guard let snapshot = scanState.snapshot,
              let focusNode = navigation.currentFocusNode,
              focusNode.id != snapshot.root.id else {
            return String(localized: "Rescan Entire Scan")
        }
        return String(
            localized: "Rescan \(focusNode.name)",
            comment: "Toolbar action that refreshes the currently focused folder."
        )
    }

    var visualizationModePicker: some View {
        Picker("Disk Map Style", selection: $visualizationMode) {
            Label("Sunburst", systemImage: "chart.pie")
                .labelStyle(.iconOnly)
                .tag(ScanVisualizationMode.sunburst)
            Label("Treemap", systemImage: "rectangle.split.3x3")
                .labelStyle(.iconOnly)
                .tag(ScanVisualizationMode.treemap)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Disk Map Style")
        .accessibilityLabel("Disk map style")
        .workspaceTourAnchor(.visualization)
    }

    var inspectorToggleTitle: String {
        isInspectorPresented
            ? String(localized: "Hide Inspector", comment: "Toolbar action for hiding the inspector sidebar.")
            : String(localized: "Show Inspector", comment: "Toolbar action for showing the inspector sidebar.")
    }
}

private extension View {
    @ViewBuilder
    func hidingWindowToolbarBackgroundWhenAvailable() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
