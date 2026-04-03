import SwiftUI

struct SelectionInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            if let node = appModel.selectedNode {
                Section {
                    InspectorHeader(node: node)
                }

                Section("Key Stats") {
                    LabeledContent("Size") {
                        Text(RadixFormatters.size(node.allocatedSize))
                            .font(.title3.weight(.semibold))
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
                }

                Section("Metadata") {
                    LabeledContent("Kind") {
                        Text(node.itemKind)
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

                Section("Actions") {
                    Button {
                        appModel.revealSelectedInFinder()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appModel.canRevealSelected)

                    Button {
                        appModel.openSelected()
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appModel.canOpenSelected)

                    if appModel.canZoomIntoSelection {
                        Button {
                            appModel.zoomIntoSelection()
                        } label: {
                            Label("Zoom Into Folder", systemImage: "arrow.down.right.and.arrow.up.left")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        appModel.copySelectedPath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appModel.canCopySelectedPath)

                    Button(role: .destructive) {
                        appModel.requestMoveSelectedToTrash()
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appModel.canMoveSelectedToTrash)
                }

                if !appModel.largestSelectedChildren.isEmpty {
                    Section("Largest Children") {
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
                Section {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.trailing",
                        description: Text("Select a chart segment or table row to inspect metadata and file actions.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            if !appModel.scanWarningsPreview.isEmpty {
                Section("Warnings") {
                    ForEach(appModel.scanWarningsPreview) { warning in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(warning.path, systemImage: warning.category.symbolName)
                                .font(.caption.weight(.semibold))

                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
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
        .formStyle(.grouped)
        .controlSize(.small)
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
        .padding(.vertical, 4)
    }
}
