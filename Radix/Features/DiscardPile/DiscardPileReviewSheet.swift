import SwiftUI

struct DiscardPileReviewActions {
    let removeNodes: (Set<FileNodeRecord.ID>) -> Void
    let clear: () -> Void
    let dismiss: () -> Void
    let cleanup: (TrashFlowController.DiscardPileCleanupAction) -> Void
    let cancelCleanup: () -> Void
    let confirmCleanup: (TrashFlowController.DiscardPileCleanupAction) -> Void
}

struct DiscardPileReviewSheet: View {
    @EnvironmentObject private var tour: WorkspaceTourController
    private let nodes: [FileNodeRecord]
    private let rowIDs: Set<FileNodeRecord.ID>
    private let summary: DiscardPileSummary
    private let canMoveToTrash: Bool
    private let isPreparingTrash: Bool
    private let pendingCleanup: TrashFlowController.PendingTrashSelection?
    private let actions: DiscardPileReviewActions

    @State private var selection: Set<FileNodeRecord.ID> = []
    @State private var isConfirmingClear = false

    init(
        snapshot: DiscardPileSnapshot,
        canMoveToTrash: Bool,
        isPreparingTrash: Bool,
        pendingCleanup: TrashFlowController.PendingTrashSelection?,
        actions: DiscardPileReviewActions
    ) {
        self.nodes = snapshot.nodes
        self.rowIDs = Set(snapshot.nodes.map(\.id))
        self.summary = snapshot.summary
        self.canMoveToTrash = canMoveToTrash
        self.isPreparingTrash = isPreparingTrash
        self.pendingCleanup = pendingCleanup
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pendingCleanup {
                DiscardPileTrashConfirmationSheet(
                    selection: pendingCleanup,
                    onCancel: actions.cancelCleanup,
                    onConfirm: { actions.confirmCleanup(pendingCleanup.action) }
                )
            } else {
                review
            }
        }
        .onAppear { tour.reviewOpened() }
        .onChange(of: rowIDs) { previousRowIDs, currentRowIDs in
            let restoredIDs = currentRowIDs.subtracting(previousRowIDs)
            selection = restoredIDs.isEmpty ? selection.intersection(currentRowIDs) : restoredIDs
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discard Pile")
                .font(.title3.weight(.semibold))

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
                Button("Remove All Marks…") {
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

                cleanupButton
                    .disabled(!canMoveToTrash)
            }
        }
        .padding(20)
        .frame(width: 720, height: showsTourGuidance ? 560 : 420)
        .confirmationDialog(
            "Clear Discard Pile?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Remove All Marks", role: .destructive) {
                selection.removeAll()
                actions.clear()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all marked items from the Discard Pile. Files on disk are unchanged.")
        }
    }

    @ViewBuilder
    private var cleanupButton: some View {
        if tour.isActive {
            Button("Move to Trash…") { actions.cleanup(.moveToTrash) }
                .keyboardShortcut(showsTourGuidance ? nil : .defaultAction)
        } else {
            Menu {
                Button("Delete Permanently…", role: .destructive) {
                    actions.cleanup(.deletePermanently)
                }
            } label: {
                Text("Move to Trash…")
            } primaryAction: {
                actions.cleanup(.moveToTrash)
            }
            .fixedSize()
            .keyboardShortcut(.defaultAction)
        }
    }

    private var listAndStatusBar: some View {
        let selectedRowCount = selection.intersection(rowIDs).count

        return VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(nodes) { node in
                    reviewRow(node)
                        .tag(node.id)
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
                if nodes.isEmpty {
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

    private func reviewRow(_ node: FileNodeRecord) -> some View {
        let path = node.url.path
        let removeButtonLabel = removeButtonLabel(for: node)

        return HStack(spacing: 10) {
            Image(systemName: node.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }

            Spacer(minLength: 12)

            Text(RadixFormatters.size(node.allocatedSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Button {
                remove([node.id])
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

    private func removeButtonLabel(for node: FileNodeRecord) -> String {
        String(localized: "Remove \(node.name) from Discard Pile", comment: "Accessible label and help text for removing an item from the Discard Pile review list.")
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
        let hasItems = !selection.nodes.isEmpty
        let deletesPermanently = selection.action == .deletePermanently
        let title: LocalizedStringKey = switch (selection.action, hasItems) {
        case (.moveToTrash, true): "Move to Trash?"
        case (.moveToTrash, false): "No Items Can Be Moved"
        case (.deletePermanently, true): "Delete Permanently?"
        case (.deletePermanently, false): "No Items Can Be Deleted"
        }
        let cancelTitle: LocalizedStringKey = hasItems ? "Cancel" : "Close"
        let itemsTitle: LocalizedStringKey = deletesPermanently ? "Items to Delete" : "Items to Move"

        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if deletesPermanently && hasItems {
                if selection.nodes.contains(where: { $0.isDirectory && !$0.isSymbolicLink }) {
                    Text("This action can’t be undone. All contents of listed folders will also be deleted.")
                } else {
                    Text("This action can’t be undone.")
                }
            }

            List {
                if hasItems {
                    Section(itemsTitle) {
                        ForEach(selection.nodes) { node in
                            let resolvedURL = selection.discardPileBatch?.resolvedURLsByOperationID[node.id]
                            Text(verbatim: (deletesPermanently ? resolvedURL ?? node.url : node.url).path)
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

                if hasItems {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 360)
    }

    private var confirmTitle: String {
        switch selection.action {
        case .moveToTrash:
            String(localized: "Move \(selection.nodes.count) Items to Trash", comment: "Destructive action for moving marked items to the Trash.")
        case .deletePermanently:
            String(localized: "Delete \(selection.nodes.count) Items Permanently", comment: "Destructive action for permanently deleting the listed items. The count controls pluralization.")
        }
    }
}
