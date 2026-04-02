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
                    HStack(spacing: 10) {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                            if !node.isAccessible {
                                Text("Limited access")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
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
                    Text(node.isDirectory ? "\(node.descendantFileCount)" : "1")
                }
                .width(min: 70, ideal: 80)

                TableColumn("Modified") { node in
                    Text(RadixFormatters.date(node.lastModified))
                }
                .width(min: 160, ideal: 180)
            }
            .contextMenu(forSelectionType: FileNode.ID.self) { selectedIDs in
                if let selectedID = selectedIDs.first {
                    Button("Reveal in Finder") {
                        appModel.select(nodeID: selectedID)
                        appModel.revealSelectedInFinder()
                    }
                    Button("Open") {
                        appModel.select(nodeID: selectedID)
                        appModel.openSelected()
                    }
                    Button("Zoom In") {
                        appModel.select(nodeID: selectedID)
                        appModel.zoomIntoSelection()
                    }
                    Divider()
                    Button("Copy Path") {
                        appModel.select(nodeID: selectedID)
                        appModel.copySelectedPath()
                    }
                }
            } primaryAction: { selectedIDs in
                if let selectedID = selectedIDs.first {
                    appModel.select(nodeID: selectedID)
                }
            }
        }
    }
}
