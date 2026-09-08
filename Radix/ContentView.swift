//
//  ContentView.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    private static let discardPileDragActivationDistance: CGFloat = 10

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var showsInspector = false
    @State private var prefersInspectorPresented = true
    @State private var inspectorPreferenceBeforeTour: Bool?
    @State private var sidebarVisibilityBeforeTour: NavigationSplitViewVisibility?
    @State private var discardPileDragIsActive = false
    @State private var discardPileDragMonitorTask: Task<Void, Never>?
    @StateObject private var tourPresentation = WorkspaceTourPresentation()
    @FocusState private var focusedWorkspaceTarget: WorkspaceFocusTarget?

    var body: some View {
        let discardPileSnapshot = appModel.discardPileSnapshot

        NavigationSplitView(columnVisibility: workspaceColumnVisibility) {
            SidebarView(
                model: appModel.sidebar,
                scanState: appModel.scanState,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                discardPileSummary: discardPileSnapshot.summary,
                discardPileDragIsActive: discardPileDragIsActive,
                actions: sidebarActions
            )
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            WorkspaceDetailView(
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                scanComparison: appModel.scanComparison,
                isInspectorPresented: inspectorPresentation,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                visualizationMode: Binding(
                    get: { appModel.scanVisualizationMode },
                    set: { appModel.setScanVisualizationModeAfterViewUpdate($0) }
                ),
                maxRenderedDepth: appModel.maxRenderedDepth,
                showFreeSpaceInDiskMaps: appModel.showFreeSpaceInDiskMaps,
                workspaceHiddenNodeIDs: appModel.workspaceHiddenNodeIDs,
                discardPileRootNodeIDs: appModel.discardPileRootNodeIDs,
                movingToTrashRootNodeIDs: appModel.movingToTrashRootNodeIDs,
                startupDiskTarget: appModel.startupDiskTarget,
                fullDiskAccessStatus: appModel.fullDiskAccessStatus,
                freeSpaceAvailableCapacity: { snapshot, focusNode in
                    appModel.cachedFreeSpaceAvailableCapacity(for: snapshot, focusNode: focusNode)
                },
                closeScanComparison: {
                    appModel.closeScanComparison()
                },
                comparisonRowActions: comparisonRowActions,
                actions: workspaceActions
            )
            .id(appModel.workspaceTourSessionID)
            .overlay(alignment: .topTrailing) {
                WorkspaceTourCard(tour: appModel.workspaceTour, presentation: tourPresentation)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            WorkspaceTourHost(
                tour: appModel.workspaceTour,
                navigation: appModel.navigation,
                presentation: tourPresentation,
                canPresent: appModel.presentationCoordinator.activeSheet == nil
                    && appModel.presentationCoordinator.activeDialog == nil
                    && appModel.scanComparison == nil
            )
        }
        .environmentObject(appModel.workspaceTour)
        .environmentObject(tourPresentation)
        .focusedSceneValue(\.workspaceFocusAction) { target in
            guard appModel.scanComparison == nil else { return }
            if target == .sidebar {
                splitViewVisibility = .all
            }
            focusedWorkspaceTarget = target
        }
        .background(WorkspaceWindowObserver { window in
            appModel.setWorkspaceWindowNumber(window?.windowNumber)
        })
        .inspector(isPresented: inspectorPresentation) {
            SelectionInspectorView(
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                fullDiskAccessStatus: appModel.fullDiskAccessStatus,
                discardPileRootNodeIDs: appModel.discardPileRootNodeIDs,
                actions: selectionInspectorActions
            )
                .inspectorColumnWidth(min: 260, ideal: 320, max: 380)
        }
        .focusedSceneValue(\.inspectorVisibility, inspectorPresentation)
        .onChange(of: appModel.workspaceTourSessionID) { _, sessionID in
            if sessionID != nil {
                inspectorPreferenceBeforeTour = prefersInspectorPresented
                sidebarVisibilityBeforeTour = splitViewVisibility
                splitViewVisibility = .all
            } else {
                if let preference = inspectorPreferenceBeforeTour {
                    inspectorPreferenceBeforeTour = nil
                    prefersInspectorPresented = preference
                    setInspectorPresented(preference && canPresentInspector)
                }
                if let visibility = sidebarVisibilityBeforeTour {
                    sidebarVisibilityBeforeTour = nil
                    splitViewVisibility = visibility
                }
            }
        }
        .onReceive(appModel.workspaceTour.$step) { step in
            if step == .markForReview || step == .review {
                splitViewVisibility = .all
            }
        }
        .onReceive(appModel.scanState.$snapshot) { snapshot in
            updateInspectorPresentation(hasSnapshot: snapshot != nil)
        }
        .onChange(of: appModel.scanComparison != nil) { _, isComparing in
            if isComparing {
                focusedWorkspaceTarget = nil
                setInspectorPresented(false)
            } else {
                Task { @MainActor in
                    await Task.yield()
                    guard appModel.scanComparison == nil else { return }
                    updateInspectorPresentation(
                        hasSnapshot: appModel.scanState.snapshot != nil
                    )
                }
            }
        }
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
                .topBannerTransition()
            } else if appModel.exportConfirmation != nil {
                ExportConfirmationBanner(
                    onReveal: {
                        appModel.revealExportedSnapshotInFinder()
                    },
                    onDismiss: {
                        appModel.dismissExportConfirmation()
                    }
                )
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .topBannerTransition()
            }
        }
        .animation(
            TopBannerPresentation.animation(reduceMotion: reduceMotion),
            value: appModel.archiveOperation?.id
        )
        .animation(
            TopBannerPresentation.animation(reduceMotion: reduceMotion),
            value: appModel.exportConfirmation?.id
        )
        .sheet(item: activeSheetBinding) { sheet in
            switch sheet {
            case .onboarding:
                OnboardingView()
            case .discardPileReview:
                DiscardPileReviewSheet(
                    snapshot: discardPileSnapshot,
                    actions: DiscardPileReviewActions(
                        removeNodes: { nodeIDs in
                            appModel.removeDiscardPileNodes(ids: nodeIDs)
                        },
                        clear: {
                            appModel.clearDiscardPile()
                        },
                        dismiss: {
                            appModel.dismissDiscardPileReview()
                        },
                        moveToTrash: {
                            if appModel.requestMoveDiscardPileToTrash() {
                                appModel.dismissDiscardPileReview()
                            }
                        }
                    )
                )
                .environmentObject(appModel.workspaceTour)
            case .importPreview:
                if let preview = appModel.pendingImportPreview {
                    ImportSnapshotPreviewSheet(
                        preview: preview,
                        onCancel: {
                            appModel.cancelImportPreview()
                        },
                        onImport: {
                            appModel.confirmImportPreview()
                        }
                    )
                    .interactiveDismissDisabled()
                }
            case .comparisonSetup:
                if let setup = appModel.pendingComparisonSetup {
                    ScanComparisonSetupSheet(
                        setup: setup,
                        canUseCurrentScan: appModel.canUseCurrentScanInComparisonSetup,
                        onChooseSnapshot: { slot in
                            appModel.chooseComparisonSnapshot(for: slot)
                        },
                        onDropSnapshot: { url, slot in
                            appModel.dropComparisonSnapshot(url, for: slot)
                        },
                        onUseCurrentScan: { slot in
                            appModel.useCurrentScanForComparisonSlot(slot)
                        },
                        onClear: { slot in
                            appModel.clearComparisonSlot(slot)
                        },
                        onSwap: {
                            appModel.swapPendingComparisonSetup()
                        },
                        onCancel: {
                            appModel.cancelComparisonSetup()
                        },
                        onCompare: {
                            appModel.confirmComparisonSetup()
                        }
                    )
                    .interactiveDismissDisabled()
                }
            }
        }
        .alert(
            appModel.errorAlertTitle,
            isPresented: Binding(
                get: {
                    appModel.presentationCoordinator.activeDialog == .error &&
                        appModel.lastErrorMessage != nil
                },
                set: { newValue in
                    if !newValue {
                        appModel.dismissErrorPresentation()
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
            Text(appModel.lastErrorMessage ?? String(localized: "Unknown error", comment: "Fallback error message when no specific error is available."))
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(
                get: {
                    appModel.presentationCoordinator.activeDialog == .trashConfirmation &&
                        appModel.pendingTrashSelection != nil
                },
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
        .confirmationDialog(
            cloudFileConfirmationTitle,
            isPresented: Binding(
                get: {
                    appModel.presentationCoordinator.activeDialog == .cloudFileConfirmation &&
                        appModel.pendingCloudFileAction != nil
                },
                set: { newValue in
                    if !newValue {
                        appModel.cancelPendingCloudFileAction()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(cloudFileConfirmationButtonTitle, role: cloudFileConfirmationButtonRole) {
                appModel.confirmPendingCloudFileAction()
            }

            Button("Cancel", role: .cancel) {
                appModel.cancelPendingCloudFileAction()
            }
        } message: {
            Text(cloudFileConfirmationMessage)
        }
        .onDisappear {
            discardPileDragDidEnd()
            appModel.setWorkspaceWindowNumber(nil)
            appModel.suspendMainWindowActivity()
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == ScanArchiveService.fileExtension else { return }
            appModel.openScanSnapshotArchive(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                appModel.refreshFullDiskAccessStatus()
            case .background:
                discardPileDragDidEnd()
                appModel.suspendBackgroundActivity()
            case .inactive:
                discardPileDragDidEnd()
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .topBannerSurface()
    }

    private var messageText: some View {
        Text(operation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .overlay {
                if shouldShimmerMessage {
                    ShimmeringTextHighlight(
                        text: operation.message,
                        font: .caption
                    )
                }
            }
    }

    private var shouldShimmerMessage: Bool {
        (operation.kind == .import || operation.kind == .importPreview || operation.kind == .export || operation.kind == .compare) && !reduceMotion
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

private struct ExportConfirmationBanner: View {
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text("Snapshot Exported")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Show in Finder") {
                onReveal()
            }
            .buttonStyle(.borderless)

            Button {
                onDismiss()
            } label: {
                Label("Dismiss", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .topBannerSurface()
    }
}

private struct ImportSnapshotPreviewSheet: View {
    let preview: ScanArchivePreview
    let onCancel: () -> Void
    let onImport: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Import Snapshot", systemImage: "archivebox.fill")
                .font(.title3.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary, .tint)

            VStack(alignment: .leading, spacing: 5) {
                Text(preview.target.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(preview.target.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(preview.target.path)

                Label(
                    "Scanned \(RadixFormatters.date(preview.finishedAt ?? preview.startedAt))",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ImportSnapshotStatCard(
                    title: "Scanned Data",
                    value: RadixFormatters.size(preview.totalAllocatedSize)
                )
                ImportSnapshotStatCard(
                    title: "Files",
                    value: preview.fileCount.formatted()
                )
                ImportSnapshotStatCard(
                    title: "Folders",
                    value: preview.directoryCount.formatted()
                )
                ImportSnapshotStatCard(
                    title: "Snapshot Size",
                    value: RadixFormatters.size(preview.archiveSize)
                )
            }

            Divider()

            HStack {
                Button("Details…", systemImage: "info.circle") {
                    showsDetails.toggle()
                }
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    ImportSnapshotDetailsPopover(preview: preview)
                }

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
        .frame(width: 480, alignment: .topLeading)
    }
}

private struct ImportSnapshotDetailsPopover: View {
    let preview: ScanArchivePreview

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            detailRow("Exported", RadixFormatters.date(preview.exportedAt))
            detailRow("Nodes", preview.nodeCount.formatted())
            detailRow("App Version", preview.appVersion)
        }
        .font(.subheadline)
        .padding(16)
        .frame(minWidth: 260)
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
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

private struct ImportSnapshotStatCard: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private extension ContentView {
    var activeSheetBinding: Binding<AppPresentationCoordinator.Sheet?> {
        Binding(
            get: { appModel.presentationCoordinator.activeSheet },
            set: { newValue in
                if newValue == nil {
                    appModel.dismissActiveSheet()
                }
            }
        )
    }

    var sidebarActions: SidebarActions {
        SidebarActions(
            selectTargetAfterViewUpdate: { appModel.selectSidebarTargetAfterViewUpdate(id: $0) },
            revealInFinder: { appModel.revealTargetInFinder($0) },
            removeRecentTarget: { appModel.removeRecentTarget($0) },
            reviewDiscardPile: { appModel.presentDiscardPileReview() },
            addDroppedNodesToDiscardPile: { nodeIDs, snapshotID in
                defer { discardPileDragDidEnd() }
                return appModel.addNodeIDsToDiscardPile(nodeIDs, snapshotID: snapshotID)
            }
        )
    }

    private func discardPileDragDidEnd() {
        discardPileDragMonitorTask?.cancel()
        discardPileDragMonitorTask = nil
        discardPileDragIsActive = false
    }

    private func setDiscardPileDragIsActive(_ isActive: Bool) {
        guard isActive else {
            discardPileDragDidEnd()
            return
        }

        discardPileDragIsActive = true
        discardPileDragMonitorTask?.cancel()
        discardPileDragMonitorTask = Task { @MainActor in
            await monitorDiscardPileDragUntilMouseUp()
        }
    }

    private func setDiscardPileDragIsActiveAfterThreshold(_ isActive: Bool) {
        guard isActive else {
            discardPileDragDidEnd()
            return
        }

        guard discardPileDragMonitorTask == nil else { return }

        let initialMouseLocation = NSEvent.mouseLocation
        discardPileDragMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                guard NSEvent.pressedMouseButtons & 1 != 0 else {
                    discardPileDragDidEnd()
                    return
                }

                if Self.mouseLocation(
                    NSEvent.mouseLocation,
                    isAtLeast: Self.discardPileDragActivationDistance,
                    from: initialMouseLocation
                ) {
                    discardPileDragIsActive = true
                    await monitorDiscardPileDragUntilMouseUp()
                    return
                }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func monitorDiscardPileDragUntilMouseUp() async {
        try? await Task.sleep(for: .milliseconds(120))

        while !Task.isCancelled {
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                discardPileDragDidEnd()
                return
            }

            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private static func mouseLocation(_ location: NSPoint, isAtLeast distance: CGFloat, from origin: NSPoint) -> Bool {
        let dx = location.x - origin.x
        let dy = location.y - origin.y
        return ((dx * dx) + (dy * dy)) >= (distance * distance)
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
    let scanComparison: ScanComparison?
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
    let closeScanComparison: () -> Void
    let comparisonRowActions: ScanComparisonRowActions
    let actions: WorkspaceActions

    var body: some View {
        if let scanComparison {
            ScanComparisonView(
                comparison: scanComparison,
                actions: comparisonRowActions,
                onClose: closeScanComparison
            )
        } else {
            WorkspaceView(
                scanState: scanState,
                navigation: navigation,
                isInspectorPresented: $isInspectorPresented,
                focusedWorkspaceTarget: $focusedWorkspaceTarget,
                visualizationMode: $visualizationMode,
                maxRenderedDepth: maxRenderedDepth,
                showFreeSpaceInDiskMaps: showFreeSpaceInDiskMaps,
                workspaceHiddenNodeIDs: workspaceHiddenNodeIDs,
                discardPileRootNodeIDs: discardPileRootNodeIDs,
                movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
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
}

private extension ContentView {
    var workspaceColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                appModel.scanComparison == nil ? splitViewVisibility : .detailOnly
            },
            set: { visibility in
                guard appModel.scanComparison == nil else { return }
                splitViewVisibility = visibility
            }
        )
    }

    var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { showsInspector },
            set: { isPresented in
                if canPresentInspector {
                    prefersInspectorPresented = isPresented
                }
                setInspectorPresented(isPresented && canPresentInspector)
            }
        )
    }

    var canPresentInspector: Bool {
        appModel.scanState.snapshot != nil && appModel.scanComparison == nil
    }

    func updateInspectorPresentation(hasSnapshot: Bool) {
        setInspectorPresented(
            prefersInspectorPresented && hasSnapshot && appModel.scanComparison == nil
        )
    }

    func setInspectorPresented(_ isPresented: Bool) {
        guard showsInspector != isPresented else { return }

        withTransaction(Transaction(animation: nil)) {
            showsInspector = isPresented
        }
    }

    var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            makeFileBrowserModel: { appModel.makeFileBrowserModel() },
            chooseFolder: { appModel.presentOpenPanelAndScan() },
            startScan: { appModel.startScan($0) },
            stopScan: { appModel.stopScan() },
            rescan: { appModel.rescan() },
            rescanFolder: { appModel.rescanFolder(id: $0) },
            canRescanCurrentFolder: { appModel.canRescanCurrentFolder },
            compareScans: { appModel.compareScanSnapshots() },
            canCompareScans: { appModel.canCompareScanSnapshots },
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
            recordSunburstSegmentClick: { appModel.recordSunburstSegmentClick() },
            selectedFileActions: previewSelectedFileActions,
            bulkFileActions: bulkFileActions,
            openFullDiskAccessSettings: { appModel.prepareAndOpenFullDiskAccessSettings() },
            setDiscardPileDragActive: setDiscardPileDragIsActive,
            setDiscardPileDragActiveAfterThreshold: setDiscardPileDragIsActiveAfterThreshold
        )
    }

    var comparisonRowActions: ScanComparisonRowActions {
        ScanComparisonRowActions(
            reveal: { appModel.revealComparisonRowInFinder($0) },
            canReveal: { appModel.canRevealComparisonRowInFinder($0) },
            showInBrowser: { appModel.showComparisonRowInBrowser($0) },
            canShowInBrowser: { appModel.canShowComparisonRowInBrowser($0) },
            copyPath: { appModel.copyComparisonRowPath($0) },
            revealNode: { appModel.revealComparisonChangeNodeInFinder($0) },
            canRevealNode: { appModel.canRevealComparisonChangeNodeInFinder($0) },
            showNodeInBrowser: { appModel.showComparisonChangeNodeInBrowser($0) },
            canShowNodeInBrowser: { appModel.canShowComparisonChangeNodeInBrowser($0) },
            copyNodePath: { appModel.copyComparisonChangeNodePath($0) }
        )
    }

    var selectionInspectorActions: SelectionInspectorActions {
        SelectionInspectorActions(
            selectNodeAfterViewUpdate: { appModel.selectAfterViewUpdate(nodeID: $0) },
            selectAndFocusNodeAfterViewUpdate: { appModel.selectAndFocusAfterViewUpdate(nodeID: $0) },
            expandSummarizedNode: { appModel.expandSummarizedNode($0) {} },
            selectedFileActions: primarySelectedFileActions,
            addPrimarySelectionToDiscardPile: { appModel.addPrimarySelectionToDiscardPileAfterViewUpdate() },
            removeDiscardPileNode: { appModel.removeDiscardPileNode(id: $0) },
            presentDiscardPileReview: { appModel.presentDiscardPileReview() },
            bulkFileActions: bulkFileActions,
            openFullDiskAccessSettings: { appModel.prepareAndOpenFullDiskAccessSettings() }
        )
    }

    var primarySelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.previewSelectedWithQuickLook() },
            revealInFinder: { appModel.revealPrimarySelectionInFinder() },
            open: { appModel.openSelected() },
            openInTerminal: { Task { await appModel.openSelectedInTerminal() } },
            copyPath: { appModel.copyPrimarySelectionPath() },
            moveToTrash: { appModel.requestMovePrimarySelectionToTrash() }
        )
    }

    var previewSelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.previewSelectedWithQuickLook() },
            revealInFinder: { appModel.revealSelectedInFinder() },
            open: { appModel.openSelected() },
            openInTerminal: { Task { await appModel.openSelectedInTerminal() } },
            copyPath: { appModel.copySelectedPath() },
            moveToTrash: { appModel.requestMoveSelectedToTrash() }
        )
    }

    var bulkFileActions: BulkFileActions {
        BulkFileActions(
            revealInFinder: { appModel.revealNodesInFinder($0) },
            copyPaths: { appModel.copyPaths(for: $0) },
            addToDiscardPile: { appModel.addNodesToDiscardPile($0) },
            moveToTrash: { appModel.requestMoveNodesToTrash($0) }
        )
    }

    var pendingTrashMessage: String {
        let nodes = appModel.pendingTrashSelection?.nodes ?? []
        guard nodes.count != 1 else {
            return String(localized: "Radix will ask macOS to move \(nodes[0].url.path) to the Trash.", comment: "Confirmation message for moving one selected item to the Trash.")
        }
        let shownPaths = nodes.prefix(3).map(\.url.path).joined(separator: "\n")
        let remainingCount = nodes.count - 3
        let remainingText = remainingCount > 0
            ? "\n" + String(localized: "+\(remainingCount) more", comment: "Additional selected paths omitted from the Trash confirmation list.")
            : ""
        return String(localized: "Radix will ask macOS to move \(nodes.count) selected items to the Trash:\n\(shownPaths)\(remainingText)", comment: "Confirmation message listing multiple selected items that will be moved to the Trash.")
    }

    var cloudFileConfirmationTitle: String {
        guard let action = appModel.pendingCloudFileAction else {
            return String(localized: "Cloud Storage", comment: "Fallback title for a cloud-storage confirmation dialog.")
        }
        switch (action.kind, action.nodes.count == 1) {
        case (.addToDiscardPile, true):
            return String(localized: "Add Cloud Item to Discard Pile?", comment: "Confirmation title before adding one cloud-stored item to the Discard Pile.")
        case (.addToDiscardPile, false):
            return String(localized: "Add Cloud Items to Discard Pile?", comment: "Confirmation title before adding multiple cloud-stored items to the Discard Pile.")
        case (.moveToTrash, true):
            return String(localized: "Move Cloud Item to Trash?", comment: "Second confirmation title before moving one cloud-stored item to the Trash.")
        case (.moveToTrash, false):
            return String(localized: "Move Cloud Items to Trash?", comment: "Second confirmation title before moving multiple cloud-stored items to the Trash.")
        }
    }

    var cloudFileConfirmationButtonTitle: String {
        switch appModel.pendingCloudFileAction?.kind {
        case .addToDiscardPile:
            String(localized: "Add to Discard Pile", comment: "Confirmation button for adding a cloud-stored item to the Discard Pile.")
        case .moveToTrash:
            String(localized: "Move to Trash", comment: "Confirmation button for moving a cloud-stored item to the Trash.")
        case nil:
            String(localized: "Continue", comment: "Fallback action title for a cloud-file confirmation dialog.")
        }
    }

    var cloudFileConfirmationButtonRole: ButtonRole? {
        guard case .moveToTrash = appModel.pendingCloudFileAction?.kind else {
            return nil
        }
        return .destructive
    }

    var cloudFileConfirmationMessage: String {
        guard let action = appModel.pendingCloudFileAction else {
            return String(localized: "This selection is stored in cloud storage.", comment: "Fallback warning for a cloud-file confirmation dialog.")
        }
        switch (action.kind, action.cloudImpact) {
        case (.addToDiscardPile, .storedInCloud):
            return String(localized: "This selection is stored in cloud storage. If you later move it to the Trash, it may also be deleted from the cloud and other synced devices.", comment: "Warning shown before adding cloud-stored items to the Discard Pile.")
        case (.moveToTrash, .storedInCloud):
            return String(localized: "This selection is stored in cloud storage. Moving it to the Trash may also delete it from the cloud and other synced devices.", comment: "Second warning shown before moving cloud-stored items to the Trash.")
        case (.addToDiscardPile, .containsCloudStorage):
            return String(localized: "This selection contains a cloud storage folder. If you later move it to the Trash, cloud files inside it may also be deleted from the cloud and other synced devices.", comment: "Warning shown before adding an ancestor of a cloud storage folder to the Discard Pile.")
        case (.moveToTrash, .containsCloudStorage):
            return String(localized: "This selection contains a cloud storage folder. Moving it to the Trash may also delete cloud files inside it from the cloud and other synced devices.", comment: "Second warning shown before moving an ancestor of a cloud storage folder to the Trash.")
        }
    }
}
