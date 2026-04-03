//
//  ContentView.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    private let showsInspector = Binding.constant(true)

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            WorkspaceView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        appModel.navigateBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!appModel.canNavigateBack)

                    Button {
                        appModel.navigateForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!appModel.canNavigateForward)
                }

                Button {
                    appModel.presentOpenPanelAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!appModel.canChooseFolder)

                if appModel.canStopScan {
                    Button {
                        appModel.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        appModel.rescan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(!appModel.canRescan)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: showsInspector) {
            SelectionInspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $appModel.showsOnboarding) {
            OnboardingView()
        }
        .alert(
            "Scan Failed",
            isPresented: Binding(
                get: { appModel.lastErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        appModel.lastErrorMessage = nil
                    }
                }
            )
        ) {
            if appModel.selectedTarget != nil {
                Button("Rescan") {
                    appModel.rescan()
                }
                .disabled(!appModel.canRescan)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.lastErrorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(
                get: { appModel.pendingTrashNode != nil },
                set: { newValue in
                    if !newValue {
                        appModel.cancelPendingTrash()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: appModel.pendingTrashNode
        ) { _ in
            Button("Move to Trash", role: .destructive) {
                appModel.confirmMovePendingNodeToTrash()
            }

            Button("Cancel", role: .cancel) {
                appModel.cancelPendingTrash()
            }
        } message: { node in
            Text("Radix will ask macOS to move “\(node.name)” to the Trash.")
        }
    }
}
