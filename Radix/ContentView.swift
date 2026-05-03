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
    @State private var showsInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                WorkspaceView()
                    .toolbar {
                        ToolbarItemGroup(placement: .navigation) {
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
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showsInspector) {
            SelectionInspectorView()
                .inspectorColumnWidth(min: 260, ideal: 320, max: 380)
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
