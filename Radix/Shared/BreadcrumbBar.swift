import SwiftUI

struct BreadcrumbBar: View {
    let nodes: [FileNode]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { element in
                    breadcrumbButton(node: element.element, isCurrent: element.offset == nodes.count - 1)

                    if element.offset < nodes.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func breadcrumbButton(node: FileNode, isCurrent: Bool) -> some View {
        Button(node.name) {
            onSelect(node.id)
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .lineLimit(1)
        .accessibilityLabel(isCurrent ? "Current location, \(node.name)" : "Show \(node.name)")
        .accessibilityHint(isCurrent ? "Current focus in the filesystem hierarchy." : "Navigates to this location.")
    }
}
