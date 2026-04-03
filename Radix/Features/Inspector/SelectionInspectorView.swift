import SwiftUI

struct SelectionInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let node = appModel.selectedNode {
                    InspectorHeader(node: node)

                    InspectorPanelSection("Key Stats") {
                        HStack(spacing: 10) {
                            InspectorStatCard(
                                title: "Size",
                                value: RadixFormatters.size(node.allocatedSize)
                            )

                            InspectorStatCard(
                                title: "% Parent",
                                value: appModel.selectedNodePercentOfParentText ?? "—"
                            )

                            InspectorStatCard(
                                title: "% Scan",
                                value: appModel.selectedNodePercentOfScanText ?? "—"
                            )
                        }
                    }

                    InspectorPanelSection("Metadata") {
                        LabeledContent("Kind") {
                            Text(node.itemKind)
                        }

                        LabeledContent("Modified") {
                            Text(RadixFormatters.date(node.lastModified))
                        }

                        LabeledContent("Access") {
                            Text(node.accessDescription)
                        }

                        if let parent = appModel.selectedNodeParent {
                            LabeledContent("Parent") {
                                Text(parent.name)
                            }
                        }
                    }

                    InspectorPanelSection("Actions") {
                        VStack(spacing: 10) {
                            Button {
                                appModel.revealSelectedInFinder()
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!appModel.canRevealSelected)

                            HStack(spacing: 10) {
                                Button {
                                    appModel.openSelected()
                                } label: {
                                    Label("Open", systemImage: "arrow.up.forward.app")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!appModel.canOpenSelected)

                                Button {
                                    appModel.copySelectedPath()
                                } label: {
                                    Label("Copy Path", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!appModel.canCopySelectedPath)
                            }

                            if appModel.canZoomIntoSelection {
                                Button {
                                    appModel.zoomIntoSelection()
                                } label: {
                                    Label("Zoom Into Folder", systemImage: "arrow.down.right.and.arrow.up.left")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            Button(role: .destructive) {
                                appModel.requestMoveSelectedToTrash()
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!appModel.canMoveSelectedToTrash)
                        }
                        .controlSize(.large)
                    }

                    if !appModel.largestSelectedChildren.isEmpty {
                        InspectorPanelSection("Largest Children") {
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

                                        Spacer(minLength: 8)

                                        Text(RadixFormatters.size(child.allocatedSize))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    InspectorPanelSection {
                        ContentUnavailableView(
                            "No Selection",
                            systemImage: "sidebar.trailing",
                            description: Text("Select a chart segment or table row to inspect metadata and file actions.")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }

                if !appModel.scanWarningsPreview.isEmpty {
                    InspectorPanelSection("Warnings") {
                        ForEach(appModel.scanWarningsPreview) { warning in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(warning.path, systemImage: warning.category.symbolName)
                                    .font(.caption.weight(.semibold))

                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if appModel.shouldSuggestFullDiskAccess {
                            Button("Open Full Disk Access Settings") {
                                appModel.prepareAndOpenFullDiskAccessSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct InspectorHeader: View {
    let node: FileNode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.systemImageName)
                .font(.title2)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
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
}

private struct InspectorStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct InspectorPanelSection<Content: View>: View {
    private let title: String?
    @ViewBuilder private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
        }
    }
}
