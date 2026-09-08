import SwiftUI

struct SettingsView: View {
    let softwareUpdates: SoftwareUpdateModel
    @AppStorage("selectedSettingsTab") private var selectedTab = SettingsTab.scanning

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanningSettingsPane()
                .tabItem {
                    Label(String(localized: "Scanning", table: "Interface"), systemImage: "magnifyingglass")
                }
                .tag(SettingsTab.scanning)

            DiskMapSettingsPane()
                .tabItem { Label("Disk Maps", systemImage: "chart.pie") }
                .tag(SettingsTab.diskMaps)

            StatsSettingsPane()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
                .tag(SettingsTab.stats)

            GeneralSettingsPane(softwareUpdates: softwareUpdates)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .scenePadding()
        .frame(width: 600, height: 580)
    }
}

private enum SettingsTab: String {
    case scanning
    case diskMaps
    case stats
    case general
}

private struct ScanningSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Scan Options") {
                SettingsToggle(
                    "Include hidden files",
                    detail: "Include dotfiles and hidden folders. Volume scans always include them.",
                    isOn: $appModel.showHiddenFiles
                )
                SettingsToggle(
                    "Expand packages",
                    detail: "Explore app bundles and other packages as folders.",
                    isOn: $appModel.treatPackagesAsDirectories
                )
                SettingsToggle(
                    "Summarize large folders",
                    detail: "Group folders with thousands of tiny files.",
                    isOn: $appModel.autoSummarizeDirectories
                )
            }

            Section("Exclusions") {
                SettingsToggle(
                    "Use exclusions",
                    detail: "Skip matching files and folders when scanning.",
                    isOn: $appModel.useScanExclusions
                )
                ExclusionPatternsEditor(patterns: $appModel.exclusionPatterns)
                    .disabled(!appModel.useScanExclusions)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiskMapSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Display") {
                Picker("Detail depth", selection: $appModel.maxRenderedDepth) {
                    ForEach(3...10, id: \.self) { depth in
                        Text("\(depth) levels").tag(depth)
                    }
                }
                .pickerStyle(.menu)

                SettingsToggle(
                    "Show free space in volume scans",
                    detail: "Uses macOS available capacity, which may include purgeable space.",
                    isOn: $appModel.showFreeSpaceInDiskMaps
                )
            }

            Section("Live Preview") {
                SettingsDiskMapPreview(
                    mode: appModel.scanVisualizationMode,
                    depthLimit: appModel.maxRenderedDepth,
                    showFreeSpace: appModel.showFreeSpaceInDiskMaps
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var softwareUpdates: SoftwareUpdateModel
    @State private var resetAction = SettingsResetAction.settings
    @State private var confirmsReset = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("Software Updates") {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Radix").font(.headline)
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    CheckForUpdatesView(softwareUpdates: softwareUpdates)
                }
                .padding(.vertical, 5)

                SettingsToggle(
                    "Automatically check for updates",
                    detail: "Check for new versions periodically.",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyChecksForUpdates },
                        set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Group {
                    if let lastCheck = softwareUpdates.lastUpdateCheckDate {
                        Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("No update checks yet.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Full Disk Access") {
                Label(
                    appModel.fullDiskAccessStatus.fullDiskAccessSettingsSummary,
                    systemImage: appModel.fullDiskAccessStatus.fullDiskAccessSystemImage
                )
                .foregroundStyle(appModel.fullDiskAccessStatus.fullDiskAccessColor)
                .font(.callout)

                Text("Allow Radix to scan protected locations such as Mail, Messages, and Safari data.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open System Settings…") {
                        appModel.prepareAndOpenFullDiskAccessSettings()
                    }
                    Button("Recheck") {
                        appModel.refreshFullDiskAccessStatus()
                    }
                }
            }

            Section("Welcome") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get to know Radix")
                        Text("Revisit the welcome screen and guided tour.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Welcome Screen") {
                        appModel.presentOnboarding()
                    }
                }
            }

            Section("Reset") {
                HStack {
                    Button("Clear Recent Scans…", role: .destructive) { confirm(.recents) }
                        .disabled(appModel.recentTargets.isEmpty)
                    Spacer()
                    Text("\(appModel.recentTargets.count) locations").foregroundStyle(.secondary)
                }
                Button("Reset Stats…", role: .destructive) { confirm(.stats) }
                    .disabled(appModel.usageStats.isEmpty)
                Button("Reset All Settings…", role: .destructive) { confirm(.settings) }
            }
        }
        .formStyle(.grouped)
        .alert(resetAction.title, isPresented: $confirmsReset) {
            Button("Cancel", role: .cancel) {}
            Button(resetAction.buttonTitle, role: .destructive) { performReset() }
        } message: {
            Text(resetAction.message)
        }
    }

    private func confirm(_ action: SettingsResetAction) {
        resetAction = action
        confirmsReset = true
    }

    private func performReset() {
        switch resetAction {
        case .settings:
            appModel.restoreDefaultPreferences()
            softwareUpdates.restoreDefaultPreferences()
        case .stats:
            appModel.clearUsageStats()
        case .recents:
            appModel.clearRecentTargets()
        }
    }
}

private enum SettingsResetAction {
    case settings
    case stats
    case recents

    var title: LocalizedStringKey {
        switch self {
        case .settings: "Reset all settings?"
        case .stats: "Reset stats?"
        case .recents: "Clear recent scans?"
        }
    }

    var buttonTitle: LocalizedStringKey {
        switch self {
        case .settings: "Reset All Settings"
        case .stats: "Reset Stats"
        case .recents: "Clear Recent Scans"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .settings:
            "Restores scan, disk map, and update preferences to their defaults, and replaces custom exclusion patterns with the built-in presets. Recent scans, stats, and Full Disk Access are kept."
        case .stats:
            "Clears the aggregate usage stats stored on this Mac. Preferences and recent scans are kept."
        case .recents:
            "Removes recent locations from the sidebar. Your files and saved scan snapshots are kept."
        }
    }
}

private struct SettingsToggle: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
        .padding(.vertical, 3)
    }
}
