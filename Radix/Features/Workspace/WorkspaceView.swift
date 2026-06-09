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

private struct ActiveWorkspaceView: View {
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    let maxRenderedDepth: Int
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(
                navigation: navigation,
                snapshot: snapshot,
                focusNode: focusNode,
                actions: actions
            )

            Divider()

            if PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot) {
                PermissionBanner(actions: actions)
                Divider()
            }

            resizableWorkspacePanes
        }
    }

    private var resizableWorkspacePanes: some View {
        WorkspaceSplitView(topMinHeight: 260, bottomMinHeight: 200) {
            visualizationPane
        } bottom: {
            contentsPane
        }
    }

    private var visualizationPane: some View {
        VStack(spacing: 0) {
            chartContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartContent: some View {
        SunburstChartView(
            rootNode: focusNode,
            treeStore: snapshot.treeStore,
            selectedNodeID: navigation.selectedNodeID,
            selectedAncestorIDs: navigation.selectedAncestorIDs,
            depthLimit: maxRenderedDepth,
            layoutID: "\(snapshot.id.uuidString)|\(focusNode.id)|\(maxRenderedDepth)",
            onSelect: actions.selectNode,
            onZoom: actions.focusNode
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private var contentsPane: some View {
        VStack(spacing: 0) {
            FileBrowserTableView(
                scanState: scanState,
                navigation: navigation
            )

            if !snapshot.scanWarnings.isEmpty {
                Divider()
                WarningFooter(
                    warnings: snapshot.scanWarnings,
                    shouldSuggestFullDiskAccess: PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot),
                    actions: actions
                )
            }
        }
    }
}

/// Pure SwiftUI replacement for `VSplitView`.
///
/// `VSplitView` (NSSplitView-backed) combined with `.inspector` makes AppKit
/// re-enter the Update Constraints in Window pass until NSWindow throws
/// `NSGenericException` ("more Update Constraints in Window passes than there
/// are views in the window"), crashing the app once scan content is visible.
private struct WorkspaceSplitView<Top: View, Bottom: View>: View {
    private static var dividerHitHeight: CGFloat { 9 }

    let topMinHeight: CGFloat
    let bottomMinHeight: CGFloat
    private let top: Top
    private let bottom: Bottom

    @State private var topFraction: CGFloat = 0.56
    @State private var dragStartFraction: CGFloat?

    init(
        topMinHeight: CGFloat,
        bottomMinHeight: CGFloat,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.topMinHeight = topMinHeight
        self.bottomMinHeight = bottomMinHeight
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { proxy in
            let contentHeight = max(proxy.size.height - Self.dividerHitHeight, 0)

            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight(forContentHeight: contentHeight))
                    .clipped()

                divider(contentHeight: contentHeight)

                bottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func divider(contentHeight: CGFloat) -> some View {
        ZStack {
            Divider()
            PaneResizeCursorRect()
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.dividerHitHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard contentHeight > 0 else { return }

                    let baseFraction = dragStartFraction ?? topFraction
                    dragStartFraction = baseFraction
                    topFraction = clampedFraction(
                        baseFraction + (value.translation.height / contentHeight),
                        contentHeight: contentHeight
                    )
                }
                .onEnded { _ in
                    dragStartFraction = nil
                }
        )
        .accessibilityLabel("Resize panes")
    }

    private func topHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        clampedFraction(topFraction, contentHeight: contentHeight) * contentHeight
    }

    private func clampedFraction(_ fraction: CGFloat, contentHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return fraction }

        let minimums = constrainedMinimumHeights(for: contentHeight)
        let lowerBound = minimums.top / contentHeight
        let upperBound = max((contentHeight - minimums.bottom) / contentHeight, lowerBound)
        return min(max(fraction, lowerBound), upperBound)
    }

    private func constrainedMinimumHeights(for totalHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let minimumHeight = topMinHeight + bottomMinHeight
        guard minimumHeight > 0, totalHeight < minimumHeight else {
            return (topMinHeight, bottomMinHeight)
        }

        let scale = max(totalHeight, 0) / minimumHeight
        return (topMinHeight * scale, bottomMinHeight * scale)
    }
}

