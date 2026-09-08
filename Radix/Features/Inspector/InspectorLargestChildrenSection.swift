import SwiftUI

struct InspectorLargestChildrenSection: View {
    let children: [FileNodeRecord]
    let selectChild: (FileNodeRecord) -> Void

    var body: some View {
        Section("Largest Children") {
            ForEach(children) { child in
                InspectorLargestChildButton(node: child) {
                    selectChild(child)
                }
            }
        }
    }
}

private struct InspectorLargestChildButton: View {
    let node: FileNodeRecord
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            select()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: node.systemImageName)
                    .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                Text(node.displayName)
                    .lineLimit(1)

                Spacer()

                Text(RadixFormatters.size(node.allocatedSize))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
