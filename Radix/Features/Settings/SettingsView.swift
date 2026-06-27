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

            PrivacySettingsPane(scanState: appModel.scanState)
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .tag(SettingsTab.privacy.rawValue)

            StatsSettingsPane()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
                .tag(SettingsTab.stats.rawValue)
        }
        .scenePadding()
        .frame(width: 560, height: 530)
    }
}

private enum SettingsTab: String {
    case general
    case privacy
    case stats
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Show hidden files while scanning", isOn: $appModel.showHiddenFiles)
                Toggle("Treat app bundles and packages as folders", isOn: $appModel.treatPackagesAsDirectories)
                Toggle("Automatically summarize folders with many small files", isOn: $appModel.autoSummarizeDirectories)
                Toggle("Scan cloud storage folders", isOn: $appModel.scanCloudStorageFolders)

                Text("Hidden files are included by default. Mounted volume scans always include them automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("When enabled, directories with thousands of tiny files (like node_modules or caches) are summarized without expanding every file, dramatically improving scan speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("When off, Radix skips ~/Library/CloudStorage (Google Drive, Dropbox, OneDrive, and similar sync folders) and iCloud Drive at ~/Library/Mobile Documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Exclusions") {
                Toggle("Use scan exclusions", isOn: $appModel.useScanExclusions)
                ExclusionPatternsEditor(patterns: $appModel.exclusionPatterns)
                    .disabled(!appModel.useScanExclusions)
            }

            Section("Visualization") {
                Toggle("Show free space in sunburst", isOn: $appModel.showFreeSpaceInSunburst)

                Picker("Sunburst depth", selection: $appModel.maxRenderedDepth) {
                    ForEach(3...10, id: \.self) { depth in
                        Text("\(depth) rings")
                            .tag(depth)
                    }
                }
                .pickerStyle(.menu)

                Text("Changes apply immediately to the current disk map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Free space appears only for mounted volume scans and uses macOS available capacity, which can include purgeable APFS space.")
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

private struct ExclusionPatternsEditor: View {
    @Binding private var patterns: [String]
    @State private var rows: [ExclusionPatternRow]
    @State private var selectedPatternID: ExclusionPatternRow.ID?
    @State private var patternIDToReveal: ExclusionPatternRow.ID?
    @FocusState private var focusedPatternID: ExclusionPatternRow.ID?

    init(patterns: Binding<[String]>) {
        _patterns = patterns
        _rows = State(initialValue: Self.rows(from: patterns.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                List(selection: $selectedPatternID) {
                    ForEach(rows) { row in
                        patternField(for: row)
                    }
                }
                .frame(minHeight: 120)
                .onChange(of: patternIDToReveal) { _, id in
                    guard let id else { return }
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    patternIDToReveal = nil
                }
            }

            HStack {
                ControlGroup {
                    Button(action: addPattern) {
                        Label("Add Pattern", systemImage: "plus")
                    }
                    .help("Add Pattern")

                    Button(action: deleteSelectedPattern) {
                        Label("Remove Pattern", systemImage: "minus")
                    }
                    .disabled(!canDeleteSelectedPattern)
                    .help("Remove Pattern")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)

                Spacer()

                Menu("Add Preset") {
                    ForEach(ScanExclusionMatcher.commonPresetPatterns, id: \.self) { pattern in
                        Button(pattern) {
                            addPreset(pattern)
                        }
                        .disabled(rows.containsPattern(pattern))
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
            }
        }
        .onChange(of: patterns) { _, newPatterns in
            syncRows(with: newPatterns)
        }
        .onChange(of: focusedPatternID) { oldID, newID in
            if oldID != nil, oldID != newID {
                commitRows(preservingDraftIDs: [oldID, newID].compactMap(\.self))
            }

            if let newID, rows.contains(where: { $0.id == newID }) {
                selectedPatternID = newID
            }
        }
        .onDisappear {
            commitRows()
        }
        .onDeleteCommand(perform: deleteSelectedPattern)
    }

    private var canDeleteSelectedPattern: Bool {
        guard let selectedPatternID else { return false }
        return rows.contains { $0.id == selectedPatternID }
    }

    private func patternField(for row: ExclusionPatternRow) -> some View {
        let id = row.id

        return TextField("Pattern", text: patternBinding(for: id))
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedPatternID, equals: id)
            .onSubmit {
                commitRows(preservingDraftIDs: [id])
                focusedPatternID = nil
            }
            .id(id)
    }

    private func patternBinding(for id: ExclusionPatternRow.ID) -> Binding<String> {
        Binding {
            rows.first { $0.id == id }?.pattern ?? ""
        } set: { newValue in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].pattern = newValue
        }
    }

    private func addPattern() {
        if let existingDraft = rows.first(where: \.isBlank) {
            reveal(existingDraft, focus: true)
            return
        }

        let row = ExclusionPatternRow(pattern: "")
        rows.append(row)
        reveal(row, focus: true)
    }

    private func addPreset(_ pattern: String) {
        commitRows(preservingDraftIDs: focusedDraftIDs)
        guard !rows.containsPattern(pattern) else { return }
        let row = ExclusionPatternRow(pattern: pattern)
        rows.append(row)
        reveal(row, focus: false)
        commitRows(preservingDraftIDs: focusedDraftIDs)
    }

    private func deleteSelectedPattern() {
        guard let selectedPatternID else { return }

        clearInteractionState(for: [selectedPatternID])
        rows.removeAll { $0.id == selectedPatternID }
        commitRows()
    }

    private var focusedDraftIDs: [ExclusionPatternRow.ID] {
        focusedPatternID.map { [$0] } ?? []
    }

    private func reveal(_ row: ExclusionPatternRow, focus: Bool) {
        selectedPatternID = row.id
        patternIDToReveal = row.id
        if focus {
            focusedPatternID = row.id
        }
    }

    private func clearInteractionState(for ids: some Sequence<ExclusionPatternRow.ID>) {
        let ids = Set(ids)
        if selectedPatternID.map(ids.contains) == true {
            selectedPatternID = nil
        }
        if focusedPatternID.map(ids.contains) == true {
            focusedPatternID = nil
        }
    }

    private func commitRows(preservingDraftIDs draftIDs: some Sequence<ExclusionPatternRow.ID> = []) {
        let draftIDs = Set(draftIDs)
        var seenPatterns = Set<String>()
        let committedRows = rows.compactMap { row -> ExclusionPatternRow? in
            let committedPattern = row.committedPattern
            guard !committedPattern.isEmpty else {
                return draftIDs.contains(row.id) ? row : nil
            }

            guard seenPatterns.insert(committedPattern).inserted || draftIDs.contains(row.id) else {
                return nil
            }

            var committedRow = row
            committedRow.pattern = committedPattern
            return committedRow
        }

        if rows != committedRows {
            rows = committedRows
        }

        let updatedPatterns = committedRows.committedPatterns

        if let selectedPatternID,
           !committedRows.contains(where: { $0.id == selectedPatternID }) {
            self.selectedPatternID = nil
        }

        if let focusedPatternID,
           !committedRows.contains(where: { $0.id == focusedPatternID }) {
            self.focusedPatternID = nil
        }

        guard patterns != updatedPatterns else { return }
        patterns = updatedPatterns
    }

    private func syncRows(with patterns: [String]) {
        let incomingRows = Self.rows(from: patterns)
        guard rows.committedPatterns != incomingRows.map(\.pattern) else { return }

        var reusableRows = rows
        rows = incomingRows.map { incomingRow in
            let pattern = incomingRow.pattern
            if let existingIndex = reusableRows.firstIndex(where: { $0.committedPattern == pattern }) {
                var existingRow = reusableRows.remove(at: existingIndex)
                existingRow.pattern = pattern
                return existingRow
            }

            return incomingRow
        }

        if let selectedPatternID,
           !rows.contains(where: { $0.id == selectedPatternID }) {
            self.selectedPatternID = nil
        }

        if let focusedPatternID,
           !rows.contains(where: { $0.id == focusedPatternID }) {
            self.focusedPatternID = nil
        }
    }

    private static func rows(from patterns: [String]) -> [ExclusionPatternRow] {
        ScanExclusionMatcher.normalizedPatterns(patterns).map { pattern in
            ExclusionPatternRow(pattern: pattern)
        }
    }
}

private struct ExclusionPatternRow: Identifiable, Hashable {
    let id: UUID
    var pattern: String

    init(id: UUID = UUID(), pattern: String) {
        self.id = id
        self.pattern = pattern
    }

    var isBlank: Bool {
        committedPattern.isEmpty
    }

    var committedPattern: String {
        ScanExclusionMatcher.normalizedPatterns([pattern]).first ?? ""
    }
}

private extension [ExclusionPatternRow] {
    func containsPattern(_ pattern: String) -> Bool {
        guard let committedPattern = ScanExclusionMatcher.normalizedPatterns([pattern]).first else {
            return false
        }

        return contains { $0.committedPattern == committedPattern }
    }

    var committedPatterns: [String] {
        ScanExclusionMatcher.normalizedPatterns(map(\.pattern))
    }
}

private struct PrivacySettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator

    var body: some View {
        Form {
            Section("Full Disk Access") {
                Text("Radix can scan ordinary folders immediately. For protected macOS locations such as Mail, Safari, Messages, and Library content, grant Full Disk Access in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    appModel.fullDiskAccessStatus.fullDiskAccessSettingsSummary,
                    systemImage: appModel.fullDiskAccessStatus.fullDiskAccessSystemImage
                )
                    .foregroundStyle(appModel.fullDiskAccessStatus.fullDiskAccessColor)
                    .font(.callout)

                HStack {
                    Button("Open Full Disk Access Settings") {
                        appModel.prepareAndOpenFullDiskAccessSettings()
                    }

                    Button("Recheck") {
                        appModel.refreshFullDiskAccessStatus()
                    }
                }

                if PermissionAdvisor.shouldSuggestFullDiskAccess(
                    for: scanState.snapshot,
                    fullDiskAccessStatus: appModel.fullDiskAccessStatus
                ) {
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

            Section("Recent Scans") {
                Text("Recent scan locations are stored locally so they can appear in the sidebar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Clear Recent Scans", role: .destructive) {
                    appModel.clearRecentTargets()
                }
                .disabled(appModel.recentTargets.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StatsSettingsPane: View {
    private static let emptyValueText = "—"

    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section {
                SpaceExploredHero(
                    bytes: appModel.usageStats.totalBytesScanned,
                    emptyValueText: Self.emptyValueText
                )
            }

            Section("Scanning") {
                StatValueRow("Scans run", value: countText(appModel.usageStats.totalScansRun))
                StatValueRow("Largest scan", value: sizeText(appModel.usageStats.largestScanBytes))
                StatValueRow("Average scan speed", value: rateText(appModel.usageStats.averageScanBytesPerSecond))
                StatValueRow("Fastest scan speed", value: rateText(appModel.usageStats.fastestScanBytesPerSecond))
            }

            Section("Interaction") {
                StatValueRow(
                    "Sunburst segments clicked",
                    value: countText(appModel.usageStats.sunburstSegmentsClicked)
                )
            }

            Section("Cleanup") {
                StatValueRow("Files deleted", value: countText(appModel.usageStats.filesDeleted))
                StatValueRow("Bytes moved to Trash", value: sizeText(appModel.usageStats.bytesMovedToTrash))
                StatValueRow(
                    "Biggest single cleanup",
                    value: sizeText(appModel.usageStats.biggestSingleCleanupBytes)
                )
            }

            Section("Storage") {
                Text("Stats are stored locally on this Mac. Radix records aggregate counts and sizes only.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reset Stats", role: .destructive) {
                    appModel.clearUsageStats()
                }
                .disabled(appModel.usageStats.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func countText(_ value: Int) -> String {
        guard value > 0 else { return Self.emptyValueText }
        return value.formatted()
    }

    private func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return Self.emptyValueText }
        return RadixFormatters.size(bytes)
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return Self.emptyValueText
        }

        return sizeText(Int64(bytesPerSecond.rounded())) + "/s"
    }
}

private struct SpaceExploredHero: View {
    let bytes: Int64
    let emptyValueText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedBytes: Int64 = 0

    private var valueText: String {
        guard displayedBytes > 0 else { return emptyValueText }
        return RadixFormatters.size(displayedBytes)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("Space explored")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(valueText)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(displayedBytes)))
                    .animation(.easeOut(duration: 0.18), value: displayedBytes)
                    .accessibilityLabel("Space explored")
                    .accessibilityValue(valueText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .task(id: bytes) {
            await animateDisplayedBytes(to: bytes)
        }
    }

    @MainActor
    private func animateDisplayedBytes(to targetBytes: Int64) async {
        let targetBytes = max(0, targetBytes)
        guard !reduceMotion else {
            displayedBytes = targetBytes
            return
        }

        let startBytes = displayedBytes
        guard startBytes != targetBytes else { return }
        guard targetBytes > 0 else {
            withAnimation(.easeOut(duration: 0.18)) {
                displayedBytes = 0
            }
            return
        }

        let frameCount = 36
        let frameDelay = Duration.milliseconds(18)
        for frame in 1...frameCount {
            do {
                try await Task.sleep(for: frameDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            let progress = Double(frame) / Double(frameCount)
            let easedProgress = 1 - pow(1 - progress, 3)
            let interpolatedBytes = Double(startBytes) + (Double(targetBytes - startBytes) * easedProgress)
            withAnimation(.easeOut(duration: 0.18)) {
                displayedBytes = max(0, Int64(interpolatedBytes.rounded()))
            }
        }

        withAnimation(.easeOut(duration: 0.18)) {
            displayedBytes = targetBytes
        }
    }
}

private struct StatValueRow: View {
    private let title: String
    private let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
