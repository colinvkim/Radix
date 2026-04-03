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
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if appModel.shouldSuggestFullDiskAccess {
                PermissionBanner()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            VSplitView {
                visualizationPane
                    .frame(minHeight: 430, idealHeight: 560)

                contentsPane
                    .frame(minHeight: 210, idealHeight: 250)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private var visualizationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Disk Map")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 16)

                Text("Hover to inspect. Double-click a folder to zoom in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            BreadcrumbBar(items: appModel.breadcrumbItems) { item in
                appModel.activateBreadcrumb(item)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.36))

                SunburstChartView(
                    rootNode: focusNode,
                    index: appModel.fileTreeIndex,
                    selectedNodeID: appModel.selectedNodeID,
                    depthLimit: appModel.maxRenderedDepth,
                    layoutID: "\(snapshot.id.uuidString)|\(focusNode.id)|\(appModel.maxRenderedDepth)",
                    onSelect: { appModel.select(nodeID: $0) },
                    onZoom: { appModel.focus(nodeID: $0) }
                )
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if !appModel.showsInspector {
                    VisualizationContextPanel(focusNode: focusNode)
                        .frame(width: 300)
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !appModel.showsInspector {
                    Button {
                        appModel.toggleInspector()
                    } label: {
                        Label("Show Inspector", systemImage: "sidebar.trailing")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(14)
                }
            }
        }
    }

    private var contentsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Contents")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 8)

                Text("\(appModel.tableNodes.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FileBrowserTableView(
                nodes: appModel.tableNodes,
                selection: $appModel.selectedNodeID
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !snapshot.scanWarnings.isEmpty {
                WarningFooter(warnings: snapshot.scanWarnings)
            }
        }
    }
}

private struct VisualizationContextPanel: View {
    @EnvironmentObject private var appModel: AppModel

    let focusNode: FileNode

    private var inspectedNode: FileNode {
        appModel.selectedNode ?? focusNode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appModel.selectedNode == nil ? "Current Focus" : "Selection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(inspectedNode.name)
                .font(.headline)
                .lineLimit(2)

            Text(inspectedNode.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    WorkspaceMetricView(title: "Allocated", value: RadixFormatters.size(inspectedNode.allocatedSize))
                    WorkspaceMetricView(title: "Kind", value: inspectedNode.itemKind)
                }

                GridRow {
                    WorkspaceMetricView(title: "Modified", value: RadixFormatters.date(inspectedNode.lastModified))
                    WorkspaceMetricView(title: "Access", value: inspectedNode.accessDescription)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct WorkspaceMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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

private struct WorkspaceHeaderView: View {
    let snapshot: ScanSnapshot
    let focusNode: FileNode

    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(focusNode.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                Text(focusNode.url.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer(minLength: 20)

            if appModel.isScanning {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Scanning")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ProgressView(value: appModel.scanProgressFraction, total: 1)
                        .frame(width: 180)

                    Text(appModel.scanProgressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let finishedAt = snapshot.finishedAt {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Last Scan")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(RadixFormatters.date(finishedAt))
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Some protected folders were skipped.")
                    .font(.subheadline.weight(.semibold))

                Text("Grant Full Disk Access for a more complete scan of Mail, Safari, Messages, and Library content.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Open Settings") {
                appModel.prepareAndOpenFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct WarningFooter: View {
    @EnvironmentObject private var appModel: AppModel

    let warnings: [ScanWarning]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(warnings.count) locations were partially scanned.")
                    .font(.subheadline.weight(.semibold))

                Text(warnings.first?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if appModel.shouldSuggestFullDiskAccess {
                Button("Open Settings") {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
    }
}

private struct EmptyWorkspaceState: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Folder or Disk", systemImage: "internaldrive.fill")
        } description: {
            Text("Start from the sidebar, drop a folder into the window, or choose a location manually.")
        } actions: {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanningWorkspaceState: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Text("Scanning \(appModel.selectedTarget?.displayName ?? "Location")")
                    .font(.title2.weight(.semibold))

                Text(appModel.scanMetrics.currentPath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            ProgressView(value: appModel.scanProgressFraction, total: 1)
                .frame(width: 260)

            Text(appModel.scanProgressLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("\(appModel.displayedFileCount) files, \(appModel.displayedDirectoryCount) folders")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Stop Scan") {
                appModel.stopScan()
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
