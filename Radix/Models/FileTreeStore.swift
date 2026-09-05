//
//  FileTreeStore.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated struct FileTreeNodeIndex: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt32
}

nonisolated struct PreparedFileTreeNodeSet: Sendable {
    fileprivate let indices: Set<FileTreeNodeIndex>
}

nonisolated struct FileTreeChildSpan: Sendable {
    var start: UInt32 = 0
    var count: UInt32 = 0
}

nonisolated private struct FileTreeTopologyArena: Sendable {
    private static let noParent = UInt32.max

    let rootIndex: FileTreeNodeIndex
    let indexByNodeID: [String: FileTreeNodeIndex]
    let parentRawIndices: [UInt32]
    let childSpans: [FileTreeChildSpan]
    let childIndices: [FileTreeNodeIndex]
    let orderedNodeIndices: [FileTreeNodeIndex]

    init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        orderedNodeIDs: [String]
    ) {
        precondition(orderedNodeIDs.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(orderedNodeIDs.count)
        for (offset, nodeID) in orderedNodeIDs.enumerated() {
            precondition(nodesByID[nodeID] != nil, "FileTreeStore order references a missing node.")
            indexByNodeID[nodeID] = FileTreeNodeIndex(rawValue: UInt32(offset))
        }
        guard let rootIndex = indexByNodeID[rootID] else {
            preconditionFailure("FileTreeStore root is missing from its node order.")
        }

        var parentRawIndices = Array(repeating: Self.noParent, count: orderedNodeIDs.count)
        var childSpans = Array(repeating: FileTreeChildSpan(), count: orderedNodeIDs.count)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(max(orderedNodeIDs.count - 1, 0))
        for parentID in orderedNodeIDs {
            guard let parentIndex = indexByNodeID[parentID],
                  let childIDs = childIDsByID[parentID],
                  !childIDs.isEmpty else {
                continue
            }
            let start = childIndices.count
            for childID in childIDs {
                guard let childIndex = indexByNodeID[childID] else { continue }
                childIndices.append(childIndex)
                parentRawIndices[Int(childIndex.rawValue)] = parentIndex.rawValue
            }
            childSpans[Int(parentIndex.rawValue)] = FileTreeChildSpan(
                start: UInt32(start),
                count: UInt32(childIndices.count - start)
            )
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIDs.compactMap { indexByNodeID[$0] }
    }

    init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        childIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        precondition(nodes.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        precondition(childIndicesByIndex.count == nodes.count, "Verified child topology count does not match nodes.")
        precondition(parentIndices.count == nodes.count, "Verified parent topology count does not match nodes.")
        precondition(Int(rootIndex.rawValue) < nodes.count, "Verified root index is out of range.")

        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(nodes.count)
        for (offset, node) in nodes.enumerated() {
            let previous = indexByNodeID.updateValue(
                FileTreeNodeIndex(rawValue: UInt32(offset)),
                forKey: node.id
            )
            precondition(previous == nil, "Verified FileTreeStore contains duplicate node IDs.")
        }

        var parentRawIndices = Array(repeating: Self.noParent, count: nodes.count)
        for (offset, parentIndex) in parentIndices.enumerated() {
            guard let parentIndex else { continue }
            precondition(Int(parentIndex.rawValue) < nodes.count, "Verified parent index is out of range.")
            parentRawIndices[offset] = parentIndex.rawValue
        }

        var childSpans = Array(repeating: FileTreeChildSpan(), count: nodes.count)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(max(nodes.count - 1, 0))
        for (offset, children) in childIndicesByIndex.enumerated() {
            let start = childIndices.count
            for childIndex in children {
                precondition(Int(childIndex.rawValue) < nodes.count, "Verified child index is out of range.")
                childIndices.append(childIndex)
            }
            childSpans[offset] = FileTreeChildSpan(
                start: UInt32(start),
                count: UInt32(childIndices.count - start)
            )
        }
        for index in orderedNodeIndices {
            precondition(Int(index.rawValue) < nodes.count, "Verified node order index is out of range.")
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID verifiedIndexByNodeID: [String: FileTreeNodeIndex]? = nil,
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        precondition(nodes.count <= Int(UInt32.max), "FileTreeStore exceeds its node-index capacity.")
        precondition(parentRawIndices.count == nodes.count, "Verified parent topology count does not match nodes.")
        precondition(childSpans.count == nodes.count, "Verified child topology count does not match nodes.")
        precondition(Int(rootIndex.rawValue) < nodes.count, "Verified root index is out of range.")
        precondition(orderedNodeIndices.count == nodes.count, "Verified node order count does not match nodes.")
        precondition(childIndices.count == max(nodes.count - 1, 0), "Verified child index count does not match nodes.")

        let indexByNodeID: [String: FileTreeNodeIndex]
        if let verifiedIndexByNodeID {
            precondition(verifiedIndexByNodeID.count == nodes.count, "Verified node index count does not match nodes.")
            indexByNodeID = verifiedIndexByNodeID
        } else {
            var rebuiltIndexByNodeID: [String: FileTreeNodeIndex] = [:]
            rebuiltIndexByNodeID.reserveCapacity(nodes.count)
            for (offset, node) in nodes.enumerated() {
                let previous = rebuiltIndexByNodeID.updateValue(
                    FileTreeNodeIndex(rawValue: UInt32(offset)),
                    forKey: node.id
                )
                precondition(previous == nil, "Verified FileTreeStore contains duplicate node IDs.")
            }
            indexByNodeID = rebuiltIndexByNodeID
        }

        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    private init(
        rootIndex: FileTreeNodeIndex,
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        self.rootIndex = rootIndex
        self.indexByNodeID = indexByNodeID
        self.parentRawIndices = parentRawIndices
        self.childSpans = childSpans
        self.childIndices = childIndices
        self.orderedNodeIndices = orderedNodeIndices
    }

    func parentIndex(of index: FileTreeNodeIndex) -> FileTreeNodeIndex? {
        guard Int(index.rawValue) < parentRawIndices.count else { return nil }
        let rawValue = parentRawIndices[Int(index.rawValue)]
        return rawValue == Self.noParent ? nil : FileTreeNodeIndex(rawValue: rawValue)
    }

    func children(of index: FileTreeNodeIndex) -> ArraySlice<FileTreeNodeIndex> {
        guard Int(index.rawValue) < childSpans.count else { return [] }
        let span = childSpans[Int(index.rawValue)]
        let start = Int(span.start)
        return childIndices[start..<(start + Int(span.count))]
    }

    func reorderingChildren(
        of parentIndex: FileTreeNodeIndex,
        to reorderedChildren: [FileTreeNodeIndex]
    ) -> FileTreeTopologyArena? {
        let existingChildren = children(of: parentIndex)
        guard existingChildren.count == reorderedChildren.count,
              Set(existingChildren).count == existingChildren.count,
              Set(existingChildren) == Set(reorderedChildren) else {
            return nil
        }
        guard !existingChildren.elementsEqual(reorderedChildren) else { return self }

        let span = childSpans[Int(parentIndex.rawValue)]
        let start = Int(span.start)
        let end = start + Int(span.count)
        var updatedChildIndices = childIndices
        updatedChildIndices.replaceSubrange(start..<end, with: reorderedChildren)
        let updatedOrder = Self.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            capacity: orderedNodeIndices.count,
            cancellationCheck: {}
        )
        guard updatedOrder.count == orderedNodeIndices.count else { return nil }

        return FileTreeTopologyArena(
            rootIndex: rootIndex,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            orderedNodeIndices: updatedOrder
        )
    }

    func replacingChildIndices(
        _ updatedChildIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeTopologyArena {
        precondition(updatedChildIndices.count == childIndices.count)
        let updatedOrder = try Self.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            capacity: orderedNodeIndices.count,
            cancellationCheck: cancellationCheck
        )
        precondition(updatedOrder.count == orderedNodeIndices.count)
        return FileTreeTopologyArena(
            rootIndex: rootIndex,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: updatedChildIndices,
            orderedNodeIndices: updatedOrder
        )
    }

    static func preorderNodeIndices(
        rootIndex: FileTreeNodeIndex,
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        capacity: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [FileTreeNodeIndex] {
        var result: [FileTreeNodeIndex] = []
        result.reserveCapacity(capacity)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            if result.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            result.append(nodeIndex)
            let span = childSpans[Int(nodeIndex.rawValue)]
            let start = Int(span.start)
            let end = start + Int(span.count)
            stack.append(contentsOf: childIndices[start..<end].reversed())
        }
        return result
    }

    static func preorderNodeIndices(
        rootIndex: FileTreeNodeIndex,
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        includedByOffset: [Bool],
        capacity: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [FileTreeNodeIndex] {
        precondition(includedByOffset.count == childSpans.count)
        guard includedByOffset[Int(rootIndex.rawValue)] else { return [] }

        var result: [FileTreeNodeIndex] = []
        result.reserveCapacity(capacity)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            try cancellationCheck()
            result.append(nodeIndex)

            let span = childSpans[Int(nodeIndex.rawValue)]
            let start = Int(span.start)
            let end = start + Int(span.count)
            for (offset, childIndex) in childIndices[start..<end].reversed().enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                if includedByOffset[Int(childIndex.rawValue)] {
                    stack.append(childIndex)
                }
            }
        }
        return result
    }

    func preorderNodeIndices(
        includedByOffset: [Bool],
        capacity: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [FileTreeNodeIndex] {
        try Self.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: childIndices,
            includedByOffset: includedByOffset,
            capacity: capacity,
            cancellationCheck: cancellationCheck
        )
    }
}

nonisolated struct FileTreeStore: Sendable {
    nonisolated struct SubtreeSource: Sendable {
        let root: FileNodeRecord
        fileprivate let store: FileTreeStore?

        nonisolated init(node: FileNodeRecord) {
            self.root = node
            self.store = nil
        }

        nonisolated init?(
            store: FileTreeStore,
            rootedAt nodeID: String
        ) {
            guard let root = store.node(id: nodeID) else { return nil }
            self.root = root
            self.store = store
        }
    }

    private struct NodeMembership: Sendable {
        private var words: [UInt64]

        init(nodeCapacity: Int) {
            words = Array(repeating: 0, count: (nodeCapacity + 63) / 64)
        }

        @discardableResult
        mutating func insert(_ index: FileTreeNodeIndex) -> Bool {
            let offset = Int(index.rawValue)
            let wordIndex = offset >> 6
            let mask = UInt64(1) << UInt64(offset & 63)
            let inserted = words[wordIndex] & mask == 0
            words[wordIndex] |= mask
            return inserted
        }

        func contains(_ index: FileTreeNodeIndex) -> Bool {
            let offset = Int(index.rawValue)
            guard offset >= 0, offset >> 6 < words.count else { return false }
            return words[offset >> 6] & (UInt64(1) << UInt64(offset & 63)) != 0
        }
    }

    private struct LogicalScope: Sendable {
        let rootIndex: FileTreeNodeIndex
        let membership: NodeMembership
        let orderedNodeIndices: [FileTreeNodeIndex]
        let aggregateStats: ScanAggregateStats
        let replacementRecords: [FileTreeNodeIndex: FileNodeRecord]
        let reorderedChildren: [FileTreeNodeIndex: [FileTreeNodeIndex]]
    }

    private enum ChildIndexCollection: RandomAccessCollection, Sendable {
        typealias Index = Int

        case backing(ArraySlice<FileTreeNodeIndex>)
        case replacement([FileTreeNodeIndex])

        var startIndex: Int { 0 }

        var endIndex: Int {
            switch self {
            case .backing(let indices): indices.count
            case .replacement(let indices): indices.count
            }
        }

        subscript(position: Int) -> FileTreeNodeIndex {
            switch self {
            case .backing(let indices):
                indices[indices.index(indices.startIndex, offsetBy: position)]
            case .replacement(let indices):
                indices[position]
            }
        }
    }

    let contentID: UUID
    /// Shared by logical scopes that retain the same full node and topology buffers.
    let backingStorageID: UUID
    let rootID: String
    private let nodeRecords: [FileNodeRecord]
    private let topologyArena: FileTreeTopologyArena
    private let precomputedAggregateStats: ScanAggregateStats?
    private let logicalScope: LogicalScope?

    private nonisolated var activeRootIndex: FileTreeNodeIndex {
        logicalScope?.rootIndex ?? topologyArena.rootIndex
    }

    private nonisolated var activeOrderedNodeIndices: [FileTreeNodeIndex] {
        logicalScope?.orderedNodeIndices ?? topologyArena.orderedNodeIndices
    }

    private nonisolated func contains(_ index: FileTreeNodeIndex) -> Bool {
        guard let logicalScope else {
            return nodeRecords.indices.contains(Int(index.rawValue))
        }
        return logicalScope.membership.contains(index)
    }

    private nonisolated func activeChildren(
        of index: FileTreeNodeIndex
    ) -> ChildIndexCollection {
        guard let logicalScope else {
            guard nodeRecords.indices.contains(Int(index.rawValue)) else {
                return .replacement([])
            }
            return .backing(topologyArena.children(of: index))
        }
        guard logicalScope.membership.contains(index) else {
            return .replacement([])
        }
        if let children = logicalScope.reorderedChildren[index] {
            return .replacement(children)
        }
        return .backing(topologyArena.children(of: index))
    }

    private nonisolated func activeParentIndex(
        of index: FileTreeNodeIndex
    ) -> FileTreeNodeIndex? {
        guard let logicalScope else {
            guard nodeRecords.indices.contains(Int(index.rawValue)),
                  index != topologyArena.rootIndex else {
                return nil
            }
            return topologyArena.parentIndex(of: index)
        }
        guard logicalScope.membership.contains(index),
              index != logicalScope.rootIndex,
              let parentIndex = topologyArena.parentIndex(of: index),
              logicalScope.membership.contains(parentIndex) else {
            return nil
        }
        return parentIndex
    }

    nonisolated var nodesByID: [String: FileNodeRecord] {
        var result: [String: FileNodeRecord] = [:]
        result.reserveCapacity(nodeCount)
        for index in activeOrderedNodeIndices {
            guard let node = node(at: index) else { continue }
            precondition(
                result.updateValue(node, forKey: node.id) == nil,
                "FileTreeStore contains duplicate node IDs"
            )
        }
        return result
    }

    nonisolated var childIDsByID: [String: [String]] {
        var result: [String: [String]] = [:]
        for parentIndex in activeOrderedNodeIndices {
            let children = activeChildren(of: parentIndex)
            guard !children.isEmpty,
                  let parent = self.node(at: parentIndex) else {
                continue
            }
            result[parent.id] = children.compactMap { node(at: $0)?.id }
        }
        return result
    }

    nonisolated var parentIDByID: [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(max(nodeCount - 1, 0))
        for nodeIndex in activeOrderedNodeIndices {
            guard let parentIndex = activeParentIndex(of: nodeIndex),
                  let record = node(at: nodeIndex),
                  let parent = node(at: parentIndex) else {
                continue
            }
            result[record.id] = parent.id
        }
        return result
    }

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let orderedNodeIDs: [String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private struct AggregateStatsAccumulator {
        private var fileCount = 0
        private var directoryCount = 0
        private var accessibleItemCount = 0
        private var inaccessibleItemCount = 0

        @inline(__always)
        mutating func include(_ node: FileNodeRecord, hasMaterializedChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if !hasMaterializedChildren && (node.isPackage || node.isAutoSummarized) {
                    fileCount = FileTreeStore.saturatingAdd(fileCount, node.descendantFileCount)
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount = FileTreeStore.saturatingAdd(fileCount, 1)
            }

            if node.isAccessible {
                accessibleItemCount = FileTreeStore.saturatingAdd(accessibleItemCount, 1)
            } else {
                inaccessibleItemCount = FileTreeStore.saturatingAdd(inaccessibleItemCount, 1)
            }
        }

        mutating func replaceAccessibility(
            from previousNode: FileNodeRecord,
            to updatedNode: FileNodeRecord
        ) {
            guard previousNode.isAccessible != updatedNode.isAccessible else { return }
            if updatedNode.isAccessible {
                accessibleItemCount += 1
                inaccessibleItemCount -= 1
            } else {
                accessibleItemCount -= 1
                inaccessibleItemCount += 1
            }
        }

        func stats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    private struct MaterializedDirectoryTotals {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true

        mutating func include(_ child: FileNodeRecord) {
            allocatedSize = FileTreeStore.saturatingAdd(allocatedSize, child.allocatedSize)
            logicalSize = FileTreeStore.saturatingAdd(logicalSize, child.logicalSize)
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount = FileTreeStore.saturatingAdd(
                    descendantFileCount,
                    child.descendantFileCount
                )
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount = FileTreeStore.saturatingAdd(descendantFileCount, 1)
            }
        }
    }

    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)
        case overlappingReplacementTargets(String, String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            case .overlappingReplacementTargets(let ancestorID, let descendantID):
                return "Batch replacements must be disjoint, but \(ancestorID) contains \(descendantID)."
            }
        }
    }

    nonisolated var root: FileNodeRecord {
        guard let root = node(at: activeRootIndex) else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var nodeCount: Int {
        logicalScope?.orderedNodeIndices.count ?? nodeRecords.count
    }

    nonisolated var backingNodeCapacity: Int {
        nodeRecords.count
    }

    /// Aggregate stats are always resolved during construction so repeated
    /// reads never re-traverse the tree.
    nonisolated var aggregateStats: ScanAggregateStats {
        if let logicalScope {
            return logicalScope.aggregateStats
        }
        guard let precomputedAggregateStats else {
            preconditionFailure("FileTreeStore aggregate stats were not resolved during construction.")
        }
        return precomputedAggregateStats
    }

    nonisolated init(root: FileNodeRecord) {
        self.init(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [:]
        )
    }

    nonisolated init(root: FileNodeRecord, childrenByID inputChildrenByID: [String: [FileNodeRecord]]) {
        var nodesByID = [root.id: root]
        var childIDsByID: [String: [String]] = [:]
        var seenNodeIDs: Set<String> = [root.id]
        var stack = [root]

        while let parent = stack.popLast() {
            guard let inputChildren = inputChildrenByID[parent.id] else { continue }
            let uniqueChildren = Self.uniqueChildren(
                inputChildren,
                seenNodeIDs: &seenNodeIDs
            )
            let children = Self.sortedChildren(uniqueChildren)
            childIDsByID[parent.id] = children.map(\.id)
            guard !children.isEmpty else { continue }

            for child in children {
                nodesByID[child.id] = child
                stack.append(child)
            }
        }

        self.init(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
    }

    nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.contentID = UUID()
        self.backingStorageID = contentID
        self.rootID = rootID
        let storedNodes = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                orderedNodeIDs: topology.orderedNodeIDs,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.nodeRecords = topology.orderedNodeIDs.compactMap { storedNodes[$0] }
        let topologyArena = FileTreeTopologyArena(
            rootID: rootID,
            nodesByID: storedNodes,
            childIDsByID: topology.childIDsByID,
            orderedNodeIDs: topology.orderedNodeIDs
        )
        self.topologyArena = topologyArena
        if let aggregateStats, !topology.didDropReferences {
            self.precomputedAggregateStats = aggregateStats
        } else {
            self.precomputedAggregateStats = Self.computedAggregateStats(
                nodeRecords: nodeRecords,
                topologyArena: topologyArena
            )
        }
        self.logicalScope = nil
    }

    private nonisolated static func computedAggregateStats(
        nodeRecords: [FileNodeRecord],
        topologyArena: FileTreeTopologyArena
    ) -> ScanAggregateStats {
        var accumulator = AggregateStatsAccumulator()

        for nodeIndex in topologyArena.orderedNodeIndices {
            let offset = Int(nodeIndex.rawValue)
            guard offset < nodeRecords.count else { continue }
            accumulator.include(
                nodeRecords[offset],
                hasMaterializedChildren: topologyArena.childSpans[offset].count > 0
            )
        }

        return accumulator.stats(
            root: nodeRecords[Int(topologyArena.rootIndex.rawValue)]
        )
    }

    /// Fast construction for scanner output whose topology has already been
    /// validated while it was assembled. This avoids copying every node and
    /// edge through the general-purpose topology sanitizer a second time.
    nonisolated init(
        verifiedRootID rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        aggregateStats: ScanAggregateStats
    ) {
        precondition(nodesByID[rootID] != nil, "Verified FileTreeStore root is missing.")
        self.contentID = UUID()
        self.backingStorageID = contentID
        self.rootID = rootID
        let orderedNodeIDs = Self.orderedNodeIDsAssumingValidTopology(
            rootID: rootID,
            childIDsByID: childIDsByID,
            nodeCount: nodesByID.count
        )
        self.topologyArena = FileTreeTopologyArena(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            orderedNodeIDs: orderedNodeIDs
        )
        self.nodeRecords = orderedNodeIDs.compactMap { nodesByID[$0] }
        self.precomputedAggregateStats = aggregateStats
        self.logicalScope = nil
        precondition(orderedNodeIDs.count == nodesByID.count, "FileTreeStore node order count does not match its node map.")
    }

    /// Fast construction for scanner output already represented by compact node indices.
    /// Node indices are stable array offsets and child lists must already be display-sorted.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        childIndicesByIndex: [[FileTreeNodeIndex]],
        parentIndices: [FileTreeNodeIndex?],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")
        self.init(
            rootID: nodes[rootOffset].id,
            nodeRecords: nodes,
            topologyArena: topologyArena,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for scanner output already assembled into the store's
    /// compact topology representation.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats,
        cancellationCheck: () throws -> Void
    ) rethrows {
        let orderedNodeIndices = try FileTreeTopologyArena.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: childIndices,
            capacity: nodes.count,
            cancellationCheck: cancellationCheck
        )
        self.init(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats
        )
    }

    private nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")
        self.init(
            rootID: nodes[rootOffset].id,
            nodeRecords: nodes,
            topologyArena: topologyArena,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for scanner output with a precomputed traversal order.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex],
        aggregateStats: ScanAggregateStats
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")
        self.init(
            rootID: nodes[rootOffset].id,
            nodeRecords: nodes,
            topologyArena: topologyArena,
            aggregateStats: aggregateStats
        )
    }

    /// Fast construction for imported compact archives whose ordinal topology
    /// and node index were validated while the records were materialized.
    nonisolated init(
        verifiedRootIndex rootIndex: FileTreeNodeIndex,
        nodes: inout [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex],
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: [FileTreeNodeIndex],
        orderedNodeIndices: [FileTreeNodeIndex]
    ) {
        let topologyArena = FileTreeTopologyArena(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices
        )
        let rootOffset = Int(rootIndex.rawValue)
        precondition(nodes.indices.contains(rootOffset), "Verified FileTreeStore root is missing.")

        var statsAccumulator = AggregateStatsAccumulator()
        for nodeIndex in orderedNodeIndices.reversed() {
            let offset = Int(nodeIndex.rawValue)
            let span = childSpans[offset]
            if span.count > 0, nodes[offset].isDirectory {
                let start = Int(span.start)
                let end = start + Int(span.count)
                nodes[offset] = Self.repairingDirectoryRecord(
                    nodes[offset],
                    childIndices: childIndices[start..<end],
                    nodes: nodes
                )
            }
            statsAccumulator.include(
                nodes[offset],
                hasMaterializedChildren: span.count > 0
            )
        }

        self.contentID = UUID()
        self.backingStorageID = contentID
        self.rootID = nodes[rootOffset].id
        self.nodeRecords = nodes
        self.topologyArena = topologyArena
        self.precomputedAggregateStats = statsAccumulator.stats(root: nodes[rootOffset])
        self.logicalScope = nil
    }

    private nonisolated init(
        rootID: String,
        nodeRecords: [FileNodeRecord],
        topologyArena: FileTreeTopologyArena,
        aggregateStats: ScanAggregateStats,
        logicalScope: LogicalScope? = nil,
        backingStorageID: UUID? = nil
    ) {
        self.contentID = UUID()
        self.backingStorageID = backingStorageID ?? contentID
        self.rootID = rootID
        self.nodeRecords = nodeRecords
        self.topologyArena = topologyArena
        self.precomputedAggregateStats = aggregateStats
        self.logicalScope = logicalScope
    }

    nonisolated static func combining(
        root: FileNodeRecord,
        childSubtrees: [SubtreeSource],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        guard !childSubtrees.isEmpty else { return FileTreeStore(root: root) }

        var nodes = [root]
        var indexByNodeID = [root.id: FileTreeNodeIndex(rawValue: 0)]
        var parentRawIndices = [UInt32.max]
        var orderedNodeIndices = [FileTreeNodeIndex(rawValue: 0)]
        var statsAccumulator = AggregateStatsAccumulator()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var sharedAllocationClaimIndices: [FileTreeNodeIndex] = []
        statsAccumulator.include(root, hasMaterializedChildren: true)
        if let claim = SharedAllocationDeduplicator.claim(for: root) {
            sharedAllocationAccumulator.record(claim)
            sharedAllocationClaimIndices.append(FileTreeNodeIndex(rawValue: 0))
        }

        typealias TraversalEntry = (
            sourceOrdinal: Int,
            sourceIndex: FileTreeNodeIndex?,
            parentRawIndex: UInt32
        )
        var stack: [TraversalEntry] = []
        stack.reserveCapacity(childSubtrees.count)
        for ordinal in childSubtrees.indices.reversed() {
            let source = childSubtrees[ordinal]
            let sourceIndex = source.store?.nodeIndex(id: source.root.id)
            stack.append((ordinal, sourceIndex, 0))
        }

        while let entry = stack.popLast() {
            if nodes.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let source = childSubtrees[entry.sourceOrdinal]
            let node: FileNodeRecord
            let children: ChildIndexCollection
            if let sourceIndex = entry.sourceIndex, let store = source.store {
                guard let storedNode = store.node(at: sourceIndex) else { continue }
                node = storedNode
                children = store.activeChildren(of: sourceIndex)
            } else {
                node = source.root
                children = .replacement([])
            }

            let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            guard indexByNodeID.updateValue(nodeIndex, forKey: node.id) == nil else {
                throw StoreError.replacementIDCollision(node.id)
            }
            nodes.append(node)
            parentRawIndices.append(entry.parentRawIndex)
            orderedNodeIndices.append(nodeIndex)
            statsAccumulator.include(node, hasMaterializedChildren: !children.isEmpty)
            if let claim = SharedAllocationDeduplicator.claim(for: node) {
                sharedAllocationAccumulator.record(claim)
                sharedAllocationClaimIndices.append(nodeIndex)
            }

            for childIndex in children.reversed() {
                stack.append((entry.sourceOrdinal, childIndex, nodeIndex.rawValue))
            }
        }

        let combinedStore = try finalizedCompactedStore(
            nodes: &nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            orderedNodeIndices: &orderedNodeIndices,
            affectedNodeIndices: [],
            statsAccumulator: &statsAccumulator,
            cancellationCheck: cancellationCheck
        )
        return try SharedAllocationDeduplicator.rebalancedStore(
            combinedStore,
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: sharedAllocationClaimIndices,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        var sortedChildren = children
        sortChildren(&sortedChildren)
        return sortedChildren
    }

    nonisolated static func sortChildren(_ children: inout [FileNodeRecord]) {
        guard children.count > 1 else { return }
        children.sort(by: areInDisplayOrder)
    }

    nonisolated static func areInDisplayOrder(
        _ lhs: FileNodeRecord,
        _ rhs: FileNodeRecord
    ) -> Bool {
        if lhs.allocatedSize == rhs.allocatedSize {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.allocatedSize > rhs.allocatedSize
    }

    private typealias DisplayOrderEntry = (
        nodeIndex: FileTreeNodeIndex,
        originalPosition: Int
    )

    private nonisolated static func precedesInDisplayOrder(
        _ lhs: DisplayOrderEntry,
        _ rhs: DisplayOrderEntry,
        nodeAt: (FileTreeNodeIndex) -> FileNodeRecord
    ) -> Bool {
        let lhsNode = nodeAt(lhs.nodeIndex)
        let rhsNode = nodeAt(rhs.nodeIndex)
        if areInDisplayOrder(lhsNode, rhsNode) {
            return true
        }
        if areInDisplayOrder(rhsNode, lhsNode) {
            return false
        }
        return lhs.originalPosition < rhs.originalPosition
    }

    private nonisolated static func cancellablySortByDisplayOrder(
        _ entries: inout [DisplayOrderEntry],
        nodeAt: (FileTreeNodeIndex) -> FileNodeRecord,
        cancellationCheck: () throws -> Void
    ) throws {
        guard entries.count > 1 else { return }

        var source = entries
        var destination = entries
        var width = 1
        while width < source.count {
            var start = 0
            while start < source.count {
                try cancellationCheck()
                let middle = min(start + width, source.count)
                let end = min(start + width + width, source.count)
                var left = start
                var right = middle
                for output in start..<end {
                    if output.isMultiple(of: 256) {
                        try cancellationCheck()
                    }
                    let takesLeft = left < middle
                        && (right >= end || !precedesInDisplayOrder(
                            source[right],
                            source[left],
                            nodeAt: nodeAt
                        ))
                    if takesLeft {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                }
                start = end
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        entries = source
    }

    private nonisolated static func restoringDisplayOrderAfterChanges<Children>(
        _ childIndices: Children,
        isChanged: (FileTreeNodeIndex) -> Bool,
        nodeAt: (FileTreeNodeIndex) -> FileNodeRecord,
        cancellationCheck: () throws -> Void
    ) throws -> [FileTreeNodeIndex]
    where Children: Collection, Children.Element == FileTreeNodeIndex {
        func copiedChildren() throws -> [FileTreeNodeIndex] {
            var result: [FileTreeNodeIndex] = []
            result.reserveCapacity(childIndices.count)
            for (offset, childIndex) in childIndices.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                result.append(childIndex)
            }
            return result
        }

        var firstChangedPosition: Int?
        var changedCount = 0
        for (position, childIndex) in childIndices.enumerated() {
            if position.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if isChanged(childIndex) {
                firstChangedPosition = firstChangedPosition ?? position
                changedCount += 1
            }
        }
        guard let firstChangedPosition else {
            return try copiedChildren()
        }
        if changedCount == 1 {
            var result = try copiedChildren()
            let changedChild = DisplayOrderEntry(
                nodeIndex: result.remove(at: firstChangedPosition),
                originalPosition: firstChangedPosition
            )
            try cancellationCheck()
            var lowerBound = 0
            var upperBound = result.count
            while lowerBound < upperBound {
                try cancellationCheck()
                let candidatePosition = lowerBound + (upperBound - lowerBound) / 2
                let originalPosition = candidatePosition < firstChangedPosition
                    ? candidatePosition
                    : candidatePosition + 1
                let candidate = DisplayOrderEntry(
                    nodeIndex: result[candidatePosition],
                    originalPosition: originalPosition
                )
                if precedesInDisplayOrder(changedChild, candidate, nodeAt: nodeAt) {
                    upperBound = candidatePosition
                } else {
                    lowerBound = candidatePosition + 1
                }
            }
            result.insert(changedChild.nodeIndex, at: lowerBound)
            try cancellationCheck()
            return result
        }

        var unchangedChildren: [DisplayOrderEntry] = []
        var changedChildren: [DisplayOrderEntry] = []
        unchangedChildren.reserveCapacity(childIndices.count - changedCount)
        changedChildren.reserveCapacity(changedCount)
        for (position, childIndex) in childIndices.enumerated() {
            if position.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let entry = (nodeIndex: childIndex, originalPosition: position)
            if isChanged(childIndex) {
                changedChildren.append(entry)
            } else {
                unchangedChildren.append(entry)
            }
        }

        try cancellablySortByDisplayOrder(
            &changedChildren,
            nodeAt: nodeAt,
            cancellationCheck: cancellationCheck
        )

        var result: [FileTreeNodeIndex] = []
        result.reserveCapacity(childIndices.count)
        var unchangedOffset = 0
        var changedOffset = 0
        while unchangedOffset < unchangedChildren.count || changedOffset < changedChildren.count {
            if result.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let takesUnchanged = unchangedOffset < unchangedChildren.count
                && (changedOffset >= changedChildren.count || !precedesInDisplayOrder(
                    changedChildren[changedOffset],
                    unchangedChildren[unchangedOffset],
                    nodeAt: nodeAt
                ))
            if takesUnchanged {
                result.append(unchangedChildren[unchangedOffset].nodeIndex)
                unchangedOffset += 1
            } else {
                result.append(changedChildren[changedOffset].nodeIndex)
                changedOffset += 1
            }
        }
        return result
    }

    private nonisolated static func uniqueChildren(
        _ children: [FileNodeRecord],
        seenNodeIDs: inout Set<String>
    ) -> [FileNodeRecord] {
        var uniqueChildren: [FileNodeRecord] = []
        uniqueChildren.reserveCapacity(children.count)

        for child in children where seenNodeIDs.insert(child.id).inserted {
            uniqueChildren.append(child)
        }

        return uniqueChildren
    }

    private nonisolated struct AffectedDirectoryRepair {
        let index: FileTreeNodeIndex
        let source: FileNodeRecord
        let repaired: FileNodeRecord
        let orderedChildren: [FileTreeNodeIndex]
        let didReorderChildren: Bool
    }

    /// Shared post-order repair pass for affected directories: restores child
    /// display order and re-derives each directory record, deepest first.
    /// Repairs become visible to later iterations through an internal overlay,
    /// mirroring how callers previously stored results mid-loop. Callers persist
    /// the returned repairs into their own storage afterwards.
    private nonisolated static func repairedAffectedDirectories(
        postorder directories: [FileTreeNodeIndex],
        isChanged: (FileTreeNodeIndex) -> Bool,
        shouldRepair: (FileTreeNodeIndex) -> Bool = { _ in true },
        baseRecordAt: (FileTreeNodeIndex) -> FileNodeRecord,
        currentChildren: (FileTreeNodeIndex) -> some Collection<FileTreeNodeIndex>,
        cancellationCheck: () throws -> Void
    ) throws -> [AffectedDirectoryRepair] {
        var appliedRepairs: [FileTreeNodeIndex: FileNodeRecord] = [:]
        func recordAt(_ nodeIndex: FileTreeNodeIndex) -> FileNodeRecord {
            appliedRepairs[nodeIndex] ?? baseRecordAt(nodeIndex)
        }

        var results: [AffectedDirectoryRepair] = []
        results.reserveCapacity(directories.count)
        for nodeIndex in directories.reversed() {
            try cancellationCheck()
            let source = recordAt(nodeIndex)
            guard source.isDirectory, shouldRepair(nodeIndex) else { continue }

            let originalChildren = currentChildren(nodeIndex)
            let orderedChildren = try restoringDisplayOrderAfterChanges(
                originalChildren,
                isChanged: { isChanged($0) || appliedRepairs[$0] != nil },
                nodeAt: recordAt,
                cancellationCheck: cancellationCheck
            )
            var childRecords: [FileNodeRecord] = []
            childRecords.reserveCapacity(orderedChildren.count)
            for (offset, childIndex) in orderedChildren.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                childRecords.append(recordAt(childIndex))
            }
            let repaired = repairingDirectoryRecord(source, children: childRecords)
            let didReorderChildren = !orderedChildren.elementsEqual(originalChildren)
            appliedRepairs[nodeIndex] = repaired
            results.append(AffectedDirectoryRepair(
                index: nodeIndex,
                source: source,
                repaired: repaired,
                orderedChildren: orderedChildren,
                didReorderChildren: didReorderChildren
            ))
        }
        return results
    }

    nonisolated func node(id: String?) -> FileNodeRecord? {
        guard let index = nodeIndex(id: id) else { return nil }
        return node(at: index)
    }

    nonisolated func nodeIndex(id: String?) -> FileTreeNodeIndex? {
        guard let id,
              let index = topologyArena.indexByNodeID[id] else {
            return nil
        }
        guard let logicalScope else { return index }
        guard logicalScope.membership.contains(index) else { return nil }
        return index
    }

    nonisolated func node(at index: FileTreeNodeIndex) -> FileNodeRecord? {
        let offset = Int(index.rawValue)
        guard nodeRecords.indices.contains(offset) else { return nil }
        guard let logicalScope else { return nodeRecords[offset] }
        guard logicalScope.membership.contains(index) else { return nil }
        return logicalScope.replacementRecords[index] ?? nodeRecords[offset]
    }

    /// Replaces existing records while preserving node membership and parent links.
    /// The supplied child order must contain exactly the parent's current children.
    nonisolated func replacingRecordsPreservingTopology(
        _ replacements: [FileNodeRecord],
        orderedChildIDs: [String],
        of parentID: String,
        aggregateStats: ScanAggregateStats
    ) -> FileTreeStore? {
        guard !replacements.isEmpty,
              let parentIndex = nodeIndex(id: parentID) else {
            return nil
        }
        if logicalScope != nil {
            return try? materialized(cancellationCheck: {}).replacingRecordsPreservingTopology(
                replacements,
                orderedChildIDs: orderedChildIDs,
                of: parentID,
                aggregateStats: aggregateStats
            )
        }

        var indexedReplacements: [(Int, FileNodeRecord)] = []
        indexedReplacements.reserveCapacity(replacements.count)
        var replacementIDs = Set<String>()
        for replacement in replacements {
            guard replacementIDs.insert(replacement.id).inserted,
                  let index = nodeIndex(id: replacement.id) else {
                return nil
            }
            indexedReplacements.append((Int(index.rawValue), replacement))
        }

        let reorderedChildIndices = orderedChildIDs.compactMap { nodeIndex(id: $0) }
        guard reorderedChildIndices.count == orderedChildIDs.count,
              let updatedTopology = topologyArena.reorderingChildren(
                  of: parentIndex,
                  to: reorderedChildIndices
              ) else {
            return nil
        }

        var updatedRecords = nodeRecords
        for (offset, replacement) in indexedReplacements {
            updatedRecords[offset] = replacement
        }

        return FileTreeStore(
            rootID: rootID,
            nodeRecords: updatedRecords,
            topologyArena: updatedTopology,
            aggregateStats: aggregateStats
        )
    }

    /// Adds or removes one root-level leaf while preserving every unaffected
    /// subtree in the compact arena. This avoids dictionary projections for
    /// synthetic capacity nodes without exposing general topology mutation.
    nonisolated func replacingRootLeaf(
        removing removedLeafID: String?,
        adding addedLeaf: FileNodeRecord?,
        root replacementRoot: FileNodeRecord,
        orderedChildIDs: [String],
        aggregateStats: ScanAggregateStats
    ) -> FileTreeStore? {
        guard replacementRoot.id == rootID,
              let oldRootIndex = nodeIndex(id: rootID) else {
            return nil
        }
        if logicalScope != nil {
            return try? materialized(cancellationCheck: {}).replacingRootLeaf(
                removing: removedLeafID,
                adding: addedLeaf,
                root: replacementRoot,
                orderedChildIDs: orderedChildIDs,
                aggregateStats: aggregateStats
            )
        }

        let oldRootChildren = topologyArena.children(of: oldRootIndex)
        var expectedChildIDs = oldRootChildren.compactMap { node(at: $0)?.id }
        var removedIndex: FileTreeNodeIndex?
        if let removedLeafID {
            guard let index = nodeIndex(id: removedLeafID),
                  topologyArena.parentIndex(of: index) == oldRootIndex,
                  topologyArena.children(of: index).isEmpty else {
                return nil
            }
            removedIndex = index
            expectedChildIDs.removeAll { $0 == removedLeafID }
        }
        if let addedLeaf {
            guard !addedLeaf.isDirectory,
                  addedLeaf.id != removedLeafID,
                  nodeIndex(id: addedLeaf.id) == nil else {
                return nil
            }
            expectedChildIDs.append(addedLeaf.id)
        }
        guard orderedChildIDs.count == expectedChildIDs.count,
              Set(orderedChildIDs).count == orderedChildIDs.count,
              Set(orderedChildIDs) == Set(expectedChildIDs) else {
            return nil
        }

        var remappedIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: nodeRecords.count)
        var updatedRecords: [FileNodeRecord] = []
        updatedRecords.reserveCapacity(
            nodeRecords.count
                - (removedIndex == nil ? 0 : 1)
                + (addedLeaf == nil ? 0 : 1)
        )
        for (offset, record) in nodeRecords.enumerated() {
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(offset))
            guard oldIndex != removedIndex else { continue }
            let newIndex = FileTreeNodeIndex(rawValue: UInt32(updatedRecords.count))
            remappedIndices[offset] = newIndex
            updatedRecords.append(oldIndex == oldRootIndex ? replacementRoot : record)
        }
        let addedLeafIndex: FileTreeNodeIndex?
        if let addedLeaf {
            addedLeafIndex = FileTreeNodeIndex(rawValue: UInt32(updatedRecords.count))
            updatedRecords.append(addedLeaf)
        } else {
            addedLeafIndex = nil
        }

        guard let updatedRootIndex = remappedIndices[Int(oldRootIndex.rawValue)] else {
            return nil
        }
        var parentIndices = Array<FileTreeNodeIndex?>(repeating: nil, count: updatedRecords.count)
        var childIndicesByIndex = Array(repeating: [FileTreeNodeIndex](), count: updatedRecords.count)
        for oldOffset in nodeRecords.indices {
            guard let newIndex = remappedIndices[oldOffset] else { continue }
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(oldOffset))
            if let oldParent = topologyArena.parentIndex(of: oldIndex) {
                guard let newParent = remappedIndices[Int(oldParent.rawValue)] else { return nil }
                parentIndices[Int(newIndex.rawValue)] = newParent
            }
            childIndicesByIndex[Int(newIndex.rawValue)] = topologyArena.children(of: oldIndex).compactMap {
                remappedIndices[Int($0.rawValue)]
            }
        }

        let updatedRootChildren = orderedChildIDs.compactMap { childID -> FileTreeNodeIndex? in
            if childID == addedLeaf?.id {
                return addedLeafIndex
            }
            guard let oldIndex = nodeIndex(id: childID) else { return nil }
            return remappedIndices[Int(oldIndex.rawValue)]
        }
        guard updatedRootChildren.count == orderedChildIDs.count else { return nil }
        childIndicesByIndex[Int(updatedRootIndex.rawValue)] = updatedRootChildren
        for childIndex in updatedRootChildren {
            parentIndices[Int(childIndex.rawValue)] = updatedRootIndex
        }

        var orderedNodeIndices: [FileTreeNodeIndex] = []
        orderedNodeIndices.reserveCapacity(updatedRecords.count)
        var stack = [updatedRootIndex]
        while let index = stack.popLast() {
            orderedNodeIndices.append(index)
            stack.append(contentsOf: childIndicesByIndex[Int(index.rawValue)].reversed())
        }
        guard orderedNodeIndices.count == updatedRecords.count else { return nil }

        return FileTreeStore(
            verifiedRootIndex: updatedRootIndex,
            nodes: updatedRecords,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: aggregateStats
        )
    }

    nonisolated func replacingAllocatedSizes(
        _ replacements: [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        guard !replacements.isEmpty else { return self }
        if logicalScope != nil {
            var replacementsByID: [(String, Int64)] = []
            replacementsByID.reserveCapacity(replacements.count)
            for replacement in replacements {
                try cancellationCheck()
                guard let nodeID = node(at: replacement.nodeIndex)?.id else {
                    preconditionFailure("Allocated-size replacement index is out of range.")
                }
                replacementsByID.append((nodeID, replacement.allocatedSize))
            }
            let materializedStore = try materialized(cancellationCheck: cancellationCheck)
            let remappedReplacements = replacementsByID.map { nodeID, allocatedSize in
                guard let nodeIndex = materializedStore.nodeIndex(id: nodeID) else {
                    preconditionFailure("Materialized scope is missing an allocated-size replacement.")
                }
                return (nodeIndex: nodeIndex, allocatedSize: allocatedSize)
            }
            return try materializedStore.replacingAllocatedSizes(
                remappedReplacements,
                cancellationCheck: cancellationCheck
            )
        }

        var updatedRecords = nodeRecords
        var updatedChildIndices = topologyArena.childIndices
        guard try Self.applyAllocatedSizeReplacements(
            replacements,
            to: &updatedRecords,
            rootIndex: topologyArena.rootIndex,
            parentRawIndices: topologyArena.parentRawIndices,
            childSpans: topologyArena.childSpans,
            childIndices: &updatedChildIndices,
            cancellationCheck: cancellationCheck
        ) else { return self }

        let existingStats = aggregateStats
        let updatedRoot = updatedRecords[Int(topologyArena.rootIndex.rawValue)]
        let updatedStats = ScanAggregateStats(
            totalAllocatedSize: updatedRoot.allocatedSize,
            totalLogicalSize: updatedRoot.logicalSize,
            fileCount: existingStats.fileCount,
            directoryCount: existingStats.directoryCount,
            accessibleItemCount: existingStats.accessibleItemCount,
            inaccessibleItemCount: existingStats.inaccessibleItemCount
        )
        return FileTreeStore(
            rootID: rootID,
            nodeRecords: updatedRecords,
            topologyArena: try topologyArena.replacingChildIndices(
                updatedChildIndices,
                cancellationCheck: cancellationCheck
            ),
            aggregateStats: updatedStats
        )
    }

    private nonisolated static func applyAllocatedSizeReplacements(
        _ replacements: [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)],
        to nodes: inout [FileNodeRecord],
        rootIndex: FileTreeNodeIndex,
        parentRawIndices: [UInt32],
        childSpans: [FileTreeChildSpan],
        childIndices: inout [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> Bool {
        precondition(parentRawIndices.count == nodes.count)
        precondition(childSpans.count == nodes.count)

        var changedByOffset = Array(repeating: false, count: nodes.count)
        var changedOffsets: [Int] = []
        changedOffsets.reserveCapacity(replacements.count)
        for replacement in replacements {
            try cancellationCheck()
            let offset = Int(replacement.nodeIndex.rawValue)
            precondition(
                offset < nodes.count,
                "Allocated-size replacement index is out of range."
            )
            precondition(
                !nodes[offset].isDirectory,
                "Allocated-size replacement cannot target a directory."
            )
            guard nodes[offset].allocatedSize != replacement.allocatedSize else { continue }
            nodes[offset] = nodes[offset].replacingAllocatedSize(replacement.allocatedSize)
            if !changedByOffset[offset] {
                changedByOffset[offset] = true
                changedOffsets.append(offset)
            }
        }
        guard !changedOffsets.isEmpty else { return false }

        var changedRecordCount = changedOffsets.count
        for changedOffset in changedOffsets {
            var rawAncestorIndex = parentRawIndices[changedOffset]
            while rawAncestorIndex != UInt32.max {
                try cancellationCheck()
                let ancestorOffset = Int(rawAncestorIndex)
                guard !changedByOffset[ancestorOffset] else { break }
                changedByOffset[ancestorOffset] = true
                changedRecordCount += 1
                rawAncestorIndex = parentRawIndices[ancestorOffset]
            }
        }

        let changedNodeIndices = try FileTreeTopologyArena.preorderNodeIndices(
            rootIndex: rootIndex,
            childSpans: childSpans,
            childIndices: childIndices,
            includedByOffset: changedByOffset,
            capacity: changedRecordCount,
            cancellationCheck: cancellationCheck
        )
        let repairs = try Self.repairedAffectedDirectories(
            postorder: changedNodeIndices,
            isChanged: { changedByOffset[Int($0.rawValue)] },
            baseRecordAt: { nodes[Int($0.rawValue)] },
            currentChildren: { nodeIndex in
                let span = childSpans[Int(nodeIndex.rawValue)]
                let start = Int(span.start)
                return childIndices[start..<start + Int(span.count)]
            },
            cancellationCheck: cancellationCheck
        )
        for repair in repairs {
            let offset = Int(repair.index.rawValue)
            nodes[offset] = repair.repaired
            let span = childSpans[offset]
            let start = Int(span.start)
            childIndices.replaceSubrange(start..<start + Int(span.count), with: repair.orderedChildren)
        }
        return true
    }

    nonisolated func parentIndex(of index: FileTreeNodeIndex) -> FileTreeNodeIndex? {
        activeParentIndex(of: index)
    }

    nonisolated func childIndices(of index: FileTreeNodeIndex) -> [FileTreeNodeIndex] {
        guard contains(index) else { return [] }
        return Array(activeChildren(of: index))
    }

    nonisolated func parentID(of id: String?) -> String? {
        guard let index = nodeIndex(id: id),
              let parentIndex = activeParentIndex(of: index) else {
            return nil
        }
        return node(at: parentIndex)?.id
    }

    nonisolated func childIDs(of id: String?) -> [String] {
        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        return activeChildren(of: parentIndex).compactMap { node(at: $0)?.id }
    }

    nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let index = nodeIndex(id: id),
              let parentIndex = activeParentIndex(of: index) else {
            return nil
        }
        return node(at: parentIndex)
    }

    nonisolated func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    nonisolated func childrenPrefix(of id: String?, maxCount: Int) -> [FileNodeRecord] {
        (try? childrenPrefix(of: id, maxCount: maxCount, cancellationCheck: {})) ?? []
    }

    nonisolated func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        if logicalScope == nil {
            let childIndices = topologyArena.children(of: parentIndex)
            var children: [FileNodeRecord] = []
            children.reserveCapacity(childIndices.count)
            for childIndex in childIndices {
                try cancellationCheck()
                children.append(nodeRecords[Int(childIndex.rawValue)])
            }
            return children
        }
        let childIndices = activeChildren(of: parentIndex)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIndices.count)
        for childIndex in childIndices {
            try cancellationCheck()
            if let node = node(at: childIndex) {
                children.append(node)
            }
        }
        return children
    }

    nonisolated func childrenPrefix(
        of id: String?,
        maxCount: Int,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        guard maxCount > 0 else { return [] }

        let resolvedID = id ?? rootID
        guard let parentIndex = nodeIndex(id: resolvedID) else { return [] }
        if logicalScope == nil {
            let childIndices = topologyArena.children(of: parentIndex)
            var children: [FileNodeRecord] = []
            children.reserveCapacity(min(maxCount, childIndices.count))
            for childIndex in childIndices.prefix(maxCount) {
                try cancellationCheck()
                children.append(nodeRecords[Int(childIndex.rawValue)])
            }
            return children
        }
        let childIndices = activeChildren(of: parentIndex)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(min(maxCount, childIndices.count))
        for childIndex in childIndices {
            try cancellationCheck()
            if let node = node(at: childIndex) {
                children.append(node)
                if children.count == maxCount {
                    break
                }
            }
        }
        return children
    }

    nonisolated func containsChildren(id: String?) -> Bool {
        let resolvedID = id ?? rootID
        guard let index = nodeIndex(id: resolvedID) else { return false }
        return !activeChildren(of: index).isEmpty
    }

    nonisolated func childCount(of id: String?) -> Int {
        let resolvedID = id ?? rootID
        guard let index = nodeIndex(id: resolvedID) else { return 0 }
        return activeChildren(of: index).count
    }

    nonisolated func subtreeNodeCount(rootedAt nodeID: String) -> Int {
        subtreeNodeCount(rootedAt: nodeID, upTo: .max)
    }

    nonisolated func subtreeNodeCount(
        rootedAt nodeID: String,
        upTo limit: Int
    ) -> Int {
        guard limit > 0 else { return 0 }
        guard let rootIndex = nodeIndex(id: nodeID) else { return 0 }
        var count = 0
        var stack = [rootIndex]
        while count < limit, let nodeIndex = stack.popLast() {
            count += 1
            // Enqueue only as many children as could still be counted within
            // the limit so huge fan-outs do not build an oversized frontier.
            let remainingCapacity = limit - count - stack.count
            guard remainingCapacity > 0 else { continue }
            let children = activeChildren(of: nodeIndex)
            if children.count <= remainingCapacity {
                stack.append(contentsOf: children)
            } else {
                stack.append(contentsOf: children.prefix(remainingCapacity))
            }
        }
        return count
    }

    nonisolated func subtreeContainsSharedAllocationMetadata(
        rootedAt nodeID: String,
        cancellationCheck: () throws -> Void
    ) throws -> Bool {
        guard let rootIndex = nodeIndex(id: nodeID) else { return false }
        var stack = [rootIndex]
        var visitedCount = 0
        while let nodeIndex = stack.popLast() {
            if visitedCount.isMultiple(of: 256) {
                try cancellationCheck()
            }
            visitedCount += 1
            if let node = node(at: nodeIndex),
               !node.isDirectory,
               !node.isSymbolicLink,
               !node.isSynthetic,
               node.cloneIdentity != nil || node.linkCount > 1 {
                return true
            }
            stack.append(contentsOf: activeChildren(of: nodeIndex))
        }
        return false
    }

    nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        activeOrderedNodeIndices.compactMap { nodeIndex in
            guard !excludingRoot || nodeIndex != activeRootIndex else { return nil }
            return node(at: nodeIndex)?.id
        }
    }

    nonisolated func indexedNodeIndices() -> [FileTreeNodeIndex] {
        activeOrderedNodeIndices
    }

    nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for nodeIndex in activeOrderedNodeIndices {
            if excludingRoot && nodeIndex == activeRootIndex {
                continue
            }
            if let nodeID = node(at: nodeIndex)?.id {
                try body(nodeID)
            }
        }
    }

    nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let index = nodeIndex(id: id), let record = node(at: index) else {
            return [root]
        }

        var result: [FileNodeRecord] = [record]
        var cursor = index
        while let parentIndex = activeParentIndex(of: cursor),
              let parent = self.node(at: parentIndex) {
            result.append(parent)
            cursor = parentIndex
        }
        return result.reversed()
    }

    nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let ancestorIndex = nodeIndex(id: ancestorID),
              let descendantIndex = nodeIndex(id: descendantID) else {
            return false
        }
        var cursor = descendantIndex
        while true {
            if cursor == ancestorIndex {
                return true
            }
            guard let parentIndex = activeParentIndex(of: cursor) else { return false }
            cursor = parentIndex
        }
    }

    nonisolated func hasAncestor(in ancestorIDs: Set<String>, of nodeID: String) -> Bool {
        hasAncestor(in: preparedNodeSet(for: ancestorIDs), of: nodeID)
    }

    nonisolated func preparedNodeSet(for nodeIDs: Set<String>) -> PreparedFileTreeNodeSet {
        PreparedFileTreeNodeSet(
            indices: Set(nodeIDs.compactMap { nodeIndex(id: $0) })
        )
    }

    nonisolated func hasAncestor(
        in ancestorNodes: PreparedFileTreeNodeSet,
        of nodeID: String
    ) -> Bool {
        guard let nodeIndex = nodeIndex(id: nodeID) else { return false }
        return hasAncestor(in: ancestorNodes.indices, of: nodeIndex)
    }

    nonisolated func hasAncestor(
        in ancestorIndices: Set<FileTreeNodeIndex>,
        of nodeIndex: FileTreeNodeIndex
    ) -> Bool {
        var cursor = nodeIndex
        while let parentIndex = activeParentIndex(of: cursor) {
            if ancestorIndices.contains(parentIndex) {
                return true
            }
            cursor = parentIndex
        }
        return false
    }

    nonisolated func isNodeOrDescendant(_ nodeID: String, of ancestorIDs: Set<String>) -> Bool {
        isNodeOrDescendant(nodeID, of: preparedNodeSet(for: ancestorIDs))
    }

    nonisolated func isNodeOrDescendant(
        _ nodeID: String,
        of ancestorNodes: PreparedFileTreeNodeSet
    ) -> Bool {
        guard let nodeIndex = nodeIndex(id: nodeID) else { return false }
        return ancestorNodes.indices.contains(nodeIndex)
            || hasAncestor(in: ancestorNodes.indices, of: nodeIndex)
    }

    nonisolated func topLevelNodeIDs(from nodeIDs: [String]) -> [String] {
        let candidateIDs = Set(nodeIDs.filter { nodeIndex(id: $0) != nil })
        let candidateNodes = preparedNodeSet(for: candidateIDs)
        var emittedIDs = Set<String>()
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateNodes, of: nodeID) else {
                continue
            }
            emittedIDs.insert(nodeID)
            result.append(nodeID)
        }

        return result
    }

    nonisolated func removingSubtrees(rootedAt nodeIDs: [String]) -> FileTreeStore {
        (try? removingSubtrees(rootedAt: nodeIDs, cancellationCheck: {})) ?? self
    }

    nonisolated func removingSubtrees(
        rootedAt nodeIDs: [String],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        try cancellationCheck()
        let removalIDs = topLevelNodeIDs(from: nodeIDs)
        guard !removalIDs.isEmpty else { return self }
        if removalIDs.contains(rootID) {
            return FileTreeStore(root: emptyRootNode())
        }
        let removalRootIndices = removalIDs.compactMap { nodeIndex(id: $0) }
        if logicalScope != nil {
            return try compactedSubtree(
                rootedAt: activeRootIndex,
                excludingSubtreesAt: removalRootIndices,
                cancellationCheck: cancellationCheck
            )
        }
        return try compactedStore(
            removingSubtreesAt: removalRootIndices,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated func removingSubtree(id targetID: String) -> FileTreeStore? {
        try? removingSubtree(id: targetID, cancellationCheck: {})
    }

    nonisolated func removingSubtree(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = nodeIndex(id: targetID),
              parentIndex(of: targetIndex) != nil else {
            return nil
        }
        if logicalScope != nil {
            return try compactedSubtree(
                rootedAt: activeRootIndex,
                excludingSubtreesAt: [targetIndex],
                cancellationCheck: cancellationCheck
            )
        }
        return try compactedStore(
            removingSubtreesAt: [targetIndex],
            cancellationCheck: cancellationCheck
        )
    }

    private nonisolated func compactedStore(
        removingSubtreesAt removalRootIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        var removed = Array(repeating: false, count: nodeRecords.count)
        var removedCount = 0
        for removalRootIndex in removalRootIndices {
            var stack = [removalRootIndex]
            while let currentIndex = stack.popLast() {
                try cancellationCheck()
                let currentOffset = Int(currentIndex.rawValue)
                guard !removed[currentOffset] else { continue }
                removed[currentOffset] = true
                removedCount += 1
                stack.append(contentsOf: topologyArena.children(of: currentIndex))
            }
        }
        guard removedCount > 0 else { return self }

        var affectedAncestors = Array(repeating: false, count: nodeRecords.count)
        var affectedAncestorCount = 0
        for removalRootIndex in removalRootIndices {
            var cursor = topologyArena.parentIndex(of: removalRootIndex)
            while let ancestorIndex = cursor {
                try cancellationCheck()
                let ancestorOffset = Int(ancestorIndex.rawValue)
                guard !affectedAncestors[ancestorOffset] else { break }
                affectedAncestors[ancestorOffset] = true
                affectedAncestorCount += 1
                cursor = topologyArena.parentIndex(of: ancestorIndex)
            }
        }

        var repairedRecordsByOffset: [Int: FileNodeRecord] = [:]
        repairedRecordsByOffset.reserveCapacity(affectedAncestorCount)
        var reorderedChildrenByOffset: [Int: [FileTreeNodeIndex]] = [:]
        reorderedChildrenByOffset.reserveCapacity(affectedAncestorCount)

        let affectedNodeIndices = try topologyArena.preorderNodeIndices(
            includedByOffset: affectedAncestors,
            capacity: affectedAncestorCount,
            cancellationCheck: cancellationCheck
        )
        let repairs = try Self.repairedAffectedDirectories(
            postorder: affectedNodeIndices,
            isChanged: { affectedAncestors[Int($0.rawValue)] },
            shouldRepair: { !removed[Int($0.rawValue)] },
            baseRecordAt: { nodeIndex in
                let offset = Int(nodeIndex.rawValue)
                return repairedRecordsByOffset[offset] ?? nodeRecords[offset]
            },
            currentChildren: { nodeIndex in
                topologyArena.children(of: nodeIndex).filter { childIndex in
                    !removed[Int(childIndex.rawValue)]
                }
            },
            cancellationCheck: cancellationCheck
        )
        for repair in repairs {
            let oldOffset = Int(repair.index.rawValue)
            repairedRecordsByOffset[oldOffset] = repair.repaired
            reorderedChildrenByOffset[oldOffset] = repair.orderedChildren
        }

        let retainedCount = nodeRecords.count - removedCount
        var oldToNewRawIndex = Array(repeating: UInt32.max, count: nodeRecords.count)
        var compactedNodes: [FileNodeRecord] = []
        compactedNodes.reserveCapacity(retainedCount)
        var compactedIndexByNodeID: [String: FileTreeNodeIndex] = [:]
        compactedIndexByNodeID.reserveCapacity(retainedCount)

        for oldOffset in nodeRecords.indices where !removed[oldOffset] {
            if oldOffset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let compactedIndex = FileTreeNodeIndex(rawValue: UInt32(compactedNodes.count))
            let record = repairedRecordsByOffset[oldOffset] ?? nodeRecords[oldOffset]
            oldToNewRawIndex[oldOffset] = compactedIndex.rawValue
            compactedNodes.append(record)
            let previous = compactedIndexByNodeID.updateValue(compactedIndex, forKey: record.id)
            precondition(previous == nil, "Subtree compaction produced duplicate node IDs.")
        }

        let compactedRootRawIndex = oldToNewRawIndex[Int(topologyArena.rootIndex.rawValue)]
        precondition(compactedRootRawIndex != UInt32.max, "Subtree compaction removed the store root.")
        let compactedRootIndex = FileTreeNodeIndex(rawValue: compactedRootRawIndex)
        var compactedParentRawIndices = Array(repeating: UInt32.max, count: retainedCount)
        var compactedChildSpans = Array(repeating: FileTreeChildSpan(), count: retainedCount)
        var compactedChildIndices: [FileTreeNodeIndex] = []
        compactedChildIndices.reserveCapacity(max(retainedCount - 1, 0))
        var statsAccumulator = AggregateStatsAccumulator()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var sharedAllocationClaimNodeIndices: [FileTreeNodeIndex] = []

        for oldOffset in nodeRecords.indices where !removed[oldOffset] {
            let newOffset = Int(oldToNewRawIndex[oldOffset])
            if newOffset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let oldIndex = FileTreeNodeIndex(rawValue: UInt32(oldOffset))
            if let oldParentIndex = topologyArena.parentIndex(of: oldIndex) {
                compactedParentRawIndices[newOffset] = oldToNewRawIndex[Int(oldParentIndex.rawValue)]
            }

            let childStart = compactedChildIndices.count
            if let reorderedChildren = reorderedChildrenByOffset[oldOffset] {
                for childIndex in reorderedChildren {
                    let compactedRawIndex = oldToNewRawIndex[Int(childIndex.rawValue)]
                    guard compactedRawIndex != UInt32.max else { continue }
                    compactedChildIndices.append(FileTreeNodeIndex(rawValue: compactedRawIndex))
                }
            } else {
                for childIndex in topologyArena.children(of: oldIndex) {
                    let compactedRawIndex = oldToNewRawIndex[Int(childIndex.rawValue)]
                    guard compactedRawIndex != UInt32.max else { continue }
                    compactedChildIndices.append(FileTreeNodeIndex(rawValue: compactedRawIndex))
                }
            }
            let childCount = UInt32(compactedChildIndices.count - childStart)
            compactedChildSpans[newOffset] = FileTreeChildSpan(
                start: UInt32(childStart),
                count: childCount
            )
            statsAccumulator.include(
                compactedNodes[newOffset],
                hasMaterializedChildren: childCount > 0
            )
            if let claim = SharedAllocationDeduplicator.claim(for: compactedNodes[newOffset]) {
                sharedAllocationAccumulator.record(claim)
                sharedAllocationClaimNodeIndices.append(FileTreeNodeIndex(rawValue: UInt32(newOffset)))
            }
        }

        let sharedAllocationReplacements = try SharedAllocationDeduplicator.rebalancedAllocatedSizeReplacements(
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: sharedAllocationClaimNodeIndices,
            nodeAt: { compactedNodes[Int($0.rawValue)] },
            cancellationCheck: cancellationCheck
        )
        _ = try Self.applyAllocatedSizeReplacements(
            sharedAllocationReplacements,
            to: &compactedNodes,
            rootIndex: compactedRootIndex,
            parentRawIndices: compactedParentRawIndices,
            childSpans: compactedChildSpans,
            childIndices: &compactedChildIndices,
            cancellationCheck: cancellationCheck
        )

        let compactedOrder = try FileTreeTopologyArena.preorderNodeIndices(
            rootIndex: compactedRootIndex,
            childSpans: compactedChildSpans,
            childIndices: compactedChildIndices,
            capacity: retainedCount,
            cancellationCheck: cancellationCheck
        )
        precondition(compactedOrder.count == retainedCount, "Subtree compaction produced disconnected nodes.")

        let compactedStats = statsAccumulator.stats(
            root: compactedNodes[Int(compactedRootIndex.rawValue)]
        )
        let compactedTopology = FileTreeTopologyArena(
            verifiedRootIndex: compactedRootIndex,
            nodes: compactedNodes,
            indexByNodeID: compactedIndexByNodeID,
            parentRawIndices: compactedParentRawIndices,
            childSpans: compactedChildSpans,
            childIndices: compactedChildIndices,
            orderedNodeIndices: compactedOrder
        )
        let compactedStore = FileTreeStore(
            rootID: rootID,
            nodeRecords: compactedNodes,
            topologyArena: compactedTopology,
            aggregateStats: compactedStats
        )
        return compactedStore
    }

    private nonisolated func emptyRootNode() -> FileNodeRecord {
        let root = root
        return FileNodeRecord(
            id: root.id,
            url: root.url,
            name: root.name,
            isDirectory: root.isDirectory,
            isSymbolicLink: root.isSymbolicLink,
            allocatedSize: 0,
            unduplicatedAllocatedSize: 0,
            dataAllocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            cloneIdentity: root.cloneIdentity,
            mayShareDataBlocks: root.mayShareDataBlocks,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            isSelfAccessible: root.isSelfAccessible,
            isSynthetic: root.isSynthetic,
            isAutoSummarized: root.isAutoSummarized
        )
    }

    nonisolated func replacingSubtree(id targetID: String, with replacement: FileTreeStore) -> FileTreeStore? {
        try? replacingSubtree(id: targetID, with: replacement, cancellationCheck: {})
    }

    nonisolated func replacingSubtree(
        id targetID: String,
        with replacement: FileTreeStore,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try replacingSubtrees(
            [targetID: replacement],
            cancellationCheck: cancellationCheck
        )
    }

    /// Replaces multiple disjoint subtrees as one topology transaction.
    ///
    /// All replacements are validated before the store is changed. Their shared
    /// ancestor chain is then rebuilt once, followed by one scan-wide shared-
    /// allocation rebalance so claims crossing replacement boundaries remain correct.
    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore]
    ) -> FileTreeStore? {
        try? replacingSubtrees(replacements, cancellationCheck: {})
    }

    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard !replacements.isEmpty else { return self }
        if replacements.count == 1,
           let replacement = replacements[rootID],
           replacement.rootID == rootID {
            return try SharedAllocationDeduplicator.rebalancedStore(
                replacement,
                cancellationCheck: cancellationCheck
            )
        }
        if logicalScope != nil {
            return try materialized(cancellationCheck: cancellationCheck).replacingSubtrees(
                replacements,
                cancellationCheck: cancellationCheck
            )
        }

        let targetIDs = Array(replacements.keys)
        var targetIndices: [FileTreeNodeIndex] = []
        targetIndices.reserveCapacity(targetIDs.count)
        var targetOrdinalByIndex: [FileTreeNodeIndex: Int] = [:]
        targetOrdinalByIndex.reserveCapacity(targetIDs.count)
        for (ordinal, targetID) in targetIDs.enumerated() {
            guard let targetIndex = nodeIndex(id: targetID) else { return nil }
            targetIndices.append(targetIndex)
            targetOrdinalByIndex[targetIndex] = ordinal
        }

        for (ordinal, targetIndex) in targetIndices.enumerated() {
            var cursor = topologyArena.parentIndex(of: targetIndex)
            while let ancestorIndex = cursor {
                try cancellationCheck()
                if let ancestorOrdinal = targetOrdinalByIndex[ancestorIndex] {
                    throw StoreError.overlappingReplacementTargets(
                        targetIDs[ancestorOrdinal],
                        targetIDs[ordinal]
                    )
                }
                cursor = topologyArena.parentIndex(of: ancestorIndex)
            }
        }

        let replacementStores = targetIDs.compactMap { replacements[$0] }
        var removalOwnerByOffset = Array(repeating: UInt32.max, count: nodeRecords.count)
        var removedNodeCount = 0
        for (ordinal, targetIndex) in targetIndices.enumerated() {
            var stack = [targetIndex]
            while let nodeIndex = stack.popLast() {
                if removedNodeCount.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                let nodeOffset = Int(nodeIndex.rawValue)
                precondition(removalOwnerByOffset[nodeOffset] == UInt32.max)
                removalOwnerByOffset[nodeOffset] = UInt32(ordinal)
                removedNodeCount += 1
                stack.append(contentsOf: topologyArena.children(of: nodeIndex))
            }
        }

        let replacementNodeCount = replacementStores.reduce(0) { $0 + $1.nodeCount }
        var replacementNodeIDs = Set<String>()
        replacementNodeIDs.reserveCapacity(replacementNodeCount)
        for (ordinal, replacement) in replacementStores.enumerated() {
            for (offset, replacementIndex) in replacement.indexedNodeIndices().enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard let replacementNode = replacement.node(at: replacementIndex) else { continue }
                let replacementID = replacementNode.id
                if !replacementNodeIDs.insert(replacementID).inserted {
                    throw StoreError.replacementIDCollision(replacementID)
                }
                if let existingIndex = nodeIndex(id: replacementID),
                   removalOwnerByOffset[Int(existingIndex.rawValue)] != UInt32(ordinal) {
                    throw StoreError.replacementIDCollision(replacementID)
                }
            }
        }

        var affectedAncestorMembership = NodeMembership(nodeCapacity: nodeRecords.count)
        for targetIndex in targetIndices {
            var cursor = topologyArena.parentIndex(of: targetIndex)
            while let ancestorIndex = cursor {
                try cancellationCheck()
                affectedAncestorMembership.insert(ancestorIndex)
                cursor = topologyArena.parentIndex(of: ancestorIndex)
            }
        }

        let finalNodeCount = nodeRecords.count - removedNodeCount + replacementNodeCount
        var compactedNodes: [FileNodeRecord] = []
        var compactedIndexByNodeID: [String: FileTreeNodeIndex] = [:]
        var parentRawIndices: [UInt32] = []
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        var affectedCompactedIndices: [FileTreeNodeIndex] = []
        var replacementRootCompactedIndices: [FileTreeNodeIndex] = []
        var statsAccumulator = AggregateStatsAccumulator()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var sharedAllocationClaimIndices: [FileTreeNodeIndex] = []
        compactedNodes.reserveCapacity(finalNodeCount)
        compactedIndexByNodeID.reserveCapacity(finalNodeCount)
        parentRawIndices.reserveCapacity(finalNodeCount)
        orderedNodeIndices.reserveCapacity(finalNodeCount)

        typealias TraversalEntry = (
            sourceOrdinal: Int,
            sourceIndex: FileTreeNodeIndex,
            parentRawIndex: UInt32
        )
        let baselineSourceOrdinal = -1
        let rootEntry: TraversalEntry
        if let rootReplacementOrdinal = targetOrdinalByIndex[topologyArena.rootIndex] {
            rootEntry = (
                rootReplacementOrdinal,
                replacementStores[rootReplacementOrdinal].activeRootIndex,
                UInt32.max
            )
        } else {
            rootEntry = (baselineSourceOrdinal, topologyArena.rootIndex, UInt32.max)
        }
        var traversalStack = [rootEntry]

        while let entry = traversalStack.popLast() {
            if compactedNodes.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let sourceStore = entry.sourceOrdinal == baselineSourceOrdinal
                ? self
                : replacementStores[entry.sourceOrdinal]
            guard let node = sourceStore.node(at: entry.sourceIndex) else { continue }
            let sourceChildren = sourceStore.activeChildren(of: entry.sourceIndex)
            let compactedIndex = FileTreeNodeIndex(rawValue: UInt32(compactedNodes.count))
            precondition(
                compactedIndexByNodeID.updateValue(compactedIndex, forKey: node.id) == nil
            )
            compactedNodes.append(node)
            parentRawIndices.append(entry.parentRawIndex)
            orderedNodeIndices.append(compactedIndex)
            statsAccumulator.include(node, hasMaterializedChildren: !sourceChildren.isEmpty)
            if let claim = SharedAllocationDeduplicator.claim(for: node) {
                sharedAllocationAccumulator.record(claim)
                sharedAllocationClaimIndices.append(compactedIndex)
            }

            let isReplacementRoot = entry.sourceOrdinal != baselineSourceOrdinal
                && entry.sourceIndex == sourceStore.activeRootIndex
            if isReplacementRoot {
                replacementRootCompactedIndices.append(compactedIndex)
            } else if entry.sourceOrdinal == baselineSourceOrdinal
                && affectedAncestorMembership.contains(entry.sourceIndex) {
                affectedCompactedIndices.append(compactedIndex)
            }

            for childIndex in sourceChildren.reversed() {
                if entry.sourceOrdinal == baselineSourceOrdinal,
                   let replacementOrdinal = targetOrdinalByIndex[childIndex] {
                    traversalStack.append((
                        replacementOrdinal,
                        replacementStores[replacementOrdinal].activeRootIndex,
                        compactedIndex.rawValue
                    ))
                } else {
                    traversalStack.append((
                        entry.sourceOrdinal,
                        childIndex,
                        compactedIndex.rawValue
                    ))
                }
            }
        }

        precondition(compactedNodes.count == finalNodeCount)
        let compactedStore = try Self.finalizedCompactedStore(
            nodes: &compactedNodes,
            indexByNodeID: compactedIndexByNodeID,
            parentRawIndices: parentRawIndices,
            orderedNodeIndices: &orderedNodeIndices,
            affectedNodeIndices: affectedCompactedIndices,
            changedNodeIndices: replacementRootCompactedIndices,
            statsAccumulator: &statsAccumulator,
            cancellationCheck: cancellationCheck
        )
        return try SharedAllocationDeduplicator.rebalancedStore(
            compactedStore,
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: sharedAllocationClaimIndices,
            cancellationCheck: cancellationCheck
        )
    }

    /// Returns an independently mutable compact store for the visible scope.
    /// Unscoped stores already own a complete backing arena and pass through.
    nonisolated func materialized(
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        guard logicalScope != nil else { return self }
        guard let store = try subtree(
            rootedAt: rootID,
            cancellationCheck: cancellationCheck
        ) else {
            preconditionFailure("Logical scope root is missing from its backing store.")
        }
        return store
    }

    /// Creates an immutable view rooted inside the same compact backing store.
    /// Node and topology buffers remain shared; only membership, traversal order,
    /// and sparse shared-allocation corrections belong to the logical scope.
    nonisolated func logicalScope(rootedAt targetID: String) -> FileTreeStore? {
        try? logicalScope(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func logicalScope(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = nodeIndex(id: targetID) else { return nil }

        var membership = NodeMembership(nodeCapacity: nodeRecords.count)
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        let targetRecord = nodeRecords[Int(targetIndex.rawValue)]
        if !topologyArena.children(of: targetIndex).isEmpty {
            orderedNodeIndices.reserveCapacity(min(
                nodeRecords.count,
                Self.saturatingAdd(targetRecord.descendantFileCount, 1)
            ))
        }
        var statsAccumulator = AggregateStatsAccumulator()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var sharedAllocationClaimIndices: [FileTreeNodeIndex] = []
        var stack = [targetIndex]

        while let nodeIndex = stack.popLast() {
            if orderedNodeIndices.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let node = nodeRecords[Int(nodeIndex.rawValue)]
            let children = topologyArena.children(of: nodeIndex)
            membership.insert(nodeIndex)
            orderedNodeIndices.append(nodeIndex)
            statsAccumulator.include(node, hasMaterializedChildren: !children.isEmpty)
            if let claim = SharedAllocationDeduplicator.claim(for: node) {
                sharedAllocationAccumulator.record(claim)
                sharedAllocationClaimIndices.append(nodeIndex)
            }
            guard !children.isEmpty else { continue }
            stack.reserveCapacity(stack.count + children.count)
            for (offset, childIndex) in children.reversed().enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                stack.append(childIndex)
            }
        }

        let allocationReplacements = try SharedAllocationDeduplicator.rebalancedAllocatedSizeReplacements(
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: sharedAllocationClaimIndices,
            nodeAt: { nodeRecords[Int($0.rawValue)] },
            cancellationCheck: cancellationCheck
        )
        var replacementRecords: [FileTreeNodeIndex: FileNodeRecord] = [:]
        replacementRecords.reserveCapacity(allocationReplacements.count)
        var changedRecordIndices = Set<FileTreeNodeIndex>()
        changedRecordIndices.reserveCapacity(allocationReplacements.count)
        var affectedDirectoryIndices = Set<FileTreeNodeIndex>()

        for replacement in allocationReplacements {
            try cancellationCheck()
            let source = nodeRecords[Int(replacement.nodeIndex.rawValue)]
            replacementRecords[replacement.nodeIndex] = source.replacingAllocatedSize(
                replacement.allocatedSize
            )
            changedRecordIndices.insert(replacement.nodeIndex)

            var ancestorIndex = topologyArena.parentIndex(of: replacement.nodeIndex)
            while let currentIndex = ancestorIndex, membership.contains(currentIndex) {
                try cancellationCheck()
                affectedDirectoryIndices.insert(currentIndex)
                guard currentIndex != targetIndex else { break }
                ancestorIndex = topologyArena.parentIndex(of: currentIndex)
            }
        }

        var reorderedChildren: [FileTreeNodeIndex: [FileTreeNodeIndex]] = [:]
        reorderedChildren.reserveCapacity(affectedDirectoryIndices.count)
        let affectedDirectories = orderedNodeIndices
            .filter { affectedDirectoryIndices.contains($0) }
        let repairs = try Self.repairedAffectedDirectories(
            postorder: affectedDirectories,
            isChanged: { changedRecordIndices.contains($0) },
            baseRecordAt: { nodeIndex in
                replacementRecords[nodeIndex] ?? nodeRecords[Int(nodeIndex.rawValue)]
            },
            currentChildren: { topologyArena.children(of: $0) },
            cancellationCheck: cancellationCheck
        )
        for repair in repairs {
            if repair.repaired != repair.source {
                replacementRecords[repair.index] = repair.repaired
                changedRecordIndices.insert(repair.index)
            }
            if repair.didReorderChildren {
                reorderedChildren[repair.index] = repair.orderedChildren
            }
        }

        if !reorderedChildren.isEmpty {
            orderedNodeIndices.removeAll(keepingCapacity: true)
            stack = [targetIndex]
            while let nodeIndex = stack.popLast() {
                if orderedNodeIndices.count.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                orderedNodeIndices.append(nodeIndex)
                if let children = reorderedChildren[nodeIndex] {
                    stack.append(contentsOf: children.reversed())
                } else {
                    stack.append(contentsOf: topologyArena.children(of: nodeIndex).reversed())
                }
            }
        }

        let scopedRoot = replacementRecords[targetIndex]
            ?? nodeRecords[Int(targetIndex.rawValue)]
        let scope = LogicalScope(
            rootIndex: targetIndex,
            membership: membership,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: statsAccumulator.stats(root: scopedRoot),
            replacementRecords: replacementRecords,
            reorderedChildren: reorderedChildren
        )
        return FileTreeStore(
            rootID: targetID,
            nodeRecords: nodeRecords,
            topologyArena: topologyArena,
            aggregateStats: scope.aggregateStats,
            logicalScope: scope,
            backingStorageID: backingStorageID
        )
    }

    nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = nodeIndex(id: targetID) else { return nil }
        return try compactedSubtree(
            rootedAt: targetIndex,
            excludingSubtreesAt: [],
            cancellationCheck: cancellationCheck
        )
    }

    // Keep this phase out of the large compaction routine; inlining it
    // measurably regresses logical-scope removal throughput in Release builds.
    @inline(never)
    private nonisolated static func finalizeCompactedSubtree(
        nodes: inout [FileNodeRecord],
        affectedNodeIndices: [FileTreeNodeIndex],
        changedNodeIndices: [FileTreeNodeIndex] = [],
        childSpans: [FileTreeChildSpan],
        childIndices: inout [FileTreeNodeIndex],
        orderedNodeIndices: inout [FileTreeNodeIndex],
        statsAccumulator: inout AggregateStatsAccumulator,
        cancellationCheck: () throws -> Void
    ) throws {
        var didReorderChildren = false
        if !affectedNodeIndices.isEmpty {
            var affectedNodeIndexSet = Set(affectedNodeIndices)
            affectedNodeIndexSet.formUnion(changedNodeIndices)
            let repairs = try Self.repairedAffectedDirectories(
                postorder: affectedNodeIndices,
                isChanged: { affectedNodeIndexSet.contains($0) },
                baseRecordAt: { nodes[Int($0.rawValue)] },
                currentChildren: { nodeIndex in
                    let span = childSpans[Int(nodeIndex.rawValue)]
                    let start = Int(span.start)
                    return childIndices[start..<start + Int(span.count)]
                },
                cancellationCheck: cancellationCheck
            )
            for repair in repairs {
                let offset = Int(repair.index.rawValue)
                nodes[offset] = repair.repaired
                statsAccumulator.replaceAccessibility(from: repair.source, to: repair.repaired)
                let span = childSpans[offset]
                let start = Int(span.start)
                if repair.didReorderChildren {
                    childIndices.replaceSubrange(
                        start..<start + Int(span.count),
                        with: repair.orderedChildren
                    )
                    didReorderChildren = true
                }
            }
        }

        if didReorderChildren {
            orderedNodeIndices = try FileTreeTopologyArena.preorderNodeIndices(
                rootIndex: FileTreeNodeIndex(rawValue: 0),
                childSpans: childSpans,
                childIndices: childIndices,
                capacity: nodes.count,
                cancellationCheck: cancellationCheck
            )
        }
        try cancellationCheck()
    }

    private nonisolated static func finalizedCompactedStore(
        nodes: inout [FileNodeRecord],
        indexByNodeID: [String: FileTreeNodeIndex]? = nil,
        parentRawIndices: [UInt32],
        orderedNodeIndices: inout [FileTreeNodeIndex],
        affectedNodeIndices: [FileTreeNodeIndex],
        changedNodeIndices: [FileTreeNodeIndex] = [],
        statsAccumulator: inout AggregateStatsAccumulator,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        var childSpans = Array(repeating: FileTreeChildSpan(), count: nodes.count)
        for (offset, parentRawIndex) in parentRawIndices.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if parentRawIndex != UInt32.max {
                childSpans[Int(parentRawIndex)].count += 1
            }
        }

        var childCount = 0
        for offset in childSpans.indices {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            childSpans[offset].start = UInt32(childCount)
            childCount += Int(childSpans[offset].count)
        }

        var nextChildRawOffset = childSpans.map(\.start)
        var childIndices = Array(
            repeating: FileTreeNodeIndex(rawValue: 0),
            count: childCount
        )
        for (offset, parentRawIndex) in parentRawIndices.enumerated()
        where parentRawIndex != UInt32.max {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let parentOffset = Int(parentRawIndex)
            childIndices[Int(nextChildRawOffset[parentOffset])] = FileTreeNodeIndex(
                rawValue: UInt32(offset)
            )
            nextChildRawOffset[parentOffset] += 1
        }

        try finalizeCompactedSubtree(
            nodes: &nodes,
            affectedNodeIndices: affectedNodeIndices,
            changedNodeIndices: changedNodeIndices,
            childSpans: childSpans,
            childIndices: &childIndices,
            orderedNodeIndices: &orderedNodeIndices,
            statsAccumulator: &statsAccumulator,
            cancellationCheck: cancellationCheck
        )
        if let indexByNodeID {
            return FileTreeStore(
                verifiedRootIndex: FileTreeNodeIndex(rawValue: 0),
                nodes: nodes,
                indexByNodeID: indexByNodeID,
                parentRawIndices: parentRawIndices,
                childSpans: childSpans,
                childIndices: childIndices,
                orderedNodeIndices: orderedNodeIndices,
                aggregateStats: statsAccumulator.stats(root: nodes[0])
            )
        }
        return FileTreeStore(
            verifiedRootIndex: FileTreeNodeIndex(rawValue: 0),
            nodes: nodes,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices,
            aggregateStats: statsAccumulator.stats(root: nodes[0])
        )
    }

    private nonisolated func compactedSubtree(
        rootedAt targetIndex: FileTreeNodeIndex,
        excludingSubtreesAt excludedRootIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        let excludesSubtrees = !excludedRootIndices.isEmpty
        var excludedMembership: NodeMembership?
        var affectedAncestorMembership: NodeMembership?
        var affectedAncestorCount = 0
        if excludesSubtrees {
            var excluded = NodeMembership(nodeCapacity: nodeRecords.count)
            var affected = NodeMembership(nodeCapacity: nodeRecords.count)
            for excludedRootIndex in excludedRootIndices {
                excluded.insert(excludedRootIndex)
                var cursor = topologyArena.parentIndex(of: excludedRootIndex)
                while let ancestorIndex = cursor {
                    try cancellationCheck()
                    if affected.insert(ancestorIndex) {
                        affectedAncestorCount += 1
                    }
                    guard ancestorIndex != targetIndex else { break }
                    cursor = topologyArena.parentIndex(of: ancestorIndex)
                }
            }
            excludedMembership = excluded
            affectedAncestorMembership = affected
        }

        var scopedNodes: [FileNodeRecord] = []
        var parentRawIndices: [UInt32] = []
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        var affectedScopedIndices: [FileTreeNodeIndex] = []
        var statsAccumulator = AggregateStatsAccumulator()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var sharedAllocationClaimIndices: [FileTreeNodeIndex] = []
        var stack = [(sourceIndex: targetIndex, scopedParentRawIndex: UInt32.max)]
        affectedScopedIndices.reserveCapacity(affectedAncestorCount)

        while let entry = stack.popLast() {
            if scopedNodes.count.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let sourceIndex = entry.sourceIndex
            if excludedMembership?.contains(sourceIndex) == true {
                continue
            }
            let sourceOffset = Int(sourceIndex.rawValue)
            let scopedIndex = FileTreeNodeIndex(rawValue: UInt32(scopedNodes.count))
            let node = nodeRecords[sourceOffset]
            let sourceChildren = topologyArena.children(of: sourceIndex)
            scopedNodes.append(node)
            parentRawIndices.append(entry.scopedParentRawIndex)
            orderedNodeIndices.append(scopedIndex)
            if affectedAncestorMembership?.contains(sourceIndex) == true {
                affectedScopedIndices.append(scopedIndex)
            }
            statsAccumulator.include(node, hasMaterializedChildren: !sourceChildren.isEmpty)
            if let claim = SharedAllocationDeduplicator.claim(for: node) {
                sharedAllocationAccumulator.record(claim)
                sharedAllocationClaimIndices.append(scopedIndex)
            }
            for (childOffset, childIndex) in sourceChildren.reversed().enumerated() {
                if childOffset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                stack.append((
                    sourceIndex: childIndex,
                    scopedParentRawIndex: scopedIndex.rawValue
                ))
            }
        }

        let scopedStore = try Self.finalizedCompactedStore(
            nodes: &scopedNodes,
            parentRawIndices: parentRawIndices,
            orderedNodeIndices: &orderedNodeIndices,
            affectedNodeIndices: affectedScopedIndices,
            statsAccumulator: &statsAccumulator,
            cancellationCheck: cancellationCheck
        )
        return try SharedAllocationDeduplicator.rebalancedStore(
            scopedStore,
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: sharedAllocationClaimIndices,
            cancellationCheck: cancellationCheck
        )
    }

    private nonisolated static func sanitizedTopology(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]]
    ) -> SanitizedTopology {
        guard let root = inputNodesByID[rootID] else {
            preconditionFailure("FileTreeStore root is missing from its nodes.")
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var orderedNodeIDs: [String] = []
        var materializedDirectoryIDs = Set<String>()
        var visited: Set<String> = [rootID]
        var stack = [rootID]

        while let parentID = stack.popLast() {
            orderedNodeIDs.append(parentID)
            guard let childIDs = inputChildIDsByID[parentID] else { continue }
            if inputNodesByID[parentID]?.isDirectory == true {
                materializedDirectoryIDs.insert(parentID)
            }
            guard !childIDs.isEmpty else { continue }

            var sanitizedChildIDs: [String] = []
            sanitizedChildIDs.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let child = inputNodesByID[childID] else { continue }
                guard visited.insert(childID).inserted else { continue }
                nodesByID[childID] = child
                sanitizedChildIDs.append(childID)
            }

            if !sanitizedChildIDs.isEmpty {
                childIDsByID[parentID] = sanitizedChildIDs
                stack.append(contentsOf: sanitizedChildIDs.reversed())
            }
        }

        let materializedInputChildIDsByID = inputChildIDsByID.filter { !$0.value.isEmpty }
        let didDropReferences =
            nodesByID.count != inputNodesByID.count ||
            childIDsByID != materializedInputChildIDsByID

        return SanitizedTopology(
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            orderedNodeIDs: orderedNodeIDs,
            materializedDirectoryIDs: materializedDirectoryIDs,
            didDropReferences: didDropReferences
        )
    }

    private nonisolated static func orderedNodeIDsAssumingValidTopology(
        rootID: String,
        childIDsByID: [String: [String]],
        nodeCount: Int
    ) -> [String] {
        var orderedNodeIDs: [String] = []
        orderedNodeIDs.reserveCapacity(nodeCount)
        var stack = [rootID]

        while let nodeID = stack.popLast() {
            orderedNodeIDs.append(nodeID)
            if orderedNodeIDs.count > nodeCount {
                preconditionFailure("FileTreeStore topology reaches more nodes than declared.")
            }
            if let childIDs = childIDsByID[nodeID] {
                stack.append(contentsOf: childIDs.reversed())
            }
        }
        return orderedNodeIDs
    }

    private nonisolated static func repairMaterializedDirectoryTotals(
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        orderedNodeIDs: [String],
        materializedDirectoryIDs: Set<String>
    ) -> [String: FileNodeRecord] {
        guard !materializedDirectoryIDs.isEmpty else { return nodesByID }

        var repairedNodes = nodesByID
        for nodeID in orderedNodeIDs.reversed() where materializedDirectoryIDs.contains(nodeID) {
            guard let node = repairedNodes[nodeID], node.isDirectory else { continue }
            let childIDs = childIDsByID[nodeID] ?? []
            let children = childIDs.compactMap { repairedNodes[$0] }
            repairedNodes[nodeID] = repairingDirectoryRecord(node, children: children)
        }
        return repairedNodes
    }

    private nonisolated static func repairingDirectoryRecord<Children: Sequence>(
        _ node: FileNodeRecord,
        children: Children
    ) -> FileNodeRecord where Children.Element == FileNodeRecord {
        var totals = MaterializedDirectoryTotals()
        for child in children {
            totals.include(child)
        }
        return repairingDirectoryRecord(node, totals: totals)
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        childIndices: ArraySlice<FileTreeNodeIndex>,
        nodes: [FileNodeRecord]
    ) -> FileNodeRecord {
        var totals = MaterializedDirectoryTotals()
        for childIndex in childIndices {
            totals.include(nodes[Int(childIndex.rawValue)])
        }
        return repairingDirectoryRecord(node, totals: totals)
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        totals: MaterializedDirectoryTotals
    ) -> FileNodeRecord {
        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: totals.allocatedSize,
            logicalSize: totals.logicalSize,
            descendantFileCount: totals.descendantFileCount,
            lastModified: node.lastModified,
            fileIdentity: node.fileIdentity,
            linkCount: node.linkCount,
            cloneIdentity: node.cloneIdentity,
            mayShareDataBlocks: node.mayShareDataBlocks,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && totals.childrenAreAccessible,
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }

    /// Tree totals originate from filesystem metadata and imported archives. A
    /// malformed archive can contain individually valid nonnegative values whose
    /// sum exceeds the integer representation; clamp instead of trapping while
    /// rebuilding a safe in-memory tree.
    private nonisolated static func saturatingAdd<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> Value {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= .zero ? .max : .min
    }
}
