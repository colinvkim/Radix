import AppKit
import SwiftUI

struct WorkspaceActions {
    let chooseFolder: () -> Void
    let startScan: (ScanTarget) -> Void
    let stopScan: () -> Void
    let rescan: () -> Void
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
    let selectedFileActions: SelectedFileActions
    let bulkFileActions: BulkFileActions
    let openFullDiskAccessSettings: () -> Void
}

struct SelectedFileActions {
    let quickLook: () -> Void
    let revealInFinder: () -> Void
    let open: () -> Void
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
    let moveToTrash: ([FileNodeRecord]) -> Void
}

struct WorkspaceView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @Binding var isInspectorPresented: Bool
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?

    let maxRenderedDepth: Int
    let startupDiskTarget: ScanTarget?
    let fullDiskAccessStatus: FullDiskAccessStatus
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
                    maxRenderedDepth: maxRenderedDepth,
                    fullDiskAccessStatus: fullDiskAccessStatus,
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .hidingWindowToolbarBackgroundWhenAvailable()
        .toolbar {
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    actions.chooseFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .disabled(scanState.isScanning)
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
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(!scanState.canRescan)
                    .help("Rescan")
                }
            }
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItem(placement: .automatic) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(inspectorToggleTitle, systemImage: "sidebar.trailing")
                }
                .labelStyle(.iconOnly)
                .help(inspectorToggleTitle)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.handleDroppedURLs(urls)
        }
    }
}

private extension WorkspaceView {
    var inspectorToggleTitle: String {
        isInspectorPresented ? "Hide Inspector" : "Show Inspector"
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
