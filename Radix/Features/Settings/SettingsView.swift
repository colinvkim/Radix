import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("selectedSettingsTab") private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPane()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general.rawValue)

            PrivacySettingsPane()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy.rawValue)
        }
        .scenePadding()
        .frame(width: 520, height: 340)
    }
}

private enum SettingsTab: String {
    case general
    case privacy
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Show hidden files while scanning", isOn: $appModel.showHiddenFiles)
                Toggle("Treat app bundles and packages as folders", isOn: $appModel.treatPackagesAsDirectories)
                Toggle("Automatically summarize folders with many small files", isOn: $appModel.autoSummarizeDirectories)

                Text("Hidden files are included by default. Mounted volume scans always include them automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("When enabled, directories with thousands of tiny files (like node_modules or caches) are summarized without expanding every file, dramatically improving scan speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visualization") {
                Stepper(value: $appModel.maxRenderedDepth, in: 3...10) {
                    LabeledContent("Sunburst depth") {
                        Text("\(appModel.maxRenderedDepth) rings")
                    }
                }

                Text("Changes apply immediately to the current disk map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workspace") {
                Button("Show Welcome Screen") {
                    appModel.presentOnboarding()
                }

                Button("Restore Defaults") {
                    appModel.restoreDefaultPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Full Disk Access") {
                Text("Radix can scan ordinary folders immediately. For protected macOS locations such as Mail, Safari, Messages, and Library content, grant Full Disk Access in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Full Disk Access Settings") {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }

                if appModel.shouldSuggestFullDiskAccess {
                    Label("Recent scan results suggest that protected folders were skipped.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Label("No protected-folder warning is active for the current scan.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            Section("File Actions") {
                Text("Reveal, Open, Copy Path, and Move to Trash always act on the current visible selection. Radix stays read-only unless you explicitly choose a file action.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
