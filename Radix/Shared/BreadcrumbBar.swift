import SwiftUI

struct BreadcrumbBar: View {
    let nodes: [FileNodeRecord]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { element in
                    breadcrumbButton(node: element.element, isCurrent: element.offset == nodes.count - 1)
                        .workspaceTourAnchor(.folderPath, enabled: element.offset == 0)

                    if element.offset < nodes.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func breadcrumbButton(node: FileNodeRecord, isCurrent: Bool) -> some View {
        Button(node.name) {
            onSelect(node.id)
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .lineLimit(1)
        .accessibilityLabel(isCurrent
            ? String(localized: "Current location, \(node.name)", comment: "Accessibility label for the breadcrumb button of the location currently shown.")
            : String(localized: "Show \(node.name)", comment: "Accessibility label for a breadcrumb button that navigates to an ancestor location."))
        .accessibilityHint(isCurrent
            ? String(localized: "Current focus in the filesystem hierarchy.", comment: "Accessibility hint for the breadcrumb button of the current location.")
            : String(localized: "Navigates to this location.", comment: "Accessibility hint for ancestor breadcrumb buttons."))
    }
}
