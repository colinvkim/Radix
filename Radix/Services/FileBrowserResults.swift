//
//  FileBrowserResults.swift
//  Radix
//

import Foundation

enum FileBrowserResults {
    nonisolated static func visibleNodes(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?
    ) -> [FileNodeRecord] {
        visibleNodes(
            nodes,
            hiddenNodeIDs: hiddenNodeIDs,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func visibleNodes(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        guard !hiddenNodeIDs.isEmpty,
              let fileTreeStore else {
            try cancellationCheck()
            return nodes
        }

        let hiddenNodes = fileTreeStore.preparedNodeSet(for: hiddenNodeIDs)
        var visibleNodes: [FileNodeRecord] = []
        visibleNodes.reserveCapacity(nodes.count)

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if !fileTreeStore.isNodeOrDescendant(node.id, of: hiddenNodes) {
                visibleNodes.append(node)
            }
        }
        try cancellationCheck()
        return visibleNodes
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        filteredAndSortedCurrentContents(
            nodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func filteredAndSortedCurrentContents(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        guard query.isActive else {
            try cancellationCheck()
            return try sorted(
                nodes,
                sortOrder: sortOrder,
                fileTreeStore: fileTreeStore,
                cancellationCheck: cancellationCheck
            )
        }

        let preparedQuery = query.prepared()
        var filteredNodes: [FileNodeRecord] = []
        filteredNodes.reserveCapacity(min(nodes.count, 256))

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }

            if preparedQuery.matches(node) {
                filteredNodes.append(node)
            }
        }

        try cancellationCheck()
        return try sorted(
            filteredNodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil
    ) -> [FileNodeRecord] {
        sorted(
            nodes,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: {}
        )
    }

    nonisolated static func sorted(
        _ nodes: [FileNodeRecord],
        sortOrder: [FileNodeTableComparator],
        fileTreeStore: FileTreeStore? = nil,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FileNodeRecord] {
        try cancellationCheck()
        guard !sortOrder.isEmpty else { return nodes }

        let preparesItemKind = sortOrder.contains { $0.field == .itemKind }
        let preparesDescendantFileCount = sortOrder.contains { $0.field == .descendantFileCount }
        var indices: [Int] = []
        indices.reserveCapacity(nodes.count)
        var keys = PreparedSortKeys()
        if preparesItemKind {
            keys.itemKinds.reserveCapacity(nodes.count)
        }
        if preparesDescendantFileCount {
            keys.descendantFileCounts.reserveCapacity(nodes.count)
        }

        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            indices.append(offset)
            if preparesItemKind {
                keys.itemKinds.append(node.itemKind)
            }
            if preparesDescendantFileCount {
                keys.descendantFileCounts.append(
                    FileBrowserPackageContents.areHidden(for: node, fileTreeStore: fileTreeStore)
                        ? 0
                        : node.descendantFileCount
                )
            }
        }
        try cancellationCheck()

        // Keep records and prepared keys in input order; only offsets move through sort buffers.
        let sortedIndices = try CancellableSort.sorted(
            &indices,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            keys.isOrderedBefore(lhs, rhs, in: nodes, using: sortOrder)
        }
        try cancellationCheck()
        var result: [FileNodeRecord] = []
        result.reserveCapacity(sortedIndices.count)
        var start = 0
        while start < sortedIndices.count {
            let end = min(start + 256, sortedIndices.count)
            while start < end {
                result.append(nodes[sortedIndices[start]])
                start += 1
            }
            try cancellationCheck()
        }
        return result
    }

    private struct PreparedSortKeys {
        var itemKinds: [String] = []
        var descendantFileCounts: [Int] = []

        nonisolated func compare(
            _ lhs: Int,
            _ rhs: Int,
            in nodes: [FileNodeRecord],
            using comparator: FileNodeTableComparator
        ) -> ComparisonResult {
            let result: ComparisonResult = switch comparator.field {
            case .name:
                nodes[lhs].name.localizedStandardCompare(nodes[rhs].name)
            case .allocatedSize:
                FileNodeSortComparison.compare(nodes[lhs].allocatedSize, nodes[rhs].allocatedSize)
            case .itemKind:
                itemKinds[lhs].localizedStandardCompare(itemKinds[rhs])
            case .descendantFileCount:
                FileNodeSortComparison.compare(descendantFileCounts[lhs], descendantFileCounts[rhs])
            case .lastModified:
                FileNodeSortComparison.compareOptional(nodes[lhs].lastModified, nodes[rhs].lastModified)
            }

            return FileNodeSortComparison.applying(comparator.order, to: result)
        }

        nonisolated func isOrderedBefore(
            _ lhs: Int,
            _ rhs: Int,
            in nodes: [FileNodeRecord],
            using sortOrder: [FileNodeTableComparator]
        ) -> Bool {
            for comparator in sortOrder {
                switch compare(lhs, rhs, in: nodes, using: comparator) {
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
                lhsName: nodes[lhs].name,
                lhsID: nodes[lhs].id,
                rhsName: nodes[rhs].name,
                rhsID: nodes[rhs].id
            ) == .orderedAscending
        }
    }
}
