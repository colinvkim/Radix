import SwiftUI

struct InspectorLargestChildrenSection: View {
    let children: [FileNodeRecord]
    let selectChild: (FileNodeRecord) -> Void

    var body: some View {
        Section("Largest Children") {
            ForEach(children) { child in
                Button {
                    selectChild(child)
                } label: {
                    LargestChildRow(node: child)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LargestChildRow: View {
    let node: FileNodeRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                Text(node.itemKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(RadixFormatters.size(node.allocatedSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
