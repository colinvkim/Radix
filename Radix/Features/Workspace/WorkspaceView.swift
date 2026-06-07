import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    var body: some View {
        Group {
            if let snapshot = scanState.snapshot,
               let focusNode = navigation.currentFocusNode {
                ActiveWorkspaceView(
                    scanState: scanState,
                    navigation: navigation,
                    snapshot: snapshot,
                    focusNode: focusNode
                )
            } else if scanState.isScanning {
                ScanningWorkspaceState(
                    progress: scanState.progress,
                    selectedTarget: scanState.selectedTarget
                )
            } else {
                EmptyWorkspaceState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .hidingWindowToolbarBackgroundWhenAvailable()
        .toolbar {
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    appModel.presentOpenPanelAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .disabled(scanState.isScanning)

                if scanState.canStopScan {
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
                    .disabled(!scanState.canRescan)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            appModel.handleDroppedURLs(urls)
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
    @EnvironmentObject private var appModel: AppModel
    let scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(
                navigation: navigation,
                snapshot: snapshot,
                focusNode: focusNode
            )

            Divider()

            if PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot) {
                PermissionBanner()
                Divider()
            }

            visualizationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            contentsPane
                .frame(minHeight: 200, maxHeight: .infinity)
        }
    }

    private var visualizationPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Disk Map",
                subtitle: "Hover to inspect. Double-click a folder to drill down."
            )

            Divider()

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
            depthLimit: appModel.maxRenderedDepth,
            layoutID: "\(snapshot.id.uuidString)|\(focusNode.id)|\(appModel.maxRenderedDepth)",
            onSelect: { appModel.select(nodeID: $0) },
            onZoom: { appModel.focus(nodeID: $0) }
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
                    shouldSuggestFullDiskAccess: PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot)
                )
            }
        }
    }
}

private struct WorkspaceHeaderView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var navigation: WorkspaceNavigationModel

    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord

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
                        onSelect: { appModel.focus(nodeID: $0) }
                    )

                    Spacer(minLength: 12)

                    MetricStrip(snapshot: snapshot, focusNode: focusNode)
                }

                VStack(alignment: .leading, spacing: 10) {
                    BreadcrumbBar(
                        nodes: navigation.breadcrumbNodes,
                        onSelect: { appModel.focus(nodeID: $0) }
                    )

                    MetricStrip(snapshot: snapshot, focusNode: focusNode)
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
    @EnvironmentObject private var appModel: AppModel

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

            Button("Open Settings") {
                appModel.prepareAndOpenFullDiskAccessSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct MetricStrip: View {
    let snapshot: ScanSnapshot
    let focusNode: FileNodeRecord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricRow
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(displayedAllocatedSize))
                    WorkspaceMetricView(title: "Files", value: "\(displayedFileCount)")
                    WorkspaceMetricView(title: "Folders", value: "\(displayedDirectoryCount)")
                }

                GridRow {
                    WorkspaceMetricView(title: "Focus", value: focusNode.name)
                    WorkspaceMetricView(title: "Warnings", value: "\(warningCount)")
                    Color.clear
                }
            }
        }
    }

    private var metricRow: some View {
        Group {
            WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(displayedAllocatedSize))
            WorkspaceMetricView(title: "Files", value: "\(displayedFileCount)")
            WorkspaceMetricView(title: "Folders", value: "\(displayedDirectoryCount)")
            WorkspaceMetricView(title: "Focus", value: focusNode.name)
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
    @EnvironmentObject private var appModel: AppModel

    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool

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
                Button("Open Settings") {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct EmptyWorkspaceState: View {
    @EnvironmentObject private var appModel: AppModel

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
                    appModel.presentOpenPanelAndScan()
                }
                .buttonStyle(.borderedProminent)

                if let startupDiskTarget = appModel.startupDiskTarget {
                    Button("Scan \(startupDiskTarget.sidebarTitle)") {
                        appModel.startScan(startupDiskTarget)
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
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var progress: ScanProgressState

    let selectedTarget: ScanTarget?

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
                appModel.stopScan()
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
