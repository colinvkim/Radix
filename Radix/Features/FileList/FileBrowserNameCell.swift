import SwiftUI

struct FileBrowserNameCell: View {
    let node: FileNodeRecord
    let subtitleOverride: String?
    let isExpanding: Bool
    let expandAction: () -> Void
    @Binding var presentedSharedStorageNodeID: FileNodeRecord.ID?

    var body: some View {
        if node.sharedStorageDescription != nil {
            cellContent
                .accessibilityAction(named: "About shared APFS storage") {
                    presentedSharedStorageNodeID = node.id
                }
        } else {
            cellContent
        }
    }

    private var cellContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: fileBrowserSystemImageName)
                    .foregroundStyle(node.isDirectory || node.isSynthetic ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName)
                        .lineLimit(1)

                    if let statusText = subtitleOverride ?? node.secondaryStatusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(searchSubtitleColor)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            if let title = node.sharedStorageStatusText,
               let description = node.sharedStorageDescription {
                SharedStorageInfoButton(
                    nodeID: node.id,
                    title: title,
                    description: description,
                    presentedNodeID: $presentedSharedStorageNodeID
                )
            }

            if node.isAutoSummarized {
                ExpandSummarizedButton(
                    node: node,
                    isExpanding: isExpanding,
                    expandAction: expandAction
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var fileBrowserSystemImageName: String {
        node.cloneIdentity == nil ? node.systemImageName : "doc.on.doc"
    }

    private var searchSubtitleColor: Color {
        if subtitleOverride != nil {
            return .secondary
        }
        return node.isSynthetic ? .secondary : .orange
    }
}

private struct SharedStorageInfoButton: View {
    let nodeID: FileNodeRecord.ID
    let title: String
    let description: String
    @Binding var presentedNodeID: FileNodeRecord.ID?

    var body: some View {
        Button {
            presentedNodeID = nodeID
        } label: {
            Label("About shared APFS storage", systemImage: "info.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .help("About shared APFS storage")
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .lineLimit(nil)
            .padding(16)
            .frame(width: 310, alignment: .leading)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { presentedNodeID == nodeID },
            set: { shouldPresent in
                if shouldPresent {
                    presentedNodeID = nodeID
                } else if presentedNodeID == nodeID {
                    presentedNodeID = nil
                }
            }
        )
    }
}

/// Button that appears next to auto-summarized directories, allowing users to expand them fully.
private struct ExpandSummarizedButton: View {
    let node: FileNodeRecord
    let isExpanding: Bool
    let expandAction: () -> Void

    var body: some View {
        Button(action: expandAction) {
            Image(systemName: "arrowshape.turn.up.right.circle.fill")
                .foregroundStyle(.blue)
                .help("Expand '\(node.name)' to scan all \(node.descendantFileCount) files")
        }
        .buttonStyle(.plain)
        .disabled(isExpanding)
        .accessibilityLabel("Expand \(node.name)")
        .accessibilityHint("Scans all \(node.descendantFileCount) files in this summarized folder.")
        .overlay {
            if isExpanding {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
