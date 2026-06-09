import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: { appModel.activeSidebarTargetID },
            set: { newValue in
                guard let newValue,
                      newValue != appModel.activeSidebarTargetID else { return }
                appModel.selectSidebarTarget(id: newValue)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if !appModel.smartTargets.isEmpty {
                Section("Smart Locations") {
                    ForEach(appModel.smartTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                }
            }

            if !appModel.mountedVolumeTargets.isEmpty {
                Section("Volumes") {
                    ForEach(appModel.mountedVolumeTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                }
            }

            if !appModel.recentScanTargets.isEmpty {
                Section("Recent Scans") {
                    ForEach(appModel.recentScanTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                }
            }
        }
        .navigationTitle("Locations")
        .listStyle(.sidebar)
    }
}

private struct SidebarTargetRow: View {
    @EnvironmentObject private var appModel: AppModel

    let target: ScanTarget

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.sidebarTitle)
                Text(appModel.sidebarSubtitle(for: target))
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
                appModel.revealTargetInFinder(target)
            }
        }
        .help(target.url.path)
    }
}
