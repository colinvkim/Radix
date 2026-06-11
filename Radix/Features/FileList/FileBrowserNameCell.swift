import SwiftUI

struct FileBrowserNameCell: View {
    let node: FileNodeRecord
    let subtitleOverride: String?
    let isExpanding: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory || node.isSynthetic ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)

                if let statusText = subtitleOverride ?? node.secondaryStatusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(searchSubtitleColor)
                        .lineLimit(1)
                }
            }

            if node.isAutoSummarized {
                ExpandSummarizedButton(node: node, isExpanding: isExpanding)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var searchSubtitleColor: Color {
        if subtitleOverride != nil {
            return .secondary
        }
        return node.isSynthetic ? .secondary : .orange
    }
}

/// Button that appears next to auto-summarized directories, allowing users to expand them fully.
private struct ExpandSummarizedButton: View {
    let node: FileNodeRecord
    let isExpanding: Bool
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Button(action: expandFolder) {
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

    private func expandFolder() {
        appModel.expandSummarizedNode(node) {}
    }
}
