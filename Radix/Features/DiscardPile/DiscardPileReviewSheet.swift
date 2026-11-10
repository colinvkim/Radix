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
    private let canMoveToTrash: Bool
    private let isPreparingTrash: Bool
    private let actions: DiscardPileReviewActions

    @State private var selection: Set<FileNodeRecord.ID> = []
    @State private var isConfirmingClear = false

    init(
        snapshot: DiscardPileSnapshot,
        canMoveToTrash: Bool,
        isPreparingTrash: Bool,
        actions: DiscardPileReviewActions
    ) {
        let rows = snapshot.nodes.map(DiscardPileReviewRow.init)
        self.rows = rows
        self.rowIDs = Set(rows.map(\.id))
        self.summary = snapshot.summary
        self.canMoveToTrash = canMoveToTrash
        self.isPreparingTrash = isPreparingTrash
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

            Divider()

            HStack {
                Button("Clear All…") {
                    isConfirmingClear = true
                }
                .disabled(summary.isEmpty)

                Spacer()

                Button("Done", role: .cancel) {
                    actions.dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if isPreparingTrash {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Checking Marked Items"))
                }

                Button("Move to Trash…") {
                    actions.moveToTrash()
                }
                .keyboardShortcut(showsTourGuidance ? nil : .defaultAction)
                .disabled(!canMoveToTrash)
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
        .onChange(of: rowIDs) { previousRowIDs, currentRowIDs in
            let restoredIDs = currentRowIDs.subtracting(previousRowIDs)
            selection = restoredIDs.isEmpty ? selection.intersection(currentRowIDs) : restoredIDs
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
                Text(summary.markedItemsText)

                if selectedRowCount > 0 {
                    Text(verbatim: "•")
                    Text(selectedText(for: selectedRowCount))
                }

                Spacer()

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
}

struct DiscardPileTrashConfirmationSheet: View {
    let selection: TrashFlowController.PendingTrashSelection
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let hasItemsToMove = !selection.nodes.isEmpty
        let title: LocalizedStringKey = hasItemsToMove ? "Move to Trash?" : "No Items Can Be Moved"
        let cancelTitle: LocalizedStringKey = hasItemsToMove ? "Cancel" : "Close"

        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            List {
                if hasItemsToMove {
                    Section("Items to Move") {
                        ForEach(selection.nodes) { node in
                            Text(verbatim: node.url.path)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let unavailable = selection.discardPileBatch?.unavailable, !unavailable.isEmpty {
                    Section("Items That Will Stay Marked") {
                        ForEach(unavailable, id: \.node.id) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: item.node.url.path)
                                Text(verbatim: item.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .textSelection(.enabled)

            HStack {
                Spacer()

                Button(cancelTitle, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if hasItemsToMove {
                    Button(
                        String(localized: "Move \(selection.nodes.count) Items to Trash", comment: "Destructive action for moving marked items to the Trash."),
                        role: .destructive,
                        action: onConfirm
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 360)
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
