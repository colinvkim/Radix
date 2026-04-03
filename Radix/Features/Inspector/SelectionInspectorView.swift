import SwiftUI

struct SelectionInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if let node = appModel.selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        InspectorSection {
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
                                    }
                                }
                            }
                        }

                        InspectorSection("Details") {
                            LabeledContent("Kind") {
                                Text(node.itemKind)
                            }

                            LabeledContent("Allocated") {
                                Text(RadixFormatters.size(node.allocatedSize))
                            }

                            LabeledContent("Logical") {
                                Text(RadixFormatters.size(node.logicalSize))
                            }

                            if let percent = appModel.selectedNodePercentOfParentText {
                                LabeledContent("% of Parent") {
                                    Text(percent)
                                }
                            }

                            if let percent = appModel.selectedNodePercentOfScanText {
                                LabeledContent("% of Scan") {
                                    Text(percent)
                                }
                            }

                            if let parent = appModel.selectedNodeParent {
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

                        InspectorSection("Actions") {
                            if appModel.canZoomIntoSelection {
                                Button("Zoom Into Folder") {
                                    appModel.zoomIntoSelection()
                                }
                            }

                            Button("Open") {
                                appModel.openSelected()
                            }
                            .disabled(!appModel.canOpenSelected)

                            Button("Reveal in Finder") {
                                appModel.revealSelectedInFinder()
                            }
                            .disabled(!appModel.canRevealSelected)

                            Button("Copy Path") {
                                appModel.copySelectedPath()
                            }
                            .disabled(!appModel.canCopySelectedPath)

                            Button("Move to Trash", role: .destructive) {
                                appModel.requestMoveSelectedToTrash()
                            }
                            .disabled(!appModel.canMoveSelectedToTrash)
                        }

                        if !appModel.largestSelectedChildren.isEmpty {
                            InspectorSection("Largest Children") {
                                ForEach(appModel.largestSelectedChildren) { child in
                                    Button {
                                        appModel.select(nodeID: child.id)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: child.systemImageName)
                                                .foregroundStyle(child.isDirectory ? Color.accentColor : Color.secondary)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(child.name)
                                                    .lineLimit(1)
                                                Text(child.itemKind)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Text(RadixFormatters.size(child.allocatedSize))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !appModel.scanWarningsPreview.isEmpty {
                            InspectorSection("Warnings") {
                                ForEach(appModel.scanWarningsPreview) { warning in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(warning.path, systemImage: warning.category.symbolName)
                                            .font(.caption)
                                        Text(warning.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if appModel.shouldSuggestFullDiskAccess {
                                    Button("Open Full Disk Access Settings") {
                                        appModel.prepareAndOpenFullDiskAccessSettings()
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                NoSelectionInspectorState(scanWarningsPreview: appModel.scanWarningsPreview, shouldSuggestFullDiskAccess: appModel.shouldSuggestFullDiskAccess) {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NoSelectionInspectorState: View {
    let scanWarningsPreview: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))

            VStack {
                Spacer()

                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a chart segment or table row to inspect metadata and available actions.")
                )
                .frame(maxWidth: .infinity)

                Spacer()
            }
            .padding(24)

            if !scanWarningsPreview.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorSection("Warnings") {
                        ForEach(scanWarningsPreview) { warning in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(warning.path, systemImage: warning.category.symbolName)
                                    .font(.caption.weight(.semibold))
                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if shouldSuggestFullDiskAccess {
                            Button("Open Full Disk Access Settings") {
                                openFullDiskAccessSettings()
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorSection<Content: View>: View {
    private let title: String?
    @ViewBuilder private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Group {
            if let title {
                GroupBox {
                    sectionContent
                } label: {
                    Text(title)
                }
            } else {
                GroupBox {
                    sectionContent
                }
            }
        }
        .controlSize(.small)
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
