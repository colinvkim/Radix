import SwiftUI

struct BreadcrumbBar: View {
    let items: [BreadcrumbItem]
    let onSelect: (BreadcrumbItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onSelect(item)
                    } label: {
                        Text(item.title)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                if item.isCurrent {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.18))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(item.isCurrent ? .semibold : .regular))
                    .foregroundStyle(item.isCurrent ? Color.primary : Color.secondary)
                    .accessibilityLabel(item.isCurrent ? "Current location, \(item.title)" : "Open \(item.title)")
                    .accessibilityHint(item.isCurrent ? "Current focus in the filesystem hierarchy." : "Navigates to this location.")
                    .interactivePointer()

                    if index < items.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
