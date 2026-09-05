import Foundation

nonisolated struct ScanComparisonSearchIndex: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let name: String
        let relativePath: String
    }

    private let entryByRowID: [ScanComparisonRow.ID: Entry]

    init(
        rows: [ScanComparisonRow],
        cancellationCheck: CancellationCheck
    ) throws {
        try cancellationCheck()
        var entryByRowID: [ScanComparisonRow.ID: Entry] = [:]
        entryByRowID.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            entryByRowID[row.id] = Entry(
                name: SearchNormalizer.normalize(row.name),
                relativePath: SearchNormalizer.normalize(row.relativePath)
            )
        }
        self.entryByRowID = entryByRowID
    }

    func row(_ row: ScanComparisonRow, matches normalizedQuery: String) -> Bool {
        guard let entry = entryByRowID[row.id] else { return false }
        return entry.name.contains(normalizedQuery)
            || entry.relativePath.contains(normalizedQuery)
    }
}

/// Sorts comparison evidence independently from the service that constructs it.
nonisolated struct ScanComparisonRowComparator: Equatable, SortComparator, Sendable {
    enum Field: Equatable, Sendable {
        case changeKind
        case relativePath
        case beforeAllocatedSize
        case afterAllocatedSize
        case allocatedDelta
        case absoluteAllocatedDelta
        case itemKind
    }

    static let defaultOrder = ScanComparisonRowComparator(field: .absoluteAllocatedDelta, order: .reverse)
    static let defaultSortOrder = [defaultOrder]

    static func sorted(
        _ rows: [ScanComparisonRow],
        using comparators: [ScanComparisonRowComparator],
        cancellationCheck: () throws -> Void
    ) rethrows -> [ScanComparisonRow] {
        guard !comparators.isEmpty else { return rows }
        return try CancellableSort.sortedByIndex(rows, cancellationCheck: cancellationCheck) {
            sortsBefore($0, $1, using: comparators)
        }
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: ScanComparisonRow, _ rhs: ScanComparisonRow) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .changeKind:
            FileNodeSortComparison.compare(lhs.kind.sortRank, rhs.kind.sortRank)
        case .relativePath:
            lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        case .beforeAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.beforeAllocatedSize, rhs.beforeAllocatedSize)
        case .afterAllocatedSize:
            FileNodeSortComparison.compareOptional(lhs.afterAllocatedSize, rhs.afterAllocatedSize)
        case .allocatedDelta:
            FileNodeSortComparison.compare(lhs.allocatedDelta, rhs.allocatedDelta)
        case .absoluteAllocatedDelta:
            FileNodeSortComparison.compare(lhs.absoluteAllocatedDelta, rhs.absoluteAllocatedDelta)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        }

        return FileNodeSortComparison.applying(order, to: result)
    }

    static func sortsBefore(
        _ lhs: ScanComparisonRow,
        _ rhs: ScanComparisonRow,
        using comparators: [ScanComparisonRowComparator]
    ) -> Bool {
        for comparator in comparators {
            switch comparator.compare(lhs, rhs) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                continue
            @unknown default:
                continue
            }
        }
        return FileNodeSortComparison.fallback(
            lhsName: lhs.name,
            lhsID: lhs.relativePath,
            rhsName: rhs.name,
            rhsID: rhs.relativePath
        ) == .orderedAscending
    }
}

/// Filters and orders comparison evidence for table presentation.
nonisolated struct ScanComparisonRowQuery: Equatable, Sendable {
    let changeKinds: Set<ScanComparisonChangeKind>
    let searchText: String
    let sortOrder: [ScanComparisonRowComparator]
    /// Limits evidence to one top-level contributor while retaining its full descendant rows.
    let pathPrefix: String?

    init(
        changeKinds: Set<ScanComparisonChangeKind> = Set(ScanComparisonChangeKind.allCases),
        searchText: String,
        sortOrder: [ScanComparisonRowComparator],
        pathPrefix: String? = nil
    ) {
        self.changeKinds = changeKinds
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.pathPrefix = pathPrefix
    }

    var hasSearchText: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applying(
        to rows: [ScanComparisonRow],
        searchIndex: ScanComparisonSearchIndex? = nil,
        cancellationCheck: CancellationCheck
    ) throws -> [ScanComparisonRow] {
        try cancellationCheck()
        let query = SearchNormalizer.normalize(
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var filteredRows: [ScanComparisonRow] = []
        filteredRows.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard changeKinds.contains(row.kind) else { continue }
            if let pathPrefix, !pathPrefix.isEmpty {
                guard row.relativePath == pathPrefix || row.relativePath.hasPrefix(pathPrefix + "/") else {
                    continue
                }
            }
            guard !query.isEmpty else {
                filteredRows.append(row)
                continue
            }
            if let searchIndex {
                if searchIndex.row(row, matches: query) {
                    filteredRows.append(row)
                }
                continue
            }
            if SearchNormalizer.normalize(row.name).contains(query)
                || SearchNormalizer.normalize(row.relativePath).contains(query) {
                filteredRows.append(row)
            }
        }

        try cancellationCheck()
        guard !sortOrder.isEmpty else { return filteredRows }
        let sortedRows = try ScanComparisonRowComparator.sorted(
            filteredRows, using: sortOrder,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return sortedRows
    }
}
