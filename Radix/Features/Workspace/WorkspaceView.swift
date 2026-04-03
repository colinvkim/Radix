import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if let snapshot = appModel.snapshot,
               let focusNode = appModel.currentFocusNode {
                ActiveWorkspaceView(snapshot: snapshot, focusNode: focusNode)
            } else if appModel.isScanning {
                ScanningWorkspaceState()
            } else {
                EmptyWorkspaceState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appModel.presentOpenPanelAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!appModel.canChooseFolder)
            }

            ToolbarItem(placement: .primaryAction) {
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
        .dropDestination(for: URL.self) { urls, _ in
            appModel.handleDroppedURLs(urls)
        }
    }
}

private struct ActiveWorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel

    let snapshot: ScanSnapshot
    let focusNode: FileNode

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(snapshot: snapshot, focusNode: focusNode)

            Divider()

            if appModel.shouldSuggestFullDiskAccess {
                PermissionBanner()
                Divider()
            }

            visualizationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            contentsPane
                .frame(height: 220)
        }
    }

    private var visualizationPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Disk Map",
                subtitle: "Hover to inspect. Double-click a folder to drill down."
            )

            Divider()

            ZStack(alignment: .bottomLeading) {
                chartContent

                VStack {
                    Spacer()

                    HStack(alignment: .bottom, spacing: 16) {
                        SelectionAccessoryBar(focusNode: focusNode)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartContent: some View {
        SunburstChartView(
            rootNode: focusNode,
            index: appModel.fileTreeIndex,
            selectedNodeID: appModel.selectedNodeID,
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
                nodes: appModel.tableNodes,
                selection: $appModel.selectedNodeID
            )

            if !snapshot.scanWarnings.isEmpty {
                Divider()
                WarningFooter(warnings: snapshot.scanWarnings)
            }
        }
    }
}

private struct WorkspaceHeaderView: View {
    @EnvironmentObject private var appModel: AppModel

    let snapshot: ScanSnapshot
    let focusNode: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(focusNode.name)
                        .font(.title2.weight(.semibold))

                    Text(appModel.statusSubtitle)
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
                        nodes: appModel.breadcrumbNodes,
                        canReset: !appModel.isFocusedAtRoot,
                        onSelect: { appModel.focus(nodeID: $0) },
                        onReset: { appModel.resetFocusToRoot() }
                    )

                    Spacer(minLength: 12)

                    MetricStrip(focusNode: focusNode)
                }

                VStack(alignment: .leading, spacing: 10) {
                    BreadcrumbBar(
                        nodes: appModel.breadcrumbNodes,
                        canReset: !appModel.isFocusedAtRoot,
                        onSelect: { appModel.focus(nodeID: $0) },
                        onReset: { appModel.resetFocusToRoot() }
                    )

                    MetricStrip(focusNode: focusNode)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

private struct SelectionAccessoryBar: View {
    @EnvironmentObject private var appModel: AppModel

    let focusNode: FileNode

    private var inspectedNode: FileNode {
        appModel.selectedNode ?? focusNode
    }

    private var title: String {
        appModel.selectedNode == nil ? "Current Focus" : "Selection"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(inspectedNode.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Divider()
                .frame(height: 24)

            WorkspaceMetricView(title: "Allocated", value: RadixFormatters.size(inspectedNode.allocatedSize))
            WorkspaceMetricView(title: "Kind", value: inspectedNode.itemKind)

            if appModel.selectedNode != nil, let percentOfScan = appModel.selectedNodePercentOfScanText {
                WorkspaceMetricView(title: "% of Scan", value: percentOfScan)
            }

            Spacer(minLength: 0)

            Text(appModel.selectedNode == nil ? "Select a segment to inspect it." : "Double-click a folder to zoom in.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MetricStrip: View {
    let focusNode: FileNode

    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricRow
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(appModel.displayedAllocatedSize))
                    WorkspaceMetricView(title: "Files", value: "\(appModel.displayedFileCount)")
                    WorkspaceMetricView(title: "Folders", value: "\(appModel.displayedDirectoryCount)")
                }

                GridRow {
                    WorkspaceMetricView(title: "Focus", value: focusNode.name)
                    WorkspaceMetricView(title: "Warnings", value: "\(appModel.warningCount)")
                    Color.clear
                }
            }
        }
    }

    private var metricRow: some View {
        Group {
            WorkspaceMetricView(title: "Scanned", value: RadixFormatters.size(appModel.displayedAllocatedSize))
            WorkspaceMetricView(title: "Files", value: "\(appModel.displayedFileCount)")
            WorkspaceMetricView(title: "Folders", value: "\(appModel.displayedDirectoryCount)")
            WorkspaceMetricView(title: "Focus", value: focusNode.name)
            WorkspaceMetricView(title: "Warnings", value: "\(appModel.warningCount)")
        }
    }
}

private struct WarningFooter: View {
    @EnvironmentObject private var appModel: AppModel

    let warnings: [ScanWarning]

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

            if appModel.shouldSuggestFullDiskAccess {
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

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ProgressView(value: appModel.scanProgressFraction, total: 1)
                    .frame(width: 260)

                Text(appModel.scanProgressLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Scanning \(appModel.selectedTarget?.displayName ?? "Location")")
                .font(.title3.weight(.semibold))

            Text(appModel.scanMetrics.currentPath)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            Text("\(appModel.displayedFileCount) files, \(appModel.displayedDirectoryCount) folders")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Stop Scan") {
                appModel.stopScan()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
