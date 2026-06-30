import SwiftUI

struct SidebarActions {
    let selectTargetAfterViewUpdate: (String?) -> Void
    let revealInFinder: (ScanTarget) -> Void
    let removeRecentTarget: (ScanTarget) -> Void
    let reviewDiscardPile: () -> Void
    let addDroppedNodesToDiscardPile: ([FileNodeRecord.ID], UUID) -> Bool
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var scanState: ScanCoordinator
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let discardPileSummary: DiscardPileSummary
    let discardPileDragIsActive: Bool
    let actions: SidebarActions

    @State private var discardPileDropIsTargeted = false

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

                DiscardPileSidebarButton(
                    summary: discardPileSummary,
                    isDropHintActive: discardPileDragIsActive,
                    isDropTargeted: $discardPileDropIsTargeted,
                    addDroppedPayloads: addDroppedPayloadsToDiscardPile
                ) {
                    actions.reviewDiscardPile()
                }
            }
        }
        .navigationTitle("Locations")
        .focused($focusedWorkspaceTarget, equals: .sidebar)
    }

    private func addDroppedPayloadsToDiscardPile(_ payloads: [DiscardPileDragPayload]) -> Bool {
        let snapshotIDs = Set(payloads.map(\.snapshotID))
        guard payloads.isEmpty == false,
              snapshotIDs.count == 1,
              let snapshotID = snapshotIDs.first else { return false }
        return actions.addDroppedNodesToDiscardPile(
            payloads.flatMap(\.nodeIDs),
            snapshotID
        )
    }
}

private struct DiscardPileSidebarButton: View {
    let summary: DiscardPileSummary
    let isDropHintActive: Bool
    @Binding var isDropTargeted: Bool
    let addDroppedPayloads: ([DiscardPileDragPayload]) -> Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackgroundColor)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconForegroundColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Discard Pile")
                        .font(.subheadline.weight(.semibold))
                    subtitleText
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isDropHintActive || isDropTargeted {
                    Image(systemName: isDropTargeted ? "plus.circle.fill" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                        .transition(.opacity.combined(with: .scale(scale: 0.86)))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dropBackgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropBorderColor, style: dropBorderStyle)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(
            color: isDropTargeted ? Color.accentColor.opacity(0.22) : Color.clear,
            radius: isDropTargeted ? 8 : 0,
            x: 0,
            y: 2
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .dropDestination(for: DiscardPileDragPayload.self) { payloads, _ in
            addDroppedPayloads(payloads)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isDropHintActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isDropTargeted)
        .help("Review Discard Pile")
    }

    private var iconSystemName: String {
        isDropTargeted ? "tray.and.arrow.down.fill" : "checklist"
    }

    private var iconForegroundColor: Color {
        if isDropHintActive || isDropTargeted || !summary.isEmpty {
            return .accentColor
        }

        return .secondary
    }

    private var iconBackgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.2)
        }

        if isDropHintActive {
            return Color.accentColor.opacity(0.11)
        }

        return .clear
    }

    private var dropBackgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.18)
        }

        if isDropHintActive {
            return Color.accentColor.opacity(0.07)
        }

        return .clear
    }

    private var dropBorderColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.72)
        }

        if isDropHintActive {
            return Color.accentColor.opacity(0.42)
        }

        return .clear
    }

    private var dropBorderStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: isDropTargeted ? 1.5 : 1,
            lineCap: .round,
            dash: isDropTargeted ? [] : [5, 4]
        )
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(subtitleForegroundColor)
            .lineLimit(1)
            .overlay {
                if shouldShimmerSubtitle {
                    ShimmeringTextHighlight(
                        text: subtitle,
                        font: .caption
                    )
                }
            }
    }

    private var subtitleForegroundColor: Color {
        if isDropTargeted {
            return .primary
        }

        if isDropHintActive {
            return .accentColor
        }

        return .secondary
    }

    private var shouldShimmerSubtitle: Bool {
        isDropHintActive && !isDropTargeted && !reduceMotion
    }

    private var subtitle: String {
        if isDropTargeted {
            return "Release to add"
        }

        if isDropHintActive {
            return "Drop here to add"
        }

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
