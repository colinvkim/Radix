import Foundation

/// A compact graph of aggregate comparison paths. The service stores the graph rather than a
/// recursive value tree so huge comparisons don't duplicate nested arrays for every UI facet.
nonisolated struct ScanComparisonChangeTree: Equatable, Sendable {
    let rootPaths: [String]
    let nodesByPath: [String: ScanComparisonAggregateChange]

    static let empty = ScanComparisonChangeTree(rootPaths: [], nodesByPath: [:])

    func node(at relativePath: String) -> ScanComparisonAggregateChange? {
        nodesByPath[relativePath]
    }

    func significantProjection(
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double = 0.95,
        maximumNamedChildren: Int = 12
    ) -> ScanComparisonChangeTreeProjection {
        significantProjection(
            changeKinds: changeKinds, coverageTarget: coverageTarget,
            maximumNamedChildren: maximumNamedChildren, cancellationCheck: {}
        )
    }

    func significantProjection(
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double = 0.95,
        maximumNamedChildren: Int = 12,
        cancellationCheck: () throws -> Void
    ) rethrows -> ScanComparisonChangeTreeProjection {
        try cancellationCheck()
        let target = min(max(coverageTarget, 0), 1)
        let maximum = max(1, maximumNamedChildren)
        let rootSelection = try significantSelection(
            from: rootPaths,
            changeKinds: changeKinds,
            coverageTarget: target,
            maximumNamedChildren: maximum,
            cancellationCheck: cancellationCheck
        )
        let roots = try projectedNodes(
            selectedPaths: rootSelection.selected,
            hiddenPaths: rootSelection.hidden,
            parentPath: nil,
            changeKinds: changeKinds,
            coverageTarget: target,
            maximumNamedChildren: maximum,
            cancellationCheck: cancellationCheck
        )

        return ScanComparisonChangeTreeProjection(
            roots: roots,
            changeKinds: changeKinds,
            namedRootCount: rootSelection.selected.count,
            hiddenRootCount: rootSelection.hidden.count,
            representedImpact: rootSelection.representedImpact,
            totalImpact: rootSelection.totalImpact,
            groupedAffectedCount: roots.reduce(0) { partialResult, node in
                partialResult + node.groupedAffectedCount
            }
        )
    }

    private func projectedNodes(
        selectedPaths: [String],
        hiddenPaths: [String],
        parentPath: String?,
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double,
        maximumNamedChildren: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [ScanComparisonChangeTreeNode] {
        var projected = try selectedPaths.compactMap { path -> ScanComparisonChangeTreeNode? in
            try cancellationCheck()
            guard let aggregate = nodesByPath[path] else { return nil }
            let selection = try significantSelection(
                from: aggregate.childPaths,
                changeKinds: changeKinds,
                coverageTarget: coverageTarget,
                maximumNamedChildren: maximumNamedChildren,
                cancellationCheck: cancellationCheck
            )
            let children = try projectedNodes(
                selectedPaths: selection.selected,
                hiddenPaths: selection.hidden,
                parentPath: path,
                changeKinds: changeKinds,
                coverageTarget: coverageTarget,
                maximumNamedChildren: maximumNamedChildren,
                cancellationCheck: cancellationCheck
            )
            return ScanComparisonChangeTreeNode(
                aggregate: aggregate,
                changeKinds: changeKinds,
                children: children
            )
        }

        if !hiddenPaths.isEmpty {
            projected.append(try ScanComparisonChangeTreeNode.remainder(
                parentPath: parentPath,
                changeKinds: changeKinds,
                hiddenNodes: hiddenPaths.lazy.compactMap { nodesByPath[$0] },
                cancellationCheck: cancellationCheck
            ))
        }
        return projected
    }

    private func significantSelection(
        from paths: [String],
        changeKinds: Set<ScanComparisonChangeKind>,
        coverageTarget: Double,
        maximumNamedChildren: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> SignificantSelection {
        var eligible: [ScanComparisonAggregateChange] = []
        for (offset, path) in paths.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            guard let node = nodesByPath[path], node.includes(any: changeKinds) else { continue }
            eligible.append(node)
        }
        guard !eligible.isEmpty else {
            return SignificantSelection(selected: [], hidden: [], representedImpact: 0, totalImpact: 0)
        }

        var selectedIDs = Set<String>()
        for kind in changeKinds {
            var selectedForKind = try selectForCoverage(
                eligible,
                value: { $0.impact(for: kind) },
                coverageTarget: coverageTarget,
                maximumCount: maximumNamedChildren,
                cancellationCheck: cancellationCheck
            )
            if selectedForKind.isEmpty {
                selectedForKind = try selectForCoverage(
                    eligible,
                    value: { Int64($0.changeCount(for: kind)) },
                    coverageTarget: coverageTarget,
                    maximumCount: maximumNamedChildren,
                    cancellationCheck: cancellationCheck
                )
            }
            selectedIDs.formUnion(selectedForKind)
        }

        var selectedEntries: [RankedSignificantNode] = []
        var hidden: [String] = []
        let selectedCapacity = min(selectedIDs.count, eligible.count)
        selectedEntries.reserveCapacity(selectedCapacity)
        hidden.reserveCapacity(eligible.count - selectedCapacity)
        var totalImpact: Int64 = 0
        var representedImpact: Int64 = 0
        var totalChangeCount: Int64 = 0
        var representedChangeCount: Int64 = 0
        for (offset, node) in eligible.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            let entry = RankedSignificantNode(
                node: node,
                impact: node.impact(for: changeKinds),
                changeCount: Int64(changeKinds.reduce(0) { $0 + node.changeCount(for: $1) })
            )
            let isSelected = selectedIDs.contains(entry.node.id)
            if isSelected {
                selectedEntries.append(entry)
            } else {
                hidden.append(entry.node.relativePath)
            }
            totalImpact = ScanComparisonIntegerMath.addingClamped(totalImpact, entry.impact)
            totalChangeCount = ScanComparisonIntegerMath.addingClamped(
                totalChangeCount,
                entry.changeCount
            )
            if isSelected {
                representedImpact = ScanComparisonIntegerMath.addingClamped(
                    representedImpact,
                    entry.impact
                )
                representedChangeCount = ScanComparisonIntegerMath.addingClamped(
                    representedChangeCount,
                    entry.changeCount
                )
            }
        }
        if totalImpact == 0 {
            totalImpact = totalChangeCount
            representedImpact = representedChangeCount
        }
        let sortedEntries = try CancellableSort.sorted(
            &selectedEntries, cancellationCheck: cancellationCheck, by: ranksBefore
        )
        return SignificantSelection(
            selected: try sortedEntries.map {
                try cancellationCheck()
                return $0.node.relativePath
            },
            hidden: hidden,
            representedImpact: representedImpact,
            totalImpact: totalImpact
        )
    }

    private func selectForCoverage(
        _ nodes: [ScanComparisonAggregateChange],
        value: (ScanComparisonAggregateChange) -> Int64,
        coverageTarget: Double,
        maximumCount: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> Set<String> {
        guard maximumCount > 0 else { return [] }

        var total = Double(0)
        var leading: [CoverageCandidate] = []
        leading.reserveCapacity(min(maximumCount, nodes.count))
        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            let nodeValue = value(node)
            guard nodeValue > 0 else { continue }
            total += Double(nodeValue)
            let candidate = CoverageCandidate(node: node, value: nodeValue)
            let insertionIndex = leading.firstIndex { coverageRanksBefore(candidate, $0) }
                ?? leading.endIndex
            if leading.count < maximumCount {
                leading.insert(candidate, at: insertionIndex)
            } else if insertionIndex < leading.endIndex {
                leading.insert(candidate, at: insertionIndex)
                leading.removeLast()
            }
        }
        guard total > 0 else { return [] }
        let target = total * coverageTarget
        var represented = Double(0)
        var selected = Set<String>()
        for entry in leading {
            try cancellationCheck()
            guard represented < target else { break }
            selected.insert(entry.node.id)
            represented += Double(entry.value)
        }
        return selected
    }

    private func ranksBefore(_ lhs: RankedSignificantNode, _ rhs: RankedSignificantNode) -> Bool {
        if lhs.impact != rhs.impact { return lhs.impact > rhs.impact }
        if lhs.node.grossChangedAllocatedSize != rhs.node.grossChangedAllocatedSize {
            return lhs.node.grossChangedAllocatedSize > rhs.node.grossChangedAllocatedSize
        }
        return lhs.node.relativePath.localizedStandardCompare(rhs.node.relativePath) == .orderedAscending
    }

    private func coverageRanksBefore(_ lhs: CoverageCandidate, _ rhs: CoverageCandidate) -> Bool {
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.node.relativePath.localizedStandardCompare(rhs.node.relativePath) == .orderedAscending
    }

    private struct RankedSignificantNode {
        let node: ScanComparisonAggregateChange
        let impact: Int64
        let changeCount: Int64
    }

    private struct CoverageCandidate {
        let node: ScanComparisonAggregateChange
        let value: Int64
    }

    private struct SignificantSelection {
        let selected: [String]
        let hidden: [String]
        let representedImpact: Int64
        let totalImpact: Int64
    }
}

