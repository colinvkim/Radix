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
    @State private var selectedSidebarTargetID: String?
    @State private var showsInspector = true

    private var defaultTargets: [ScanTarget] {
        SystemIntegration.defaultTargets()
    }

    private var startupDiskTarget: ScanTarget? {
        defaultTargets.first(where: { $0.kind == .volume })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showsInspector) {
            InspectorSidebarView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appModel.presentOpenPanelAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    appModel.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.selectedTarget == nil)

                if appModel.isScanning {
                    Button {
                        appModel.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label(
                        showsInspector ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.right"
                    )
                }
            }
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
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.lastErrorMessage ?? "Unknown error")
        }
        .onAppear {
            selectedSidebarTargetID = appModel.selectedTarget?.id
        }
        .onChange(of: appModel.selectedTarget?.id) { _, newValue in
            selectedSidebarTargetID = newValue
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSidebarTargetID) {
            Section("Locations") {
                ForEach(defaultTargets) { target in
                    SidebarTargetRow(target: target)
                        .tag(target.id)
                }
            }

            if !appModel.recentTargets.isEmpty {
                Section("Recent") {
                    ForEach(appModel.recentTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                }
            }

            Section("Actions") {
                Button {
                    appModel.presentOpenPanelAndScan()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }

                Button {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                } label: {
                    Label("Open Full Disk Access Settings", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("Radix")
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onChange(of: selectedSidebarTargetID) { _, newValue in
            guard let targetID = newValue,
                  let target = (defaultTargets + appModel.recentTargets).first(where: { $0.id == targetID }),
                  appModel.selectedTarget?.id != targetID else {
                return
            }

            appModel.startScan(target)
        }
    }

    private var detailColumn: some View {
        Group {
            if let snapshot = appModel.snapshot,
               let focusNode = appModel.currentFocusNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection(snapshot: snapshot, focusNode: focusNode)

                        if appModel.shouldSuggestFullDiskAccess {
                            privacyBanner
                        }

                        GroupBox {
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
                        .groupBoxStyle(.automatic)

                        GroupBox("Contents of \(focusNode.name)") {
                            FileBrowserTableView(
                                nodes: appModel.tableNodes,
                                selection: $appModel.selectedNodeID
                            )
                            .frame(minHeight: 320)
                        }

                        if !snapshot.scanWarnings.isEmpty {
                            warningsSection(snapshot.scanWarnings)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            appModel.handleDroppedURLs(urls)
        }
    }

    private func headerSection(snapshot: ScanSnapshot, focusNode: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appModel.statusTitle)
                .font(.largeTitle.weight(.bold))

            Text(snapshot.target.url.path)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            if appModel.isScanning {
                ProgressView(value: appModel.scanProgressFraction, total: 1) {
                    Text("Scanning")
                } currentValueLabel: {
                    Text(appModel.scanProgressLabel)
                        .monospacedDigit()
                }

                Text(appModel.scanMetrics.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            GroupBox("Scan Summary") {
                summaryGrid(focusNode: focusNode)
            }

            BreadcrumbStrip(
                nodes: appModel.breadcrumbNodes,
                onSelect: { appModel.focus(nodeID: $0) },
                onReset: {
                    if appModel.isFocusedAtRoot {
                        appModel.select(nodeID: snapshot.root.id)
                    } else {
                        appModel.resetFocusToRoot()
                    }
                },
                canReset: snapshot.root.id != focusNode.id
            )
        }
    }

    private var privacyBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Some protected folders were skipped.")
                    .font(.headline)

                Text("Grant Full Disk Access for more complete scans of Mail, Safari, Messages, and Library content.")
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Radix remains read-only. This only improves what the scan can see.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        appModel.prepareAndOpenFullDiskAccessSettings()
                    }
                }
            }
        }
    }

    private func warningsSection(_ warnings: [ScanWarning]) -> some View {
        GroupBox("Warnings") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(warnings.prefix(8)) { warning in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.path)
                            .font(.subheadline.weight(.semibold))
                        Text(warning.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if warning.id != warnings.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 10) {
                Text("Choose a Folder or Disk")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Start a scan from the sidebar, drop a folder into the window, or open a location manually.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 12) {
                Button("Choose Folder") {
                    appModel.presentOpenPanelAndScan()
                }
                .buttonStyle(.borderedProminent)

                if let startupDiskTarget {
                    Button("Scan \(startupDiskTarget.displayName)") {
                        appModel.startScan(startupDiskTarget)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(40)
    }

    private func summaryGrid(focusNode: FileNode) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                LabeledContent("Allocated") {
                    Text(RadixFormatters.size(appModel.displayedAllocatedSize))
                }
                LabeledContent("Files") {
                    Text("\(appModel.displayedFileCount)")
                }
            }

            GridRow {
                LabeledContent("Folders") {
                    Text("\(appModel.displayedDirectoryCount)")
                }
                LabeledContent("Focused On") {
                    Text(focusNode.name)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarTargetRow: View {
    let target: ScanTarget

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                Text(target.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: target.kind == .volume ? "internaldrive.fill" : "folder.fill")
                .foregroundStyle(target.kind == .volume ? Color.accentColor : Color.secondary)
        }
        .help(target.url.path)
    }
}

private struct BreadcrumbStrip: View {
    let nodes: [FileNode]
    let onSelect: (String) -> Void
    let onReset: () -> Void
    let canReset: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { element in
                    breadcrumbButton(index: element.offset, node: element.element)
                }

                if canReset {
                    Button("Back to Root", action: onReset)
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
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
        } else {
            Button(node.name) {
                onSelect(node.id)
            }
            .buttonStyle(.bordered)
            .lineLimit(1)
        }

        if !isLast {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
