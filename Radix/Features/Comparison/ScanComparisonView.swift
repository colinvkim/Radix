import SwiftUI

struct ScanComparisonRowActions {
    let reveal: (ScanComparisonRow) -> Void
    let canReveal: (ScanComparisonRow) -> Bool
    let showInBrowser: (ScanComparisonRow) -> Void
    let canShowInBrowser: (ScanComparisonRow) -> Bool
    let copyPath: (ScanComparisonRow) -> Void
    let revealNode: (ScanComparisonChangeTreeNode) -> Void
    let canRevealNode: (ScanComparisonChangeTreeNode) -> Bool
    let showNodeInBrowser: (ScanComparisonChangeTreeNode) -> Void
    let canShowNodeInBrowser: (ScanComparisonChangeTreeNode) -> Bool
    let copyNodePath: (ScanComparisonChangeTreeNode) -> Void
}

struct ScanComparisonView: View {
    private static let initialSortOrder = [
        ScanComparisonRowComparator.defaultOrder
    ]
    private static let allChangeKinds = Set(ScanComparisonChangeKind.allCases)

    let comparison: ScanComparison
    let actions: ScanComparisonRowActions
    let onClose: () -> Void

    @State private var displayMode: ScanComparisonDisplayMode = .significant
    @State private var selectedChangeKinds: Set<ScanComparisonChangeKind>
    @State private var searchText = ""
    @State private var focusedLocationPath: String?
    @State private var sortOrder: [ScanComparisonRowComparator]
    @StateObject private var browserModel: ScanComparisonBrowserModel

