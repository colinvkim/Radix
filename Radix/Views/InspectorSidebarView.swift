//
//  InspectorSidebarView.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

struct InspectorSidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node = appModel.selectedNode {
                    header(for: node)

                    GroupBox("Selection") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Allocated") {
                                Text(RadixFormatters.size(node.allocatedSize))
                            }
                            LabeledContent("Logical") {
                                Text(RadixFormatters.size(node.logicalSize))
                            }
                            LabeledContent("Kind") {
                                Text(node.itemKind)
                            }
                            LabeledContent("Modified") {
                                Text(RadixFormatters.date(node.lastModified))
                            }
                            LabeledContent("Access") {
                                Text(accessibilityValue(for: node))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Actions") {
                        VStack(alignment: .leading, spacing: 10) {
                            if appModel.canZoomIntoSelection {
                                Button("Zoom In") {
                                    appModel.zoomIntoSelection()
                                }
                            }

                            Button("Reveal in Finder") {
                                appModel.revealSelectedInFinder()
                            }
                            .disabled(!node.supportsFileActions)

                            Button("Open") {
                                appModel.openSelected()
                            }
                            .disabled(!node.supportsFileActions)

                            Button("Copy Path") {
                                appModel.copySelectedPath()
                            }
                            .disabled(!node.supportsFileActions)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if node.isDirectory, !node.children.isEmpty {
                        GroupBox("Largest Children") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(node.children.prefix(6))) { child in
                                    Button {
                                        appModel.select(nodeID: child.id)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(child.name)
                                                    .lineLimit(1)
                                                Text(child.itemKind)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Text(RadixFormatters.size(child.allocatedSize))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Select a segment or a table row to inspect metadata and available actions.")
                    )
                }

                if let snapshot = appModel.snapshot {
                    GroupBox("Scan Summary") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Files") {
                                Text("\(snapshot.aggregateStats.fileCount)")
                            }
                            LabeledContent("Folders") {
                                Text("\(snapshot.aggregateStats.directoryCount)")
                            }
                            LabeledContent("Warnings") {
                                Text("\(snapshot.scanWarnings.count)")
                            }
                            LabeledContent("Duration") {
                                Text(
                                    RadixFormatters.scanElapsed(
                                        startedAt: snapshot.startedAt,
                                        finishedAt: snapshot.finishedAt
                                    )
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let snapshot = appModel.snapshot, !snapshot.scanWarnings.isEmpty {
                    GroupBox("Recent Warnings") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(snapshot.scanWarnings.prefix(5)) { warning in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(warning.path)
                                        .font(.caption.weight(.semibold))
                                    Text(warning.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(for node: FileNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName(for: node))
                .font(.title2)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 34, height: 34)

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

    private func accessibilityValue(for node: FileNode) -> String {
        if node.isSynthetic {
            return "Estimated"
        }
        return node.isAccessible ? "Yes" : "Limited"
    }

    private func symbolName(for node: FileNode) -> String {
        if node.isSynthetic {
            return "internaldrive.fill"
        }
        if node.isSymbolicLink {
            return "arrowshape.turn.up.right.circle.fill"
        }
        if node.isPackage {
            return "shippingbox.fill"
        }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }
}
