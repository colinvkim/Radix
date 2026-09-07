import SwiftUI

struct DiscardPileReviewActions {
    let removeNodes: (Set<FileNodeRecord.ID>) -> Void
    let clear: () -> Void
    let dismiss: () -> Void
    let moveToTrash: () -> Void
}

struct DiscardPileReviewSheet: View {
    @EnvironmentObject private var tour: WorkspaceTourController
    private let rows: [DiscardPileReviewRow]
    private let rowIDs: Set<FileNodeRecord.ID>
    private let summary: DiscardPileSummary
    private let actions: DiscardPileReviewActions

    @State private var selection: Set<FileNodeRecord.ID> = []
    @State private var isConfirmingClear = false

    init(snapshot: DiscardPileSnapshot, actions: DiscardPileReviewActions) {
        let rows = snapshot.nodes.map(DiscardPileReviewRow.init)
        self.rows = rows
        self.rowIDs = Set(rows.map(\.id))
        self.summary = snapshot.summary
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Discard Pile")
                    .font(.title3.weight(.semibold))

                Text("Review items before moving them to Trash.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let step = tour.step, step == .removeMark || step == .finished {
                WorkspaceTourPromptView(
                    step: step, showsCompletionButton: false, stop: tour.stop, advance: tour.advance
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            listAndStatusBar

            Text("Sizes show attributed allocated storage, not guaranteed space reclaimed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Clear All…") {
                    isConfirmingClear = true
                }
                .disabled(rows.isEmpty)

                Spacer()

                Button("Done", role: .cancel) {
                    actions.dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(moveButtonTitle, role: .destructive) {
                    actions.moveToTrash()
                }
                .keyboardShortcut(showsTourGuidance ? nil : .defaultAction)
                .disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: showsTourGuidance ? 560 : 420)
        .onAppear { tour.reviewOpened() }
        .confirmationDialog(
            "Clear Discard Pile?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                selection.removeAll()
                actions.clear()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all marked items from the Discard Pile. Files on disk are unchanged.")
        }
        .onChange(of: rowIDs) { _, currentRowIDs in
            selection.formIntersection(currentRowIDs)
        }
    }

    private var listAndStatusBar: some View {
        let selectedRowCount = selection.intersection(rowIDs).count

        return VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(rows) { row in
                    reviewRow(row)
                        .tag(row.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: FileNodeRecord.ID.self) { selectedIDs in
                if !selectedIDs.isEmpty {
                    Button("Remove from Discard Pile", systemImage: "minus.circle") {
                        remove(selectedIDs)
                    }
                }
            }
            .onDeleteCommand {
                remove(selection)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Items Marked", systemImage: "checklist")
                }
            }

            Divider()

            HStack(spacing: 4) {
                Text(summaryText)

                if selectedRowCount > 0 {
                    Text(verbatim: "•")
                    Text(selectedText(for: selectedRowCount))
                }

                Spacer()

                Button("Remove from Discard Pile", systemImage: "minus.circle") {
                    remove(selection)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove from Discard Pile")
                .disabled(selectedRowCount == 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private func reviewRow(_ row: DiscardPileReviewRow) -> some View {
        let removeButtonLabel = removeButtonLabel(for: row)

        return HStack(spacing: 10) {
            Image(systemName: row.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(row.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.path)
            }

            Spacer(minLength: 12)

            Text(row.sizeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Button {
                remove([row.id])
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(removeButtonLabel)
            .accessibilityLabel(Text(removeButtonLabel))
        }
        .padding(.vertical, 4)
    }

    private var summaryText: String {
        let size = RadixFormatters.size(summary.totalAllocatedSize)
        return String(localized: "\(summary.itemCount) items • \(size)", comment: "Discard Pile status showing the marked item count and total allocated size. The item count controls pluralization.")
    }

    private var showsTourGuidance: Bool {
        tour.step == .removeMark || tour.step == .finished
    }

    private func selectedText(for selectedRowCount: Int) -> String {
        String(localized: "\(selectedRowCount) selected", comment: "Discard Pile status showing the number of selected review rows. The count controls pluralization.")
    }

    private func removeButtonLabel(for row: DiscardPileReviewRow) -> String {
        String(localized: "Remove \(row.name) from Discard Pile", comment: "Accessible label and help text for removing an item from the Discard Pile review list.")
    }

    private func remove(_ selectedIDs: Set<FileNodeRecord.ID>) {
        let removedIDs = rowIDs.intersection(selectedIDs)
        guard !removedIDs.isEmpty else { return }

        selection.subtract(removedIDs)
        actions.removeNodes(removedIDs)
    }

    private var moveButtonTitle: String {
        let count = summary.itemCount.formatted()
        if summary.itemCount == 1 {
            return String(localized: "Move \(count) Item to Trash", comment: "Destructive action for moving one marked item to the Trash.")
        }
        return String(localized: "Move \(count) Items to Trash", comment: "Destructive action for moving multiple marked items to the Trash.")
    }
}

private struct DiscardPileReviewRow: Identifiable {
    let id: FileNodeRecord.ID
    let name: String
    let systemImageName: String
    let path: String
    let sizeText: String

    init(node: FileNodeRecord) {
        self.id = node.id
        self.name = node.name
        self.systemImageName = node.systemImageName
        self.path = node.url.path
        self.sizeText = RadixFormatters.size(node.allocatedSize)
    }
}
