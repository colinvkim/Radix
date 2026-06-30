import SwiftUI

struct DiscardPileReviewActions {
    let removeNode: (FileNodeRecord.ID) -> Void
    let clear: () -> Void
    let cancel: () -> Void
    let moveToTrash: () -> Void
}

struct DiscardPileReviewSheet: View {
    private let rows: [DiscardPileReviewRow]
    private let summary: DiscardPileSummary
    private let actions: DiscardPileReviewActions

    @State private var isConfirmingClear = false

    init(nodes: [FileNodeRecord], actions: DiscardPileReviewActions) {
        self.rows = nodes.map(DiscardPileReviewRow.init)
        self.summary = DiscardPileSummary(nodes: nodes)
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Discard Pile")
                    .font(.title3.weight(.semibold))

                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if rows.isEmpty {
                emptyState
            } else {
                Table(rows) {
                    TableColumn("Name") { row in
                        Label(row.name, systemImage: row.systemImageName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Path") { row in
                        Text(row.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.path)
                    }
                    .width(min: 240, ideal: 360)

                    TableColumn("Size") { row in
                        Text(row.sizeText)
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Kind") { row in
                        Text(row.itemKind)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("") { row in
                        Button {
                            actions.removeNode(row.id)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .width(36)
                }
            }

            Divider()

            HStack {
                Button("Clear All", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(rows.isEmpty)

                Spacer()

                Button("Done", role: .cancel) {
                    actions.cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(moveButtonTitle, role: .destructive) {
                    actions.moveToTrash()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: sheetHeight)
        .confirmationDialog(
            "Clear Discard Pile?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                actions.clear()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all marked items from the Discard Pile. Files on disk are unchanged.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No Items Marked")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sheetHeight: CGFloat {
        rows.isEmpty ? 240 : 420
    }

    private var summaryText: String {
        guard !summary.isEmpty else {
            return "No items marked"
        }

        return "\(summary.itemCount.formatted()) \(summary.itemCount == 1 ? "item" : "items") • \(RadixFormatters.size(summary.totalAllocatedSize))"
    }

    private var moveButtonTitle: String {
        "Move \(summary.itemCount.formatted()) \(summary.itemCount == 1 ? "Item" : "Items") to Trash"
    }
}

private struct DiscardPileReviewRow: Identifiable {
    let id: FileNodeRecord.ID
    let name: String
    let systemImageName: String
    let path: String
    let sizeText: String
    let itemKind: String

    init(node: FileNodeRecord) {
        self.id = node.id
        self.name = node.name
        self.systemImageName = node.systemImageName
        self.path = node.url.path
        self.sizeText = RadixFormatters.size(node.allocatedSize)
        self.itemKind = node.itemKind
    }
}

private extension DiscardPileSummary {
    init(nodes: [FileNodeRecord]) {
        self.init(
            itemCount: nodes.count,
            totalAllocatedSize: nodes.reduce(into: Int64(0)) { total, node in
                total += node.allocatedSize
            }
        )
    }
}
