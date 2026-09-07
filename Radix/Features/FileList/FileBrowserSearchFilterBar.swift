import SwiftUI

struct FileBrowserSearchFilterBar: View {
    @Binding var scope: FileBrowserFindTarget
    @Binding var query: FileBrowserQuery
    let isLoading: Bool
    @FocusState.Binding var isFocused: Bool

    @State private var showsFilterEditor = false

    private var scopeLabel: String {
        switch scope {
        case .currentContents:
            String(localized: "Current Contents", comment: "Search scope label for the currently visible directory contents.")
        case .entireScan:
            String(localized: "Entire Scan", comment: "Search scope label for all items in the scan.")
        }
    }

    private var prompt: String {
        switch scope {
        case .currentContents:
            String(localized: "Filter current contents", comment: "Search field placeholder for filtering the current directory contents.")
        case .entireScan:
            String(localized: "Search entire scan", comment: "Search field placeholder for searching all scanned items.")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            scopeMenu

            TextField(prompt, text: $query.text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .workspaceTourAnchor(.search)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if !query.text.isEmpty {
                clearTextButton
            }

            filterEditorButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var scopeMenu: some View {
        Menu {
            Button("Current Contents") {
                scope = .currentContents
                isFocused = true
            }

            Button("Entire Scan") {
                scope = .entireScan
                isFocused = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: scope == .currentContents ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                Text(scopeLabel)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private var clearTextButton: some View {
        Button {
            query.text = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(clearButtonLocalizedText)
        .accessibilityLabel(clearButtonLocalizedText)
    }

    private var clearButtonLocalizedText: String {
        scope == .currentContents
            ? String(localized: "Clear current contents filter", comment: "Help text for clearing the current-folder search filter.")
            : String(localized: "Clear entire scan search", comment: "Help text for clearing the whole-scan search.")
    }

    private var filterEditorButton: some View {
        Button {
            showsFilterEditor = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: query.structuredFilterCount > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                Text("Filters")
                if query.structuredFilterCount > 0 {
                    Text(verbatim: "(\(query.structuredFilterCount))")
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .foregroundStyle(query.structuredFilterCount > 0 ? Color.accentColor : .secondary)
        .help("Search Filters")
        .accessibilityLabel("Search Filters")
        .accessibilityValue(Text(verbatim: "\(query.structuredFilterCount)"))
        .popover(isPresented: $showsFilterEditor, arrowEdge: .bottom) {
            FileBrowserFilterEditor(query: $query)
        }
    }
}

private struct FileBrowserFilterEditor: View {
    @Binding var query: FileBrowserQuery
    @State private var sizeRelation: FileBrowserSizeRelation
    @State private var sizeValue: Double?
    @State private var sizeUnit: FileBrowserSizeUnit

    init(query: Binding<FileBrowserQuery>) {
        _query = query
        let filter = query.wrappedValue.allocatedSize
        let unit = FileBrowserSizeUnit.bestUnit(for: filter?.bytes ?? 0)
        _sizeRelation = State(initialValue: filter?.relation ?? .greaterThan)
        _sizeValue = State(initialValue: filter.map { Double($0.bytes) / Double(unit.bytes) })
        _sizeUnit = State(initialValue: unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search Filters")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 14) {
                kindFilterRow
                sizeFilterRow
            }

            if query.structuredFilterCount > 0 {
                Divider()

                Button("Clear Filters") {
                    sizeValue = nil
                    sizeRelation = .greaterThan
                    sizeUnit = .megabytes
                    query.itemKind = nil
                    query.allocatedSize = nil
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var kindFilterRow: some View {
        GridRow {
            Text("Kind")

            Picker("Kind", selection: $query.itemKind) {
                Text("Any").tag(nil as FileBrowserItemKindFilter?)
                Text("File").tag(FileBrowserItemKindFilter.file as FileBrowserItemKindFilter?)
                Text("Folder").tag(FileBrowserItemKindFilter.folder as FileBrowserItemKindFilter?)
                Text("Package").tag(FileBrowserItemKindFilter.package as FileBrowserItemKindFilter?)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .gridCellColumns(3)
        }
    }

    private var sizeFilterRow: some View {
        GridRow {
            Text("Size")

            Picker("Size comparison", selection: $sizeRelation) {
                Text("Greater Than").tag(FileBrowserSizeRelation.greaterThan)
                Text("At Least").tag(FileBrowserSizeRelation.atLeast)
                Text("Less Than").tag(FileBrowserSizeRelation.lessThan)
                Text("At Most").tag(FileBrowserSizeRelation.atMost)
            }
            .labelsHidden()
            .frame(width: 164)

            TextField(
                "Any",
                value: $sizeValue,
                format: .number.precision(.fractionLength(0...2))
            )
            .frame(width: 80)
            .accessibilityLabel("Size value")

            Picker("Size unit", selection: $sizeUnit) {
                ForEach(FileBrowserSizeUnit.allCases) { unit in
                    Text(verbatim: unit.title).tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
        .onChange(of: sizeRelation) {
            updateSizeFilter()
        }
        .onChange(of: sizeValue) {
            updateSizeFilter()
        }
        .onChange(of: sizeUnit) {
            updateSizeFilter()
        }
    }

    private func updateSizeFilter() {
        guard let sizeValue else {
            if query.allocatedSize != nil {
                query.allocatedSize = nil
            }
            return
        }
        guard let bytes = sizeUnit.byteCount(for: sizeValue) else {
            self.sizeValue = nil
            query.allocatedSize = nil
            return
        }

        let filter = FileBrowserAllocatedSizeFilter(
            relation: sizeRelation,
            bytes: bytes
        )
        if query.allocatedSize != filter {
            query.allocatedSize = filter
        }
    }
}

private extension FileBrowserQuery {
    var structuredFilterCount: Int {
        (itemKind == nil ? 0 : 1) + (allocatedSize == nil ? 0 : 1)
    }
}
