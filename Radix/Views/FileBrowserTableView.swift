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
        if nodes.isEmpty {
            ContentUnavailableView(
                "Nothing to Show Here",
                systemImage: "folder",
                description: Text("Scan a folder or zoom into a directory with children to populate the detail list.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredNodes.isEmpty {
            VStack(spacing: 14) {
                filterBar
                ContentUnavailableView(
                    "No Matching Items",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different filter or clear the current search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                filterBar

                Table(filteredNodes, selection: $selection, sortOrder: $sortOrder) {
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
                        let selectedNode = filteredNodes.first(where: { $0.id == selectedID })

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

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter current folder", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("\(filteredNodes.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !searchText.isEmpty {
                Button("Clear") {
                    searchText = ""
                }
                .buttonStyle(.borderless)
            }
        }
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
        if node.isSynthetic {
            return "Estimated from volume usage"
        }
        guard !node.isAccessible else { return nil }
        return "Limited access"
    }

    private func iconColor(for node: FileNode) -> Color {
        node.isDirectory || node.isSynthetic ? .accentColor : .secondary
    }

    private func statusColor(for node: FileNode) -> Color {
        node.isSynthetic ? .secondary : .orange
    }
}
