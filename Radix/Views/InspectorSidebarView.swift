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
            VStack(alignment: .leading, spacing: 18) {
                if let node = appModel.selectedNode {
                    HStack(spacing: 14) {
                        Image(systemName: symbolName(for: node))
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(2)
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

                    inspectorCard("Overview") {
                        metricRow("Allocated", value: RadixFormatters.size(node.allocatedSize))
                        metricRow("Logical", value: RadixFormatters.size(node.logicalSize))
                        metricRow("Kind", value: node.itemKind)
                        metricRow("Modified", value: RadixFormatters.date(node.lastModified))
                        metricRow("Accessible", value: accessibilityValue(for: node))
                    }

                    inspectorCard("Actions") {
                        actionButton("Reveal in Finder", systemImage: "folder") {
                            appModel.revealSelectedInFinder()
                        }
                        .disabled(!node.supportsFileActions)
                        actionButton("Open", systemImage: "arrow.up.forward.app") {
                            appModel.openSelected()
                        }
                        .disabled(!node.supportsFileActions)
                        actionButton("Copy Path", systemImage: "doc.on.doc") {
                            appModel.copySelectedPath()
                        }
                        .disabled(!node.supportsFileActions)
                    }

                    if node.isDirectory, !node.children.isEmpty {
                        inspectorCard("Largest Children") {
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
                    }
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Pick a segment or table row to inspect its size, metadata, and Finder actions.")
                    )
                }

                if let snapshot = appModel.snapshot {
                    inspectorCard("Scan Summary") {
                        metricRow("Files", value: "\(snapshot.aggregateStats.fileCount)")
                        metricRow("Folders", value: "\(snapshot.aggregateStats.directoryCount)")
                        metricRow("Warnings", value: "\(snapshot.scanWarnings.count)")
                        metricRow("Duration", value: RadixFormatters.scanElapsed(startedAt: snapshot.startedAt, finishedAt: snapshot.finishedAt))
                    }
                }

                if let snapshot = appModel.snapshot, !snapshot.scanWarnings.isEmpty {
                    inspectorCard("Warnings") {
                        ForEach(snapshot.scanWarnings.prefix(5)) { warning in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(warning.path)
                                    .font(.caption.weight(.semibold))
                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func inspectorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func accessibilityValue(for node: FileNode) -> String {
        if node.isSynthetic {
            return "Estimated"
        }
        return node.isAccessible ? "Yes" : "Limited"
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
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
