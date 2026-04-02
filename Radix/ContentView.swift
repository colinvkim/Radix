//
//  ContentView.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } content: {
            mainWorkspace
        } detail: {
            InspectorSidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        }
        .navigationSplitViewStyle(.balanced)
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
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.lastErrorMessage ?? "Unknown error")
        }
    }

    private var sidebar: some View {
        List {
            Section("Quick Scans") {
                ForEach(SystemIntegration.defaultTargets()) { target in
                    Button {
                        appModel.startScan(target)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: target.kind == .volume ? "externaldrive.fill" : "folder.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.displayName)
                                Text(target.kind == .volume ? "Mounted volume" : "Folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Recent") {
                ForEach(appModel.recentTargets) { target in
                    Button {
                        appModel.startScan(target)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.displayName)
                            Text(target.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                appModel.presentOpenPanelAndScan()
            } label: {
                Label("Choose Folder to Scan", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var mainWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if appModel.shouldSuggestFullDiskAccess {
                    fullDiskAccessBanner
                }

                if let snapshot = appModel.snapshot,
                   let focusNode = appModel.currentFocusNode {
                    workspace(for: snapshot, focusNode: focusNode)
                } else {
                    emptyState
                        .frame(minHeight: 520)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            appModel.handleDroppedURLs(urls)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    headerTitleBlock
                    Spacer(minLength: 20)
                    headerActions
                }

                VStack(alignment: .leading, spacing: 14) {
                    headerTitleBlock
                    headerActions
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                statusMetric(
                    title: "Mode",
                    value: appModel.isFinalizingScan ? "Finishing" : (appModel.isScanning ? "Scanning" : (appModel.snapshot?.isComplete == true ? "Complete" : "Ready")),
                    systemImage: "waveform.path.ecg"
                )
                statusMetric(title: "Progress", value: appModel.scanProgressLabel, systemImage: "gauge.with.dots.needle.33percent")
                statusMetric(title: "Files", value: "\(appModel.scanMetrics.filesVisited)", systemImage: "doc.on.doc")
                statusMetric(title: "Folders", value: "\(appModel.scanMetrics.directoriesVisited)", systemImage: "folder")
                statusMetric(title: "Discovered", value: RadixFormatters.size(appModel.scanMetrics.bytesDiscovered), systemImage: "internaldrive")
            }

            if appModel.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    if appModel.isFinalizingScan {
                        ProgressView("Finishing scan…")
                            .controlSize(.small)
                    } else {
                        ProgressView(value: appModel.scanProgressFraction, total: 1) {
                            Text("Scanning \(appModel.scanProgressLabel)")
                        } currentValueLabel: {
                            Text(appModel.scanProgressLabel)
                                .monospacedDigit()
                        }
                        .controlSize(.small)
                    }
                    Text(appModel.scanMetrics.currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var headerTitleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appModel.statusTitle)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let snapshot = appModel.snapshot {
                Text(snapshot.target.url.path)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else {
                Text("Choose a folder, drag in a disk, or start from the quick-scan sidebar.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button("Scan Folder…") {
                appModel.presentOpenPanelAndScan()
            }
            .buttonStyle(.borderedProminent)

            Button("Rescan") {
                appModel.rescan()
            }
            .buttonStyle(.bordered)
            .disabled(appModel.selectedTarget == nil)

            Button("Inspector") {
                toggleInspector()
            }
            .buttonStyle(.bordered)

            Button("Stop") {
                appModel.stopScan()
            }
            .buttonStyle(.bordered)
            .disabled(!appModel.isScanning)
        }
    }

    private func workspace(for snapshot: ScanSnapshot, focusNode: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            breadcrumbBar

            sectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sunburst")
                                .font(.headline.weight(.semibold))
                            Text("Double-click a directory to zoom in. Select any segment to inspect it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let node = appModel.selectedNode {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(node.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(RadixFormatters.size(node.allocatedSize))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 220, alignment: .trailing)
                        }
                    }

                    SunburstChartView(
                        rootNode: focusNode,
                        index: appModel.fileTreeIndex,
                        selectedNodeID: appModel.selectedNodeID,
                        depthLimit: appModel.maxRenderedDepth,
                        onSelect: { appModel.select(nodeID: $0) },
                        onZoom: { appModel.focus(nodeID: $0) }
                    )
                    .frame(height: 520)
                }
            }

            sectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Contents of \(focusNode.name)")
                                .font(.headline.weight(.semibold))
                            Text("Sort by size, inspect metadata, or jump deeper from the selected row.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(snapshot.scanWarnings.count) warning\(snapshot.scanWarnings.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    FileBrowserTableView(
                        nodes: appModel.tableNodes,
                        selection: $appModel.selectedNodeID
                    )
                    .frame(minHeight: 280)
                }
            }
        }
    }

    private var breadcrumbBar: some View {
        BreadcrumbBar(
            nodes: appModel.breadcrumbNodes,
            onSelect: { appModel.focus(nodeID: $0) },
            onZoomOut: { appModel.zoomOut() }
        )
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Some folders were protected by macOS privacy controls.")
                    .font(.headline.weight(.semibold))
                Text("Grant Full Disk Access for more complete scans of Mail, Safari, Messages, and other protected locations.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                appModel.prepareAndOpenFullDiskAccessSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("Start a Scan")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Choose a folder from the sidebar, use the toolbar button, or drag a folder or mounted disk into the window.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button("Choose Folder") {
                    appModel.presentOpenPanelAndScan()
                }
                .buttonStyle(.borderedProminent)

                Button("Show Inspector") {
                    splitViewVisibility = .all
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func statusMetric(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func toggleInspector() {
        splitViewVisibility = splitViewVisibility == .all ? .doubleColumn : .all
    }
}

private struct BreadcrumbBar: View {
    let nodes: [FileNode]
    let onSelect: (String) -> Void
    let onZoomOut: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { element in
                    breadcrumbButton(index: element.offset, node: element.element)
                }

                if nodes.count > 1 {
                    Button("Zoom Out", action: onZoomOut)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func breadcrumbButton(index: Int, node: FileNode) -> some View {
        let isLast = index == nodes.count - 1

        if isLast {
            Button(node.name) {
                onSelect(node.id)
            }
            .buttonStyle(BorderedProminentButtonStyle())
        } else {
            Button(node.name) {
                onSelect(node.id)
            }
            .buttonStyle(BorderedButtonStyle())
        }

        if !isLast {
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
    }
}
