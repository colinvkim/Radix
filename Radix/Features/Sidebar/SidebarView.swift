import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: { appModel.selectedTarget?.id },
            set: { newValue in
                guard let newValue,
                      newValue != appModel.selectedTarget?.id else { return }

                Task { @MainActor in
                    appModel.selectSidebarTarget(id: newValue)
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if !appModel.smartTargets.isEmpty {
                Section {
                    ForEach(appModel.smartTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                } header: {
                    Text("Smart Locations")
                        .textCase(nil)
                }
            }

            if !appModel.mountedVolumeTargets.isEmpty {
                Section {
                    ForEach(appModel.mountedVolumeTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                } header: {
                    Text("Volumes")
                        .textCase(nil)
                }
            }

            if !appModel.recentScanTargets.isEmpty {
                Section {
                    ForEach(appModel.recentScanTargets) { target in
                        SidebarTargetRow(target: target)
                            .tag(target.id)
                    }
                } header: {
                    Text("Recent Scans")
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("Locations")
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SidebarTargetRow: View {
    let target: ScanTarget

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.sidebarTitle)
                    .lineLimit(1)
                Text(target.sidebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: target.sidebarSymbolName)
                .foregroundStyle(target.kind == .volume ? Color.accentColor : Color.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                SystemIntegration.reveal(target.url)
            }
        }
        .help(target.url.path)
        .padding(.vertical, 2)
    }
}
