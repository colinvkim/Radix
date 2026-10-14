import Foundation

struct FileNodeTableComparator: Equatable, SortComparator, Sendable {
    enum Field: Equatable, Sendable {
        case name
        case allocatedSize
        case itemKind
        case descendantFileCount
        case lastModified
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> ComparisonResult {
        compare(lhs, rhs, fileTreeStore: nil)
    }

    func compare(
        _ lhs: FileNodeRecord,
        _ rhs: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> ComparisonResult {
        let result: ComparisonResult = switch field {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .allocatedSize:
            FileNodeSortComparison.compare(lhs.allocatedSize, rhs.allocatedSize)
        case .itemKind:
            lhs.itemKind.localizedStandardCompare(rhs.itemKind)
        case .descendantFileCount:
            FileNodeSortComparison.compare(
                displayedDescendantFileCount(for: lhs, fileTreeStore: fileTreeStore),
                displayedDescendantFileCount(for: rhs, fileTreeStore: fileTreeStore)
            )
        case .lastModified:
            FileNodeSortComparison.compareOptional(lhs.lastModified, rhs.lastModified)
        }

        return FileNodeSortComparison.applying(order, to: result)
    }

    private func displayedDescendantFileCount(
        for node: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> Int {
        FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
            ? 0
            : node.descendantFileCount
    }
}

enum FileNodeSortComparison {
    nonisolated static func applying(_ order: SortOrder, to result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }

        return switch result {
        case .orderedAscending:
            .orderedDescending
        case .orderedDescending:
            .orderedAscending
        case .orderedSame:
            .orderedSame
        @unknown default:
            result
        }
    }

    nonisolated static func fallback(
        lhsName: String,
        lhsID: String,
        rhsName: String,
        rhsID: String
    ) -> ComparisonResult {
        let nameResult = lhsName.localizedStandardCompare(rhsName)
        switch nameResult {
        case .orderedSame:
            return lhsID.localizedStandardCompare(rhsID)
        default:
            return nameResult
        }
    }

    nonisolated static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }

    nonisolated static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return compare(lhs, rhs)
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedAscending
        case (_?, nil):
            return .orderedDescending
        }
    }
}
