import AppKit
import SwiftUI

struct WorkspaceActions {
    let chooseFolder: () -> Void
    let startScan: (ScanTarget) -> Void
    let stopScan: () -> Void
    let rescan: () -> Void
    let handleDroppedURLs: ([URL]) -> Bool
    let selectNode: (String?) -> Void
    let focusNode: (String?) -> Void
    let selectAndFocusNode: (String) -> Void
    let navigateBack: () -> Void
    let navigateForward: () -> Void
    let openFullDiskAccessSettings: () -> Void
}

struct WorkspaceView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let maxRenderedDepth: Int
    let startupDiskTarget: ScanTarget?
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
                    maxRenderedDepth: maxRenderedDepth,
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

                if scanState.canStopScan {
                    Button {
                        actions.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        actions.rescan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(!scanState.canRescan)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.handleDroppedURLs(urls)
        }
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