/// A small recursive projection intended for the Significant UI. Hidden siblings are represented
/// by one synthetic remainder instead of retaining thousands of invisible descendants.
nonisolated struct ScanComparisonChangeTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let allocatedDelta: Int64
    let affectedCount: Int
    let movedCount: Int
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let directChangeKind: ScanComparisonChangeKind?
    let isDirectory: Bool
    let isRemainder: Bool
    let groupedAffectedCount: Int
    let children: [ScanComparisonChangeTreeNode]?

    init(
        aggregate: ScanComparisonAggregateChange,
        changeKinds: Set<ScanComparisonChangeKind>,
        children: [ScanComparisonChangeTreeNode]
    ) {
        let increasedAllocatedSize = aggregate.increasedAllocatedSize(for: changeKinds)
        let reclaimedAllocatedSize = aggregate.reclaimedAllocatedSize(for: changeKinds)
        self.id = aggregate.id
        self.relativePath = aggregate.relativePath
        self.name = aggregate.name
        self.increasedAllocatedSize = increasedAllocatedSize
        self.reclaimedAllocatedSize = reclaimedAllocatedSize
        self.allocatedDelta = increasedAllocatedSize - reclaimedAllocatedSize
        self.affectedCount = changeKinds.reduce(0) { $0 + aggregate.changeCount(for: $1) }
        self.movedCount = changeKinds.contains(.moved) ? aggregate.movedCount : 0
        self.beforeNode = aggregate.beforeNode
        self.afterNode = aggregate.afterNode
        self.directChangeKind = aggregate.directChangeKind
        self.isDirectory = aggregate.isDirectory
        self.isRemainder = false
        self.groupedAffectedCount = children.reduce(0) { $0 + $1.groupedAffectedCount }
        self.children = children.isEmpty ? nil : children
    }

    private init(
        id: String,
        relativePath: String,
        name: String,
        increasedAllocatedSize: Int64,
        reclaimedAllocatedSize: Int64,
        affectedCount: Int,
        movedCount: Int,
        groupedAffectedCount: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.name = name
        self.increasedAllocatedSize = increasedAllocatedSize
        self.reclaimedAllocatedSize = reclaimedAllocatedSize
        self.allocatedDelta = increasedAllocatedSize - reclaimedAllocatedSize
        self.affectedCount = affectedCount
        self.movedCount = movedCount
        self.beforeNode = nil
        self.afterNode = nil
        self.directChangeKind = nil
        self.isDirectory = false
        self.isRemainder = true
        self.groupedAffectedCount = groupedAffectedCount
        self.children = nil
    }

    static func remainder(
        parentPath: String?,
        changeKinds: Set<ScanComparisonChangeKind>,
        hiddenNodes: some Sequence<ScanComparisonAggregateChange>,
        cancellationCheck: () throws -> Void
    ) rethrows -> ScanComparisonChangeTreeNode {
        var affectedCount = 0
        var increasedAllocatedSize: Int64 = 0
        var reclaimedAllocatedSize: Int64 = 0
        var movedCount = 0
        let includesMoved = changeKinds.contains(.moved)
        for (offset, node) in hiddenNodes.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            for kind in changeKinds {
                affectedCount += node.changeCount(for: kind)
                increasedAllocatedSize = ScanComparisonIntegerMath.addingClamped(
                    increasedAllocatedSize,
                    node.increasedAllocatedSizeByKind[kind, default: 0]
                )
                reclaimedAllocatedSize = ScanComparisonIntegerMath.addingClamped(
                    reclaimedAllocatedSize,
                    node.reclaimedAllocatedSizeByKind[kind, default: 0]
                )
            }
            if includesMoved {
                movedCount += node.movedCount
            }
        }
        let filterID = changeKinds.map(\.rawValue).sorted().joined(separator: ",")
        return ScanComparisonChangeTreeNode(
            id: "other:\(parentPath ?? "root"):\(filterID)",
            relativePath: parentPath ?? "",
            name: "Other smaller changes",
            increasedAllocatedSize: increasedAllocatedSize,
            reclaimedAllocatedSize: reclaimedAllocatedSize,
            affectedCount: affectedCount,
            movedCount: movedCount,
            groupedAffectedCount: affectedCount
        )
    }

    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }

    func node(withID id: String) -> ScanComparisonChangeTreeNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let match = child.node(withID: id) { return match }
        }
        return nil
    }
}

nonisolated struct ScanComparisonChangeTreeProjection: Equatable, Sendable {
    let roots: [ScanComparisonChangeTreeNode]
    let changeKinds: Set<ScanComparisonChangeKind>
    let namedRootCount: Int
    let hiddenRootCount: Int
    let representedImpact: Int64
    let totalImpact: Int64
    let groupedAffectedCount: Int

    var representedFraction: Double {
        guard totalImpact > 0 else { return 1 }
        return Double(representedImpact) / Double(totalImpact)
    }

    func node(withID id: String) -> ScanComparisonChangeTreeNode? {
        for root in roots {
            if let match = root.node(withID: id) { return match }
        }
        return nil
    }
}
