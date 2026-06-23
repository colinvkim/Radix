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
    @FocusState private var focusedWorkspaceTarget: WorkspaceFocusTarget?

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            SidebarView(
                model: appModel.sidebar,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                actions: sidebarActions
            )
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            WorkspaceDetailView(
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                isInspectorPresented: $showsInspector,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                maxRenderedDepth: appModel.maxRenderedDepth,
                showFreeSpaceInSunburst: appModel.showFreeSpaceInSunburst,
                startupDiskTarget: appModel.startupDiskTarget,
                fullDiskAccessStatus: appModel.fullDiskAccessStatus,
                freeSpaceAvailableCapacity: { snapshot, focusNode in
                    appModel.sunburstFreeSpaceAvailableCapacity(for: snapshot, focusNode: focusNode)
                },
                actions: workspaceActions
            )
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.workspaceFocusAction) { target in
            if target == .sidebar {
                splitViewVisibility = .all
            }
            focusedWorkspaceTarget = target
        }
        .background(WorkspaceWindowObserver { window in
            appModel.setWorkspaceWindowNumber(window?.windowNumber)
        })
        .inspector(isPresented: $showsInspector) {
            SelectionInspectorView(
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                fullDiskAccessStatus: appModel.fullDiskAccessStatus,
                actions: selectionInspectorActions
            )
                .inspectorColumnWidth(min: 260, ideal: 320, max: 380)
        }
        .focusedSceneValue(\.inspectorVisibility, $showsInspector)
        .overlay(alignment: .top) {
            if let archiveOperation = appModel.archiveOperation {
                ArchiveOperationBanner(
                    operation: archiveOperation,
                    onCancel: {
                        appModel.cancelArchiveOperation()
                    }
                )
                .padding(.top, 12)
                .padding(.horizontal, 16)
            }
        }
        .sheet(isPresented: $appModel.showsOnboarding) {
            OnboardingView()
        }
        .sheet(item: $appModel.pendingImportPreview) { preview in
            ImportSnapshotPreviewSheet(
                preview: preview,
                onCancel: {
                    appModel.cancelImportPreview()
                },
                onImport: {
                    appModel.confirmImportPreview()
                }
            )
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
                get: { appModel.pendingTrashSelection != nil || appModel.pendingTrashNode != nil },
                set: { newValue in
                    if !newValue {
                        appModel.cancelPendingTrash()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appModel.confirmMovePendingSelectionToTrash()
            }

            Button("Cancel", role: .cancel) {
                appModel.cancelPendingTrash()
            }
        } message: {
            Text(pendingTrashMessage)
        }
        .onDisappear {
            appModel.setWorkspaceWindowNumber(nil)
            appModel.suspendMainWindowActivity()
        }
        .onOpenURL { url in
            guard url.pathExtension == ScanArchiveService.fileExtension else { return }
            appModel.importScanSnapshot(from: url)
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

private struct ArchiveOperationBanner: View {
    let operation: ArchiveOperationState
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            progressView

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.subheadline.weight(.semibold))
                messageText
            }
            .lineLimit(1)

            Button {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var messageText: some View {
        Text(operation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .overlay {
                if shouldShimmerMessage {
                    ShimmeringTextHighlight(text: operation.message)
                }
            }
    }

    private var shouldShimmerMessage: Bool {
        operation.kind == .import && !reduceMotion
    }

    @ViewBuilder
    private var progressView: some View {
        if let progressFraction = operation.progressFraction {
            ProgressView(value: progressFraction, total: 1)
                .frame(width: 96)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct ImportSnapshotPreviewSheet: View {
    let preview: ScanArchivePreview
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Snapshot")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(preview.target.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "archivebox.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                previewRow("Target", preview.target.displayName)
                previewRow("Archived Path", preview.target.path)
                previewRow("Scanned", RadixFormatters.date(preview.finishedAt ?? preview.startedAt))
                previewRow("Exported", RadixFormatters.date(preview.exportedAt))
                previewRow("Total Size", RadixFormatters.size(preview.totalAllocatedSize))
                previewRow("Nodes", preview.nodeCount.formatted())
                previewRow("Files", preview.fileCount.formatted())
                previewRow("Directories", preview.directoryCount.formatted())
                previewRow("Warnings", preview.warningCount.formatted())
                previewRow("Path Mode", pathModeTitle)
                previewRow("App Version", preview.appVersion)
                previewRow("Format", "v\(preview.formatVersion)")
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var pathModeTitle: String {
        switch preview.pathMode {
        case .absolute:
            return "Absolute paths"
        }
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private extension ContentView {
    var sidebarActions: SidebarActions {
        SidebarActions(
            selectTargetAfterViewUpdate: { appModel.selectSidebarTargetAfterViewUpdate(id: $0) },
            revealInFinder: { appModel.revealTargetInFinder($0) },
            removeRecentTarget: { appModel.removeRecentTarget($0) }
        )
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
    @Binding var isInspectorPresented: Bool
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?

    let maxRenderedDepth: Int
    let showFreeSpaceInSunburst: Bool
    let startupDiskTarget: ScanTarget?
    let fullDiskAccessStatus: FullDiskAccessStatus
    let freeSpaceAvailableCapacity: (ScanSnapshot, FileNodeRecord) -> Int64?
    let actions: WorkspaceActions

    var body: some View {
        WorkspaceView(
            scanState: scanState,
            navigation: navigation,
            isInspectorPresented: $isInspectorPresented,
            focusedWorkspaceTarget: $focusedWorkspaceTarget,
            maxRenderedDepth: maxRenderedDepth,
            showFreeSpaceInSunburst: showFreeSpaceInSunburst,
            startupDiskTarget: startupDiskTarget,
            fullDiskAccessStatus: fullDiskAccessStatus,
            freeSpaceAvailableCapacity: freeSpaceAvailableCapacity,
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
                    .help("Back")

                    Button {
                        actions.navigateForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!navigation.canNavigateForward)
                    .help("Forward")
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
            selectNodeImmediately: { appModel.select(nodeID: $0) },
            selectNode: { appModel.selectAfterViewUpdate(nodeID: $0) },
            selectNodesImmediately: { appModel.select(nodeIDs: $0, primaryNodeID: $1) },
            selectNodes: { appModel.selectAfterViewUpdate(nodeIDs: $0, primaryNodeID: $1) },
            focusNode: { appModel.focusAfterViewUpdate(nodeID: $0) },
            selectAndFocusNode: { appModel.selectAndFocusAfterViewUpdate(nodeID: $0) },
            navigateBack: { appModel.navigateBack() },
            navigateForward: { appModel.navigateForward() },
            navigateToParent: { appModel.navigateToParent() },
            expandSummarizedNode: { appModel.expandSummarizedNode($0) {} },
            zoomIntoSelection: { appModel.zoomIntoSelection() },
            selectedFileActions: previewSelectedFileActions,
            bulkFileActions: bulkFileActions,
            openFullDiskAccessSettings: { appModel.prepareAndOpenFullDiskAccessSettings() }
        )
    }

    var selectionInspectorActions: SelectionInspectorActions {
        SelectionInspectorActions(
            selectNodeAfterViewUpdate: { appModel.selectAfterViewUpdate(nodeID: $0) },
            selectAndFocusNodeAfterViewUpdate: { appModel.selectAndFocusAfterViewUpdate(nodeID: $0) },
            expandSummarizedNode: { appModel.expandSummarizedNode($0) {} },
            zoomIntoSelection: { appModel.zoomIntoSelection() },
            selectedFileActions: primarySelectedFileActions,
            openFullDiskAccessSettings: { appModel.prepareAndOpenFullDiskAccessSettings() }
        )
    }

    var primarySelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.previewSelectedWithQuickLook() },
            revealInFinder: { appModel.revealPrimarySelectionInFinder() },
            open: { appModel.openSelected() },
            copyPath: { appModel.copyPrimarySelectionPath() },
            moveToTrash: { appModel.requestMovePrimarySelectionToTrash() }
        )
    }

    var previewSelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.previewSelectedWithQuickLook() },
            revealInFinder: { appModel.revealSelectedInFinder() },
            open: { appModel.openSelected() },
            copyPath: { appModel.copySelectedPath() },
            moveToTrash: { appModel.requestMoveSelectedToTrash() }
        )
    }

    var bulkFileActions: BulkFileActions {
        BulkFileActions(
            revealInFinder: { appModel.revealNodesInFinder($0) },
            copyPaths: { appModel.copyPaths(for: $0) },
            moveToTrash: { appModel.requestMoveNodesToTrash($0) }
        )
    }

    var pendingTrashMessage: String {
        let nodes = appModel.pendingTrashSelection?.nodes ?? appModel.pendingTrashNode.map { [$0] } ?? []
        guard nodes.count != 1 else {
            return "Radix will ask macOS to move \(nodes[0].url.path) to the Trash."
        }
        let shownPaths = nodes.prefix(3).map(\.url.path).joined(separator: "\n")
        let remainingCount = nodes.count - 3
        let remainingText = remainingCount > 0 ? "\n+\(remainingCount) more" : ""
        return "Radix will ask macOS to move \(nodes.count) selected items to the Trash:\n\(shownPaths)\(remainingText)"
    }
}
