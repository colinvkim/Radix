//
//  ContentView.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var showsInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            WorkspaceDetailView(
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                maxRenderedDepth: appModel.maxRenderedDepth,
                startupDiskTarget: appModel.startupDiskTarget,
                actions: workspaceActions
            )
        }
        .navigationSplitViewStyle(.balanced)
        .background(WorkspaceWindowObserver { window in
            appModel.setWorkspaceWindowNumber(window?.windowNumber)
        })
        .inspector(isPresented: $showsInspector) {
            SelectionInspectorView(
                scanState: appModel.scanState,
                navigation: appModel.navigation
            )
                .inspectorColumnWidth(min: 260, ideal: 320, max: 380)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $appModel.showsOnboarding) {
            OnboardingView()
        }
        .alert(
            appModel.errorAlertTitle,
            isPresented: Binding(
                get: { appModel.lastErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        appModel.lastErrorMessage = nil
                    }
                }
            )
        ) {
            if appModel.canRescanFromErrorAlert {
                Button("Rescan") {
                    appModel.rescan()
                }
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
        .onDisappear {
            appModel.setWorkspaceWindowNumber(nil)
            appModel.suspendMainWindowActivity()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                appModel.refreshFullDiskAccessStatus()
            case .background:
                appModel.suspendBackgroundActivity()
            default:
                break
            }
        }
    }
}

private struct WorkspaceWindowObserver: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.reportWindowIfNeeded()
    }

    final class WindowView: NSView {
        var onWindowChange: (NSWindow?) -> Void = { _ in }
        private var hasReportedWindow = false
        private var lastReportedWindowID: ObjectIdentifier?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowIfNeeded()
        }

        func reportWindowIfNeeded() {
            let reportedWindow = window
            let reportedWindowID = reportedWindow.map(ObjectIdentifier.init)
            guard !hasReportedWindow || reportedWindowID != lastReportedWindowID else { return }

            hasReportedWindow = true
            lastReportedWindowID = reportedWindowID

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.window.map(ObjectIdentifier.init) == reportedWindowID else {
                    self.reportWindowIfNeeded()
                    return
                }
                self.onWindowChange(reportedWindow)
            }
        }
    }
}

private struct WorkspaceDetailView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let maxRenderedDepth: Int
    let startupDiskTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        NavigationStack {
            WorkspaceView(
                scanState: scanState,
                navigation: navigation,
                maxRenderedDepth: maxRenderedDepth,
                startupDiskTarget: startupDiskTarget,
                actions: actions
            )
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            actions.navigateBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!navigation.canNavigateBack)

                        Button {
                            actions.navigateForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .disabled(!navigation.canNavigateForward)
                    }
                }
        }
    }
}

private extension ContentView {
    var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            chooseFolder: { appModel.presentOpenPanelAndScan() },
            startScan: { appModel.startScan($0) },
            stopScan: { appModel.stopScan() },
            rescan: { appModel.rescan() },
            handleDroppedURLs: { appModel.handleDroppedURLs($0) },
            selectNode: { appModel.selectAfterViewUpdate(nodeID: $0) },
            focusNode: { appModel.focusAfterViewUpdate(nodeID: $0) },
            selectAndFocusNode: { appModel.selectAndFocusAfterViewUpdate(nodeID: $0) },
            navigateBack: { appModel.navigateBack() },
            navigateForward: { appModel.navigateForward() },
            openFullDiskAccessSettings: { appModel.prepareAndOpenFullDiskAccessSettings() }
        )
    }
}
