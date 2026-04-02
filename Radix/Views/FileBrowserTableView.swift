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

    @State private var sortOrder = [KeyPathComparator(\FileNode.allocatedSize, order: .reverse)]

    private var sortedNodes: [FileNode] {
        nodes.sorted(using: sortOrder)
    }

    var body: some View {
        if nodes.isEmpty {
            ContentUnavailableView(
                "Nothing to Show Here",
                systemImage: "folder",
                description: Text("Scan a folder or zoom into a directory with children to populate the detail list.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedNodes, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { node in
                    nameCell(for: node)
                }
                .width(min: 220)

                TableColumn("Allocated", value: \.allocatedSize) { node in
                    Text(RadixFormatters.size(node.allocatedSize))
                }
                .width(min: 110, ideal: 120)

                TableColumn("Type", value: \.itemKind) { node in
                    Text(node.itemKind)
                }
                .width(min: 100, ideal: 120)

                TableColumn("Files") { node in
                    if node.isDirectory {
                        Text("\(node.descendantFileCount)")
                    } else if node.isSynthetic || node.isSymbolicLink {
                        Text("—")
                    } else {
                        Text("1")
                    }
                }
                .width(min: 70, ideal: 80)

                TableColumn("Modified") { node in
                    Text(RadixFormatters.date(node.lastModified))
                }
                .width(min: 160, ideal: 180)
            }
            .contextMenu(forSelectionType: FileNode.ID.self) { selectedIDs in
                if let selectedID = selectedIDs.first {
                    let selectedNode = sortedNodes.first(where: { $0.id == selectedID })

                    Button("Reveal in Finder") {
                        appModel.select(nodeID: selectedID)
                        appModel.revealSelectedInFinder()
                    }
                    .disabled(selectedNode?.supportsFileActions == false)
                    Button("Open") {
                        appModel.select(nodeID: selectedID)
                        appModel.openSelected()
                    }
                    .disabled(selectedNode?.supportsFileActions == false)
                    Button("Zoom In") {
                        appModel.select(nodeID: selectedID)
                        appModel.zoomIntoSelection()
                    }
                    .disabled(selectedNode?.isDirectory != true)
                    Divider()
                    Button("Copy Path") {
                        appModel.select(nodeID: selectedID)
                        appModel.copySelectedPath()
                    }
                    .disabled(selectedNode?.supportsFileActions == false)
                }
            } primaryAction: { selectedIDs in
                if let selectedID = selectedIDs.first {
                    appModel.select(nodeID: selectedID)
                }
            }
        }
    }

    private func symbolName(for node: FileNode) -> String {
        if node.isSynthetic {
            return "internaldrive.fill"
        }
        if node.isSymbolicLink {
            return "arrowshape.turn.up.right.circle.fill"
        }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    @ViewBuilder
    private func nameCell(for node: FileNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName(for: node))
                .foregroundStyle(iconColor(for: node))

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)

                if let statusText = statusText(for: node) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor(for: node))
                }
            }
        }
    }

    private func statusText(for node: FileNode) -> String? {
        guard !node.isAccessible else { return nil }
        return node.isSynthetic ? "Estimated from volume usage" : "Limited access"
    }

    private func iconColor(for node: FileNode) -> Color {
        node.isDirectory || node.isSynthetic ? .accentColor : .secondary
    }

    private func statusColor(for node: FileNode) -> Color {
        node.isSynthetic ? .secondary : .orange
    }
}
