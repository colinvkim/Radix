import SwiftUI

struct ExclusionPatternsEditor: View {
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
                .fixedSize(horizontal: true, vertical: false)

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
                .fixedSize(horizontal: true, vertical: false)
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
            publishCommittedPatterns()
        }
    }

    /// Keeps scan configuration current while a field remains focused. Without
    /// this, starting a scan from another window can use the value from before
    /// editing began because `commitRows` only runs on submit or focus loss.
    private func publishCommittedPatterns() {
        let updatedPatterns = rows.committedPatterns
        guard patterns != updatedPatterns else { return }
        patterns = updatedPatterns
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