    init(
        comparison: ScanComparison,
        actions: ScanComparisonRowActions,
        onClose: @escaping () -> Void
    ) {
        self.comparison = comparison
        self.actions = actions
        self.onClose = onClose

        let sortOrder = Self.initialSortOrder
        let selectedChangeKinds = Self.allChangeKinds
        self._selectedChangeKinds = State(initialValue: selectedChangeKinds)
        self._sortOrder = State(initialValue: sortOrder)
        self._browserModel = StateObject(wrappedValue: ScanComparisonBrowserModel())
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                header

                Divider()

                comparisonContent
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onClose()
                } label: {
                    Label("Back to Scan", systemImage: "chevron.backward")
                }
                .help("Back to Scan")
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Changes")
        .onChange(of: rowQuery) { _, query in
            refreshBrowser(using: query)
        }
        .onChange(of: selectedChangeKinds) { _, _ in
            browserModel.aggregateSelection.removeAll()
        }
        .onChange(of: displayMode) { _, mode in
            if mode == .significant {
                focusedLocationPath = nil
                browserModel.selection.removeAll()
            } else {
                browserModel.aggregateSelection.removeAll()
            }
        }
        .task(id: comparison.id) {
            refreshBrowser(using: rowQuery)
        }
        .onDisappear {
            browserModel.cancel()
        }
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if browserModel.isRefreshing && displayedRows.isEmpty && projection.roots.isEmpty {
            ProgressView {
                Text("Loading changes…", tableName: "Interface")
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if effectiveDisplayMode == .significant, !projection.roots.isEmpty {
            significantTable
        } else if displayedRows.isEmpty {
            emptyState
        } else {
            comparisonTable
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage Changes")
                        .font(.title2.weight(.semibold))

                    Text(changeHeadline)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(deltaColor(comparison.summary.allocatedDelta))
                }

                Spacer(minLength: 16)

                metricStrip
            }

            scanTimeline

            if comparison.coverage.confidence != .high {
                coverageBanner
            }

            HStack(spacing: 12) {
                Picker("Detail", selection: $displayMode) {
                    ForEach(ScanComparisonDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
                .accessibilityLabel("Comparison detail")

                Divider()
                    .frame(height: 22)

                Text("Show")

                Menu(changeKindSelectionTitle) {
                    ForEach(ScanComparisonChangeKind.allCases) { kind in
                        Toggle(kind.title, isOn: changeKindBinding(for: kind))
                    }

                    Divider()

                    Button("Select All") {
                        selectedChangeKinds = Self.allChangeKinds
                    }
                    .disabled(selectedChangeKinds == Self.allChangeKinds)

                    Button("Clear") {
                        selectedChangeKinds.removeAll()
                    }
                    .disabled(selectedChangeKinds.isEmpty)
                }
                .frame(width: 120, alignment: .leading)
                .help(selectedChangeKindDescription)
                .accessibilityLabel("Shown change types")

                if !comparison.rows.isEmpty {
                    comparisonStatus
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if effectiveDisplayMode == .significant, let selectedAggregateNode {
                aggregateSelectionActions(for: selectedAggregateNode)
            } else if let selectedRow {
                selectionActions(for: selectedRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changeHeadline: String {
        let delta = comparison.summary.allocatedDelta
        if delta > 0 {
            return String(localized: "Storage increased by \(RadixFormatters.size(delta))", comment: "Comparison headline for an increase in total storage.")
        }
        if delta < 0 {
            return String(localized: "Storage decreased by \(RadixFormatters.size(-delta))", comment: "Comparison headline for a decrease in total storage.")
        }
        return String(localized: "No net storage change", comment: "Comparison headline when total storage did not change.")
    }

    private var scanTimeline: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .foregroundStyle(.secondary)

            sourceSummary(title: String(localized: "Earlier", comment: "Label for the older scan in a comparison."), snapshot: comparison.before)

            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)

            sourceSummary(title: String(localized: "Later", comment: "Label for the newer scan in a comparison."), snapshot: comparison.after)

            Spacer(minLength: 8)

            Text("\(signedSize(comparison.summary.grossIncreasedAllocatedSize)) added or grew  •  \(RadixFormatters.size(comparison.summary.grossReclaimedAllocatedSize)) reclaimed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var coverageBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: coverageSymbolName)
                .foregroundStyle(coverageColor)

            Text(coverageMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(coverageColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var coverageMessage: String {
        switch comparison.coverage.confidence {
        case .high:
            return String(localized: "Comparable: same location, matching scan settings, and complete scans.", comment: "Comparison coverage message when both scans are directly comparable.")
        case .limited:
            let warningCount = comparison.coverage.beforeWarningCount + comparison.coverage.afterWarningCount
            if warningCount > 0 {
                if warningCount == 1 {
                    return String(localized: "Limited coverage: \(warningCount) unreadable location. Missing entries below it are not necessarily deleted.", comment: "Comparison coverage message when one location could not be read.")
                }
                return String(localized: "Limited coverage: \(warningCount) unreadable locations. Missing entries below them are not necessarily deleted.", comment: "Comparison coverage message when multiple locations could not be read.")
            }
            return String(localized: "Limited coverage: scan settings are unavailable for one or both scans.", comment: "Comparison coverage message when scan settings are missing.")
        case .low:
            return String(localized: "Forensic comparison only: scan coverage or settings differ, so totals may not be directly comparable.", comment: "Comparison coverage message when scan totals should not be compared directly.")
        }
    }

    private var coverageColor: Color {
        switch comparison.coverage.confidence {
        case .high:
            return .green
        case .limited:
            return .orange
        case .low:
            return .red
        }
    }

    private var coverageSymbolName: String {
        switch comparison.coverage.confidence {
        case .high:
            return "checkmark.seal.fill"
        case .limited:
            return "exclamationmark.triangle.fill"
        case .low:
            return "exclamationmark.octagon.fill"
        }
    }

    private func sourceSummary(title: String, snapshot: ComparedSnapshotSummary) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)

            Text(snapshot.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(comparisonDate(snapshot.comparisonDate))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var metricStrip: some View {
        HStack(spacing: 14) {
            comparisonMetric(String(localized: "Files", comment: "Comparison metric label for files."), signedCount(comparison.summary.fileCountDelta))
            comparisonMetric(String(localized: "Folders", comment: "Comparison metric label for folders."), signedCount(comparison.summary.directoryCountDelta))
            comparisonMetric(String(localized: "Modified", comment: "Comparison metric label for items whose tracked size changed."), comparison.summary.changedCount.formatted())
                .help("Items present in both scans whose tracked size changed")
            comparisonMetric(String(localized: "Warnings", comment: "Comparison metric label for scan warnings."), signedCount(comparison.summary.warningCountDelta))
        }
    }

    private func comparisonMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(minWidth: 66, alignment: .leading)
    }

    private var selectedChangeKindDescription: String {
        let selectedKinds = ScanComparisonChangeKind.allCases.filter(selectedChangeKinds.contains)
        if selectedKinds.isEmpty {
            return String(localized: "No change types selected", comment: "Accessibility description when no comparison change filters are selected.")
        }
        return selectedKinds.map(\.title).joined(separator: ", ")
    }

    private var changeKindSelectionTitle: String {
        if selectedChangeKinds == Self.allChangeKinds {
            return String(localized: "All Types", comment: "Comparison filter menu option when all change types are selected.")
        }
        if selectedChangeKinds.isEmpty {
            return String(localized: "None", comment: "Comparison filter menu option when no change types are selected.")
        }
        let selectedKinds = ScanComparisonChangeKind.allCases.filter(selectedChangeKinds.contains)
        if selectedKinds.count <= 2 {
            return selectedKinds.map(\.title).joined(separator: ", ")
        }
        return String(localized: "\(selectedKinds.count) Types", comment: "Comparison filter menu title showing the number of selected change types.")
    }

    private func changeKindBinding(for kind: ScanComparisonChangeKind) -> Binding<Bool> {
        Binding(
            get: { selectedChangeKinds.contains(kind) },
            set: { isSelected in
                if isSelected {
                    selectedChangeKinds.insert(kind)
                } else {
                    selectedChangeKinds.remove(kind)
                }
            }
        )
    }

    private var effectiveDisplayMode: ScanComparisonDisplayMode {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? displayMode
            : .allChanges
    }

    private var comparisonStatus: some View {
        HStack(spacing: 6) {
            if browserModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Refreshing comparison", tableName: "Interface"))
            }

            if let focusedLocationPath {
                Button {
                    self.focusedLocationPath = nil
                } label: {
                    Label(focusedLocationPath, systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
                .help("Clear location filter")
            }

            Image(systemName: effectiveDisplayMode == .significant ? "scope" : "list.bullet")
                .foregroundStyle(.secondary)

            if effectiveDisplayMode == .significant {
                Text(significantStatusText)
            } else {
                Text("Showing \(displayedRows.count.formatted()) of \(comparison.rows.count.formatted()) filesystem changes.")
                if !searchText.isEmpty, displayMode == .significant {
                    Text("Search uses All Changes.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var significantStatusText: String {
        let percentage = projection.representedFraction.formatted(.percent.precision(.fractionLength(0)))
        if selectedChangeKinds.isEmpty {
            return String(localized: "No change types selected.", comment: "Comparison status when no change filters are selected.")
        }
        if projection.hiddenRootCount == 0 {
            return String(localized: "Showing all meaningful contributors; expand folders to trace their source.", comment: "Comparison status when all meaningful contributors are visible.")
        }
        return String(localized: "Named contributors represent \(percentage) of selected impact; \(projection.groupedAffectedCount.formatted()) smaller changes are grouped under Other.", comment: "Comparison status explaining that smaller changes are grouped under Other.")
    }

    private var significantTable: some View {
        Table(
            projection.roots,
            children: \.children,
            selection: $browserModel.aggregateSelection
        ) {
            TableColumn("Item") { node in
                comparisonItemLabel(
                    name: node.name,
                    symbol: itemSymbol(for: node),
                    detail: node.isRemainder
                        ? String(localized: "Switch to All Changes to inspect every item", comment: "Hint for inspecting items grouped in the comparison remainder.")
                        : itemLocation(for: node),
                    isRemainder: node.isRemainder
                )
            }
            .width(min: 280, ideal: 500)

            TableColumn("Change") { node in
                aggregateChangeLabel(for: node)
            }
            .width(min: 105, ideal: 120)

            TableColumn("Increase") { node in
                Text(node.increasedAllocatedSize == 0 ? "–" : "+" + RadixFormatters.size(node.increasedAllocatedSize))
                    .foregroundStyle(node.increasedAllocatedSize == 0 ? Color.secondary : Color.red)
                    .monospacedDigit()
                    .accessibilityLabel("Increased by \(RadixFormatters.size(node.increasedAllocatedSize))")
            }
            .width(min: 120, ideal: 140)

            TableColumn("Decrease") { node in
                Text(node.reclaimedAllocatedSize == 0 ? "–" : "−" + RadixFormatters.size(node.reclaimedAllocatedSize))
                    .foregroundStyle(node.reclaimedAllocatedSize == 0 ? Color.secondary : Color.green)
                    .monospacedDigit()
                    .accessibilityLabel("Decreased by \(RadixFormatters.size(node.reclaimedAllocatedSize))")
            }
            .width(min: 135, ideal: 155)

            TableColumn("Net Change") { node in
                Text(signedSize(node.allocatedDelta))
                    .foregroundStyle(deltaColor(node.allocatedDelta))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)
        }
        .contextMenu(forSelectionType: ScanComparisonChangeTreeNode.ID.self) { ids in
            aggregateContextMenu(for: ids)
        } primaryAction: { ids in
            guard let node = singleAggregateNode(in: ids) else { return }
            if node.isRemainder {
                showAllChanges(for: node)
            } else if actions.canShowNodeInBrowser(node) {
                actions.showNodeInBrowser(node)
            }
        }
    }

    private var comparisonTable: some View {
        Table(of: ScanComparisonRow.self, selection: $browserModel.selection, sortOrder: $sortOrder) {
            TableColumn("Item", sortUsing: ScanComparisonRowComparator(field: .relativePath)) { row in
                comparisonItemLabel(
                    name: row.name,
                    symbol: itemSymbol(for: row),
                    detail: itemLocation(for: row)
                )
            }
            .width(min: 280, ideal: 500)

            TableColumn("Change", sortUsing: ScanComparisonRowComparator(field: .changeKind)) { row in
                Label(row.kind.title, systemImage: row.kind.systemImageName)
                    .foregroundStyle(row.kind.tintColor)
            }
            .width(min: 105, ideal: 120)

            TableColumn("Increase", sortUsing: ScanComparisonRowComparator(field: .allocatedDelta)) { row in
                Text(row.allocatedDelta > 0 ? "+" + RadixFormatters.size(row.allocatedDelta) : "–")
                    .foregroundStyle(row.allocatedDelta > 0 ? Color.red : Color.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(positiveChangeAccessibilityLabel(for: row))
            }
            .width(min: 120, ideal: 140)

            TableColumn("Decrease", sortUsing: ScanComparisonRowComparator(field: .allocatedDelta)) { row in
                Text(row.allocatedDelta < 0 ? "−" + RadixFormatters.size(abs(row.allocatedDelta)) : "–")
                    .foregroundStyle(row.allocatedDelta < 0 ? Color.green : Color.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(negativeChangeAccessibilityLabel(for: row))
            }
            .width(min: 135, ideal: 155)

            TableColumn("Net Change", sortUsing: ScanComparisonRowComparator(field: .allocatedDelta)) { row in
                Text(signedSize(row.allocatedDelta))
                    .foregroundStyle(deltaColor(row.allocatedDelta))
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 120)
        } rows: {
            ForEach(displayedRows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: ScanComparisonRow.ID.self) { ids in
            rowContextMenu(for: ids)
        } primaryAction: { ids in
            guard let row = singleRow(in: ids), actions.canReveal(row) else { return }
            actions.reveal(row)
        }
    }

    @ViewBuilder
    private func aggregateChangeLabel(for node: ScanComparisonChangeTreeNode) -> some View {
        if node.isRemainder {
            Text("-")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Grouped smaller changes")
        } else if node.affectedCount == 1,
                  let changeKind = node.directChangeKind,
                  selectedChangeKinds.contains(changeKind) {
            Label(changeKind.title, systemImage: changeKind.systemImageName)
                .foregroundStyle(changeKind.tintColor)
        } else if node.allocatedDelta > 0 {
            Label(ScanComparisonChangeKind.grew.title, systemImage: ScanComparisonChangeKind.grew.systemImageName)
                .foregroundStyle(ScanComparisonChangeKind.grew.tintColor)
                .help("\(node.affectedCount.formatted()) changes summarized")
        } else if node.allocatedDelta < 0 {
            Label(ScanComparisonChangeKind.shrank.title, systemImage: ScanComparisonChangeKind.shrank.systemImageName)
                .foregroundStyle(ScanComparisonChangeKind.shrank.tintColor)
                .help("\(node.affectedCount.formatted()) changes summarized")
        } else {
            Text("–", tableName: "Interface")
                .foregroundStyle(.secondary)
                .help("\(node.affectedCount.formatted()) changes summarized")
                .accessibilityLabel(Text("No net change", tableName: "Interface"))
        }
    }

    private var selectedRow: ScanComparisonRow? {
        singleRow(in: browserModel.selection)
    }

    private var selectedAggregateNode: ScanComparisonChangeTreeNode? {
        singleAggregateNode(in: browserModel.aggregateSelection)
    }

    private func aggregateSelectionActions(for node: ScanComparisonChangeTreeNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: itemSymbol(for: node))
                .foregroundStyle(.secondary)

            Text(node.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer()

            if node.isRemainder {
                Button {
                    showAllChanges(for: node)
                } label: {
                    Label("Show All Changes", systemImage: "list.bullet")
                }
            } else {
                Button {
                    actions.showNodeInBrowser(node)
                } label: {
                    Label("Show in Browser", systemImage: "sidebar.squares.left")
                }
                .disabled(!actions.canShowNodeInBrowser(node))

                Button {
                    actions.revealNode(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!actions.canRevealNode(node))

                Button {
                    actions.copyNodePath(node)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .disabled(node.fileURL == nil)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectionActions(for row: ScanComparisonRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: itemSymbol(for: row))
                .foregroundStyle(.secondary)

            Text(row.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer()

            Button {
                actions.showInBrowser(row)
            } label: {
                Label("Show in Browser", systemImage: "sidebar.squares.left")
            }
            .disabled(!actions.canShowInBrowser(row))

            Button {
                actions.reveal(row)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!actions.canReveal(row))

            Button {
                actions.copyPath(row)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<ScanComparisonRow.ID>) -> some View {
        if let row = singleRow(in: ids) {
            Button {
                actions.reveal(row)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!actions.canReveal(row))

            Button {
                actions.showInBrowser(row)
            } label: {
                Label("Show in Browser", systemImage: "sidebar.squares.left")
            }
            .disabled(!actions.canShowInBrowser(row))

            Divider()

            Button {
                actions.copyPath(row)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private func aggregateContextMenu(for ids: Set<ScanComparisonChangeTreeNode.ID>) -> some View {
        if let node = singleAggregateNode(in: ids) {
            if node.isRemainder {
                Button {
                    showAllChanges(for: node)
                } label: {
                    Label("Show All Changes", systemImage: "list.bullet")
                }
            } else {
                Button {
                    actions.revealNode(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!actions.canRevealNode(node))

                Button {
                    actions.showNodeInBrowser(node)
                } label: {
                    Label("Show in Browser", systemImage: "sidebar.squares.left")
                }
                .disabled(!actions.canShowNodeInBrowser(node))

                Divider()

                Button {
                    actions.copyNodePath(node)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .disabled(node.fileURL == nil)
            }
        }
    }

    private func singleAggregateNode(
        in ids: Set<ScanComparisonChangeTreeNode.ID>
    ) -> ScanComparisonChangeTreeNode? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return projection.node(withID: id)
    }

    private func showAllChanges(for node: ScanComparisonChangeTreeNode) {
        displayMode = .allChanges
        focusedLocationPath = node.relativePath.isEmpty ? nil : node.relativePath
        browserModel.aggregateSelection.removeAll()
    }

    private func singleRow(in ids: Set<ScanComparisonRow.ID>) -> ScanComparisonRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return comparison.rows.first { $0.id == id }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyStateTitle,
            systemImage: emptyStateSystemImage,
            description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        comparison.rows.isEmpty
            ? String(localized: "No Tracked Size Changes", comment: "Comparison empty-state title when no size changes were found.")
            : String(localized: "No Matching Changes", comment: "Comparison empty-state title when filters hide all changes.")
    }

    private var emptyStateSystemImage: String {
        comparison.rows.isEmpty ? "checkmark.circle" : "magnifyingglass"
    }

    private var emptyStateDescription: String {
        if selectedChangeKinds.isEmpty {
            return String(localized: "Choose one or more change types to display.", comment: "Comparison empty-state guidance when no change filters are selected.")
        }
        return comparison.rows.isEmpty
            ? String(localized: "No tracked size changes were found.", comment: "Comparison empty-state message when scans have no tracked size changes.")
            : String(localized: "Choose a different view or adjust your search.", comment: "Comparison empty-state guidance when filters produce no results.")
    }

    private var rowQuery: ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            changeKinds: selectedChangeKinds,
            searchText: searchText,
            sortOrder: sortOrder,
            pathPrefix: focusedLocationPath
        )
    }

    private var displayedRows: [ScanComparisonRow] {
        browserModel.displayedRows
    }

    private var projection: ScanComparisonChangeTreeProjection {
        browserModel.projection
    }

    private func refreshBrowser(using query: ScanComparisonRowQuery) {
        browserModel.refresh(
            comparisonID: comparison.id,
            rows: comparison.rows,
            changeTree: comparison.changeTree,
            query: query
        )
    }

    private func positiveChangeAccessibilityLabel(for row: ScanComparisonRow) -> String {
        guard row.allocatedDelta > 0 else {
            return String(localized: "No increase", comment: "Accessibility label when a comparison row has no increase.")
        }
        return String(localized: "Increased by \(RadixFormatters.size(row.allocatedDelta))", comment: "Accessibility label for a comparison row's increase.")
    }

    private func negativeChangeAccessibilityLabel(for row: ScanComparisonRow) -> String {
        guard row.allocatedDelta < 0 else {
            return String(localized: "No decrease", comment: "Accessibility label when a comparison row has no decrease.")
        }
        return String(localized: "Decreased by \(RadixFormatters.size(abs(row.allocatedDelta)))", comment: "Accessibility label for a comparison row's decrease.")
    }

    private func comparisonItemLabel(
        name: String,
        symbol: String,
        detail: String,
        isRemainder: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .foregroundStyle(isRemainder ? Color.secondary : Color.primary)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func itemLocation(for row: ScanComparisonRow) -> String {
        if let movedFromRelativePath = row.movedFromRelativePath {
            return "\(movedFromRelativePath) → \(row.relativePath)"
        }

        return itemLocation(relativePath: row.relativePath, itemKind: row.itemKind)
    }

    private func itemLocation(for node: ScanComparisonChangeTreeNode) -> String {
        itemLocation(relativePath: node.relativePath, itemKind: itemKind(for: node))
    }

    private func itemLocation(relativePath: String, itemKind: String) -> String {
        let components = relativePath.split(separator: "/")
        let parent = components.dropLast().joined(separator: "/")
        return parent.isEmpty ? itemKind : parent
    }

    private func itemSymbol(for row: ScanComparisonRow) -> String {
        if (row.afterNode ?? row.beforeNode)?.isPackage == true {
            return "shippingbox.fill"
        }
        return row.isDirectory ? "folder.fill" : "doc.fill"
    }

    private func itemSymbol(for node: ScanComparisonChangeTreeNode) -> String {
        if node.isRemainder {
            return "ellipsis.circle"
        }
        if (node.afterNode ?? node.beforeNode)?.isPackage == true {
            return "shippingbox.fill"
        }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    private func itemKind(for node: ScanComparisonChangeTreeNode) -> String {
        (node.afterNode ?? node.beforeNode)?.itemKind ?? (node.isDirectory
            ? String(localized: "Folder", comment: "Fallback kind label for a comparison folder.")
            : String(localized: "Item", comment: "Fallback kind label for a comparison item."))
    }

    private func comparisonDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func signedSize(_ size: Int64) -> String {
        guard size != 0 else { return RadixFormatters.size(0) }
        let prefix = size > 0 ? "+" : "-"
        return prefix + RadixFormatters.size(abs(size))
    }

    private func signedCount(_ count: Int) -> String {
        guard count != 0 else { return "0" }
        return count > 0 ? "+\(count.formatted())" : "-\(abs(count).formatted())"
    }

    private func deltaColor(_ delta: Int64) -> Color {
        if delta > 0 {
            return .red
        }
        if delta < 0 {
            return .green
        }
        return .secondary
    }
}

private enum ScanComparisonDisplayMode: String, CaseIterable, Identifiable {
    case significant
    case allChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .significant:
            return String(localized: "Significant", comment: "Comparison display mode showing the most meaningful contributors.")
        case .allChanges:
            return String(localized: "All Changes", comment: "Comparison display mode showing every matching change.")
        }
    }
}

private extension ScanComparisonChangeKind {
    var systemImageName: String {
        switch self {
        case .added:
            return "plus.circle.fill"
        case .removed:
            return "minus.circle.fill"
        case .grew:
            return "arrow.up.circle.fill"
        case .shrank:
            return "arrow.down.circle.fill"
        case .moved:
            return "arrow.left.arrow.right.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .added:
            return .blue
        case .removed:
            return .orange
        case .grew:
            return .red
        case .shrank:
            return .green
        case .moved:
            return .purple
        }
    }
}
