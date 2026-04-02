//
//  FileBrowserTableView.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

struct FileBrowserTableView: View {
    @EnvironmentObject private var appModel: AppModel

    let nodes: [FileNode]
    @Binding var selection: String?

    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\FileNode.allocatedSize, order: .reverse)]

    private var sortedNodes: [FileNode] {
        nodes.sorted(using: sortOrder)
    }

    private var filteredNodes: [FileNode] {
        guard !searchText.isEmpty else { return sortedNodes }
        return sortedNodes.filter { node in
            node.name.localizedCaseInsensitiveContains(searchText) ||
                node.url.path.localizedCaseInsensitiveContains(searchText) ||
                node.itemKind.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if nodes.isEmpty {
                ContentUnavailableView(
                    "Nothing to Show",
                    systemImage: "folder",
                    description: Text("Zoom into a directory with contents to populate this table.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredNodes.isEmpty {
                ContentUnavailableView(
                    "No Matching Items",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different filter or clear the current search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredNodes, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { node in
                        nameCell(for: node)
                    }
                    .width(min: 260, ideal: 360)

                    TableColumn("Allocated", value: \.allocatedSize) { node in
                        Text(RadixFormatters.size(node.allocatedSize))
                            .monospacedDigit()
                    }
                    .width(min: 110, ideal: 120)

                    TableColumn("Kind", value: \.itemKind) { node in
                        Text(node.itemKind)
                    }
                    .width(min: 110, ideal: 130)

                    TableColumn("Files") { node in
                        Text(descendantCountText(for: node))
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Modified") { node in
                        Text(RadixFormatters.date(node.lastModified))
                    }
                    .width(min: 150, ideal: 180)
                }
                .contextMenu(forSelectionType: FileNode.ID.self) { selectedIDs in
                    if let selectedID = selectedIDs.first,
                       let selectedNode = filteredNodes.first(where: { $0.id == selectedID }) {
                        Button("Reveal in Finder") {
                            appModel.select(nodeID: selectedID)
                            appModel.revealSelectedInFinder()
                        }
                        .disabled(!selectedNode.supportsFileActions)

                        Button("Open") {
                            appModel.select(nodeID: selectedID)
                            appModel.openSelected()
                        }
                        .disabled(!selectedNode.supportsFileActions)

                        Button("Zoom In") {
                            appModel.select(nodeID: selectedID)
                            appModel.zoomIntoSelection()
                        }
                        .disabled(!selectedNode.isDirectory)

                        Divider()

                        Button("Copy Path") {
                            appModel.select(nodeID: selectedID)
                            appModel.copySelectedPath()
                        }
                        .disabled(!selectedNode.supportsFileActions)
                    }
                } primaryAction: { selectedIDs in
                    guard let selectedID = selectedIDs.first,
                          let selectedNode = filteredNodes.first(where: { $0.id == selectedID }) else {
                        return
                    }

                    appModel.select(nodeID: selectedID)

                    if selectedNode.isDirectory {
                        appModel.zoomIntoSelection()
                    } else if selectedNode.supportsFileActions {
                        appModel.openSelected()
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter current folder")
    }

    @ViewBuilder
    private func nameCell(for node: FileNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName(for: node))
                .foregroundStyle(iconColor(for: node))

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)

                if let statusText = statusText(for: node) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor(for: node))
                }
            }
        }
    }

    private func descendantCountText(for node: FileNode) -> String {
        if node.isDirectory {
            return "\(node.descendantFileCount)"
        }
        if node.isSynthetic || node.isSymbolicLink {
            return "—"
        }
        return "1"
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

    private func statusText(for node: FileNode) -> String? {
        if node.isSynthetic {
            return "Estimated from volume usage"
        }
        if !node.isAccessible {
            return "Limited access"
        }
        return nil
    }

    private func iconColor(for node: FileNode) -> Color {
        node.isDirectory || node.isSynthetic ? .accentColor : .secondary
    }

    private func statusColor(for node: FileNode) -> Color {
        node.isSynthetic ? .secondary : .orange
    }
}
