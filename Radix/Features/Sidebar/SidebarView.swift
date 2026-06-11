import SwiftUI

struct SidebarActions {
    let selectTargetAfterViewUpdate: (String?) -> Void
    let revealInFinder: (ScanTarget) -> Void
    let removeRecentTarget: (ScanTarget) -> Void
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let actions: SidebarActions

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
        .navigationTitle("Locations")
        .listStyle(.sidebar)
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