private struct PaneResizeCursorRect: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorRectView {
        CursorRectView()
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorRectView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct WorkspaceHeaderView: View {
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord
    let actions: WorkspaceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(focusNode.name)
                        .font(.title2.weight(.semibold))

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                Spacer(minLength: 16)

                if let finishedAt = snapshot.finishedAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last Scan")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(RadixFormatters.date(finishedAt))
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    BreadcrumbBar(
                        nodes: navigation.breadcrumbNodes,
                        onSelect: actions.focusNode
                    )

                    Spacer(minLength: 12)

                    MetricStrip(snapshot: snapshot)
                }

                VStack(alignment: .leading, spacing: 10) {
                    BreadcrumbBar(
                        nodes: navigation.breadcrumbNodes,
                        onSelect: actions.focusNode
                    )

                    MetricStrip(snapshot: snapshot)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusSubtitle: String {
        snapshot.target.url.path
    }
}

private struct WorkspaceMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionBanner: View {
    let actions: WorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Protected folders were skipped.")
                    .font(.headline)

                Text("Grant Full Disk Access for more complete scans of Mail, Safari, Messages, and Library content.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Full Disk Access") {
                actions.openFullDiskAccessSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct MetricStrip: View {
    let snapshot: ScanSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricRow
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(displayedAllocatedSize))
                    WorkspaceMetricView(title: "Files", value: "\(displayedFileCount)")
                }

                GridRow {
                    WorkspaceMetricView(title: "Folders", value: "\(displayedDirectoryCount)")
                    WorkspaceMetricView(title: "Warnings", value: "\(warningCount)")
                }
            }
        }
    }

    private var metricRow: some View {
        Group {
            WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(displayedAllocatedSize))
            WorkspaceMetricView(title: "Files", value: "\(displayedFileCount)")
            WorkspaceMetricView(title: "Folders", value: "\(displayedDirectoryCount)")
            WorkspaceMetricView(title: "Warnings", value: "\(warningCount)")
        }
    }

    private var displayedFileCount: Int {
        snapshot.aggregateStats.fileCount
    }

    private var displayedDirectoryCount: Int {
        snapshot.aggregateStats.directoryCount
    }

    private var displayedAllocatedSize: Int64 {
        snapshot.aggregateStats.totalAllocatedSize
    }

    private var warningCount: Int {
        snapshot.scanWarnings.count
    }
}

private struct WarningFooter: View {
    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let actions: WorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(warnings.count) locations had limited access or scan warnings.")
                    .font(.subheadline.weight(.semibold))
                Text(warnings.first?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if shouldSuggestFullDiskAccess {
                Button("Open Full Disk Access") {
                    actions.openFullDiskAccessSettings()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct EmptyWorkspaceState: View {
    let startupDiskTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Choose a Folder or Disk")
                    .font(.title2.weight(.semibold))

                Text("Start from the sidebar, drop a folder into the window, or choose a location manually.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button("Choose Folder…") {
                    actions.chooseFolder()
                }
                .buttonStyle(.borderedProminent)

                if let startupDiskTarget {
                    Button("Scan \(startupDiskTarget.sidebarTitle)") {
                        actions.startScan(startupDiskTarget)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanningWorkspaceState: View {
    @ObservedObject var progress: ScanProgressState

    let selectedTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ProgressView(value: scanProgressFraction, total: 1)
                    .frame(width: 260)

                Text(scanProgressLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Scanning \(selectedTarget?.displayName ?? "Location")")
                .font(.title3.weight(.semibold))

            Text(progress.metrics.currentPath)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            Text("\(progress.metrics.filesVisited) files, \(progress.metrics.directoriesVisited) folders")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Stop Scan") {
                actions.stopScan()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isFinalizingScan: Bool {
        progress.metrics.isFinalizing
    }

    private var scanProgressFraction: Double {
        progress.metrics.progressFraction
    }

    private var scanProgressLabel: String {
        if isFinalizingScan {
            return "Finishing \(progress.metrics.progressPercentage.formatted(.number))%"
        }
        return progress.metrics.progressPercentage.formatted(.number) + "%"
    }
}
