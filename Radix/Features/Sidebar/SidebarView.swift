import SwiftUI

struct SidebarActions {
    let selectTargetAfterViewUpdate: (String?) -> Void
    let revealInFinder: (ScanTarget) -> Void
    let removeRecentTarget: (ScanTarget) -> Void
    let reviewCleanupList: () -> Void
    let addDroppedNodesToCleanupList: ([FileNodeRecord.ID], UUID?) -> Bool
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var scanState: ScanCoordinator
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let cleanupListSummary: CleanupListSummary
    let actions: SidebarActions

    @State private var cleanupListDropIsTargeted = false

    private var selection: Binding<String?> {
        Binding(
            get: { model.activeTargetID },
            set: { newValue in
                guard let newValue,
                      newValue != model.activeTargetID else { return }
                actions.selectTargetAfterViewUpdate(newValue)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if !model.smartTargetRows.isEmpty {
                    Section("Smart Locations") {
                        ForEach(model.smartTargetRows) { row in
                            SidebarTargetRow(
                                target: row.target,
                                subtitle: row.subtitle,
                                revealInFinder: { actions.revealInFinder(row.target) }
                            )
                                .tag(row.id)
                        }
                    }
                }

                if !model.recentScanTargetRows.isEmpty {
                    Section("Recent Scans") {
                        ForEach(model.recentScanTargetRows) { row in
                            SidebarTargetRow(
                                target: row.target,
                                subtitle: row.subtitle,
                                revealInFinder: { actions.revealInFinder(row.target) },
                                removeFromRecentScans: { actions.removeRecentTarget(row.target) }
                            )
                                .tag(row.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if scanState.snapshot != nil {
                Divider()

                CleanupListSidebarButton(
                    summary: cleanupListSummary,
                    isDropTargeted: cleanupListDropIsTargeted
                ) {
                    actions.reviewCleanupList()
                }
                .dropDestination(for: CleanupListDragPayload.self) { payloads, _ in
                    let snapshotIDs = Set(payloads.compactMap(\.snapshotID))
                    guard snapshotIDs.count <= 1 else { return false }
                    return actions.addDroppedNodesToCleanupList(
                        payloads.flatMap(\.nodeIDs),
                        snapshotIDs.first
                    )
                } isTargeted: { isTargeted in
                    cleanupListDropIsTargeted = isTargeted
                }
            }
        }
        .navigationTitle("Locations")
        .focused($focusedWorkspaceTarget, equals: .sidebar)
    }
}

private struct CleanupListSidebarButton: View {
    let summary: CleanupListSummary
    let isDropTargeted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup List")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: "checklist")
                    .foregroundStyle(summary.isEmpty ? Color.secondary : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .help("Review Cleanup List")
    }

    private var subtitle: String {
        guard !summary.isEmpty else {
            return "No items marked"
        }

        return "\(summary.itemCount.formatted()) \(summary.itemCount == 1 ? "item" : "items") • \(RadixFormatters.size(summary.totalAllocatedSize))"
    }
}

private struct SidebarTargetRow: View {
    let target: ScanTarget
    let subtitle: String
    let revealInFinder: () -> Void
    let removeFromRecentScans: (() -> Void)?

    init(
        target: ScanTarget,
        subtitle: String,
        revealInFinder: @escaping () -> Void,
        removeFromRecentScans: (() -> Void)? = nil
    ) {
        self.target = target
        self.subtitle = subtitle
        self.revealInFinder = revealInFinder
        self.removeFromRecentScans = removeFromRecentScans
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.sidebarTitle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: target.sidebarSymbolName)
                .foregroundStyle(target.kind == .volume ? Color.accentColor : Color.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder", systemImage: RadixSystemImages.revealInFinder) {
                revealInFinder()
            }

            if let removeFromRecentScans {
                Button("Remove from Recent Scans", systemImage: "minus.circle", role: .destructive) {
                    removeFromRecentScans()
                }
            }
        }
        .help(target.url.path)
    }
}
