import SwiftUI

struct SelectionInspectorView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    var body: some View {
        let largestChildren = largestSelectedChildren

        Group {
            if let node = navigation.selectedNode {
                Form {
                    Section {
                        InspectorHeader(node: node)
                    }

                    Section("Key Stats") {
                        InspectorKeyStats(
                            allocatedSize: RadixFormatters.size(node.allocatedSize),
                            percentOfParent: selectedNodePercentOfParentText ?? "—",
                            percentOfScan: selectedNodePercentOfScanText ?? "—"
                        )
                    }

                    Section("Metadata") {
                        LabeledContent("Kind") {
                            Text(node.itemKind)
                        }

                        LabeledContent("Logical Size") {
                            Text(RadixFormatters.size(node.logicalSize))
                        }

                        if let parent = navigation.selectedNodeParent {
                            LabeledContent("Parent") {
                                Text(parent.name)
                            }
                        }

                        LabeledContent("Modified") {
                            Text(RadixFormatters.date(node.lastModified))
                        }

                        LabeledContent("Access") {
                            Text(node.accessDescription)
                        }
                    }

                    Section("Actions") {
                        InspectorActionButtons(scanState: scanState, navigation: navigation)
                    }

                    if !largestChildren.isEmpty {
                        Section("Largest Children") {
                            ForEach(largestChildren) { child in
                                Button {
                                    appModel.select(nodeID: child.id)
                                } label: {
                                    LargestChildRow(node: child)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !scanWarningsPreview.isEmpty {
                        WarningsSection(
                            warnings: scanWarningsPreview,
                            shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                        ) {
                            appModel.prepareAndOpenFullDiskAccessSettings()
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                NoSelectionInspectorState(
                    scanWarningsPreview: scanWarningsPreview,
                    shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess
                ) {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scanWarningsPreview: [ScanWarning] {
        Array((scanState.snapshot?.scanWarnings ?? []).prefix(5))
    }

    private var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(for: scanState.snapshot)
    }

    private var largestSelectedChildren: [FileNodeRecord] {
        guard let fileTreeStore = scanState.fileTreeStore,
              let selectedNode = navigation.selectedNode,
              selectedNode.isDirectory else { return [] }
        return fileTreeStore.childrenPrefix(of: selectedNode.id, maxCount: 8)
    }

    private var selectedNodePercentOfParentText: String? {
        guard let selectedNode = navigation.selectedNode,
              let parent = navigation.selectedNodeParent else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    private var selectedNodePercentOfScanText: String? {
        guard let selectedNode = navigation.selectedNode,
              let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }
}

private struct InspectorHeader: View {
    let node: FileNodeRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.systemImageName)
                .font(.title2)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(3)

                if node.isSynthetic {
                    Text("Estimated storage that macOS reports as used but that Radix could not attribute to a regular file path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(node.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct InspectorKeyStats: View {
    let allocatedSize: String
    let percentOfParent: String
    let percentOfScan: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                InspectorStatCard(title: "Allocated", value: allocatedSize)
                InspectorStatCard(title: "% Parent", value: percentOfParent)
                InspectorStatCard(title: "% Scan", value: percentOfScan)
            }

            VStack(spacing: 8) {
                InspectorStatCard(title: "Allocated", value: allocatedSize)
                InspectorStatCard(title: "% Parent", value: percentOfParent)
                InspectorStatCard(title: "% Scan", value: percentOfScan)
            }
        }
    }
}

private struct InspectorStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct InspectorActionButtons: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                appModel.previewSelectedWithQuickLook()
            } label: {
                Label("Quick Look", systemImage: RadixSystemImages.quickLook)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canQuickLookSelected)

            Button {
                appModel.revealSelectedInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: RadixSystemImages.revealInFinder)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canRevealSelected)

            if canExpandSummarizedSelection {
                Button {
                    expandSummarizedSelection()
                } label: {
                    Label("Expand Fully", systemImage: "arrowshape.turn.up.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if navigation.canZoomIntoSelection {
                Button {
                    appModel.zoomIntoSelection()
                } label: {
                    Label("Zoom Into Folder", systemImage: "plus.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openButton
                    copyPathButton
                }

                VStack(spacing: 8) {
                    openButton
                    copyPathButton
                }
            }

            Button(role: .destructive) {
                appModel.requestMoveSelectedToTrash()
            } label: {
                Label("Move to Trash", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canMoveSelectedToTrash)
        }
        .controlSize(.regular)
    }

    private var openButton: some View {
        Button {
            appModel.openSelected()
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canOpenSelected)
    }

    private var copyPathButton: some View {
        Button {
            appModel.copySelectedPath()
        } label: {
            Label("Copy Path", systemImage: RadixSystemImages.copyPath)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canCopySelectedPath)
    }

    private var canOpenSelected: Bool {
        navigation.selectedNode?.supportsFileActions == true
    }

    private var canQuickLookSelected: Bool {
        navigation.selectedNode?.supportsFileActions == true
    }

    private var canRevealSelected: Bool {
        navigation.selectedNode?.supportsFileActions == true
    }

    private var canCopySelectedPath: Bool {
        navigation.selectedNode?.supportsFileActions == true
    }

    private var canMoveSelectedToTrash: Bool {
        navigation.selectedNode?.supportsMoveToTrash(activeTarget: scanState.selectedTarget) == true
    }

    private var canExpandSummarizedSelection: Bool {
        navigation.selectedNode?.isAutoSummarized == true
    }

    private func expandSummarizedSelection() {
        guard let node = navigation.selectedNode else { return }
        appModel.expandSummarizedNode(node) {}
    }
}

private struct LargestChildRow: View {
    let node: FileNodeRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                Text(node.itemKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(RadixFormatters.size(node.allocatedSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct WarningsSection: View {
    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        Section("Warnings") {
            ForEach(warnings) { warning in
                VStack(alignment: .leading, spacing: 4) {
                    Label(warning.path, systemImage: warning.category.symbolName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if shouldSuggestFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    openFullDiskAccessSettings()
                }
            }
        }
    }
}

private struct NoSelectionInspectorState: View {
    let scanWarningsPreview: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.trailing")
            } description: {
                Text("Select a chart segment or table row to inspect metadata and file actions.")
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)

            if !scanWarningsPreview.isEmpty {
                Divider()

                Form {
                    WarningsSection(
                        warnings: scanWarningsPreview,
                        shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess,
                        openFullDiskAccessSettings: openFullDiskAccessSettings
                    )
                }
                .formStyle(.grouped)
                .frame(maxHeight: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
