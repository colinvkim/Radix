//
//  FileTreeStore.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

struct FileTreeStore: Sendable {
    let rootID: String
    let nodesByID: [String: FileNodeRecord]
    let childIDsByID: [String: [String]]
    let parentIDByID: [String: String]
    private let orderedNodeIDs: [String]
    private let precomputedAggregateStats: ScanAggregateStats?

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let parentIDByID: [String: String]
        let orderedNodeIDs: [String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            }
        }
    }

    nonisolated var root: FileNodeRecord {
        guard let root = nodesByID[rootID] else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var nodeCount: Int {
        nodesByID.count
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        if let precomputedAggregateStats {
            return precomputedAggregateStats
        }

        return computedAggregateStats()
    }

    private nonisolated func computedAggregateStats() -> ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        for nodeID in orderedNodeIDs {
            guard let node = nodesByID[nodeID] else { continue }

            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !containsChildren(id: node.id) {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    nonisolated init(root: FileNodeRecord) {
        self.init(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [:],
            parentIDByID: [:]
        )
    }

    nonisolated init(root: FileNodeRecord, childrenByID inputChildrenByID: [String: [FileNodeRecord]]) {
        var nodesByID = [root.id: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var seenNodeIDs: Set<String> = [root.id]
        var stack = [root]

        while let parent = stack.popLast() {
            guard let inputChildren = inputChildrenByID[parent.id] else { continue }
            let (uniqueChildren, droppedChildIDs) = Self.uniqueChildrenAndDroppedIDs(
                inputChildren,
                seenNodeIDs: &seenNodeIDs
            )
            let children = Self.sortedChildren(uniqueChildren)
            childIDsByID[parent.id] = children.map(\.id) + droppedChildIDs
            guard !children.isEmpty else { continue }

            for child in children {
                nodesByID[child.id] = child
                parentIDByID[child.id] = parent.id
                stack.append(child)
            }
        }

        self.init(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
    }

    nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.rootID = rootID
        self.nodesByID = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                orderedNodeIDs: topology.orderedNodeIDs,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.childIDsByID = topology.childIDsByID
        self.parentIDByID = topology.parentIDByID
        self.precomputedAggregateStats = topology.didDropReferences ? nil : aggregateStats
        self.orderedNodeIDs = topology.orderedNodeIDs
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        children.sorted { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }
    }

    private nonisolated static func uniqueChildrenAndDroppedIDs(
        _ children: [FileNodeRecord],
        seenNodeIDs: inout Set<String>
    ) -> (uniqueChildren: [FileNodeRecord], droppedChildIDs: [String]) {
        var uniqueChildren: [FileNodeRecord] = []
        var droppedChildIDs: [String] = []
        uniqueChildren.reserveCapacity(children.count)

        for child in children {
            if seenNodeIDs.insert(child.id).inserted {
                uniqueChildren.append(child)
            } else {
                droppedChildIDs.append(child.id)
            }
        }

        return (uniqueChildren, droppedChildIDs)
    }

    nonisolated func node(id: String?) -> FileNodeRecord? {
        guard let id else { return nil }
        return nodesByID[id]
    }

    nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let id, let parentID = parentIDByID[id] else { return nil }
        return nodesByID[parentID]
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
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIDs.count)
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
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
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(min(maxCount, childIDs.count))
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
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
        return childIDsByID[resolvedID]?.isEmpty == false
    }

    nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        guard excludingRoot else {
            return orderedNodeIDs
        }
        return orderedNodeIDs.filter { $0 != rootID }
    }

    nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for nodeID in orderedNodeIDs {
            if excludingRoot && nodeID == rootID {
                continue
            }
            try body(nodeID)
        }
    }

    nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let id, let node = nodesByID[id] else {
            return [root]
        }

        var result: [FileNodeRecord] = [node]
        var cursor = id
        while let parentID = parentIDByID[cursor], let parent = nodesByID[parentID] {
            result.append(parent)
            cursor = parentID
        }
        return result.reversed()
    }

    nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let descendantID else { return false }
        if ancestorID == descendantID {
            return true
        }

        var cursor = descendantID
        while let parentID = parentIDByID[cursor] {
            if parentID == ancestorID {
                return true
            }
            cursor = parentID
        }
        return false
    }

    nonisolated func hasAncestor(in ancestorIDs: Set<String>, of nodeID: String) -> Bool {
        var cursor = nodeID
        while let parentID = parentIDByID[cursor] {
            if ancestorIDs.contains(parentID) {
                return true
            }
            cursor = parentID
        }
        return false
    }

    nonisolated func isNodeOrDescendant(_ nodeID: String, of ancestorIDs: Set<String>) -> Bool {
        ancestorIDs.contains(nodeID) || hasAncestor(in: ancestorIDs, of: nodeID)
    }

    nonisolated func topLevelNodeIDs(from nodeIDs: [String]) -> [String] {
        let candidateIDs = Set(nodeIDs.filter { nodesByID[$0] != nil })
        var emittedIDs = Set<String>()
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateIDs, of: nodeID) else {
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

        var removedIDs = Set<String>()
        for removalID in removalIDs {
            try cancellationCheck()
            guard nodesByID[removalID] != nil else { continue }
            removedIDs.formUnion(try subtreeNodeIDs(
                rootedAt: removalID,
                cancellationCheck: cancellationCheck
            ))
        }
        guard !removedIDs.isEmpty else { return self }

        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for (offset, entry) in childIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard !removedIDs.contains(entry.key) else { continue }
            updatedChildIDs[entry.key] = entry.value.filter { !removedIDs.contains($0) }
        }

        let updatedStore = FileTreeStore(
            rootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    nonisolated func removingSubtree(id targetID: String) -> FileTreeStore? {
        try? removingSubtree(id: targetID, cancellationCheck: {})
    }

    nonisolated func removingSubtree(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil,
              let parentID = parentIDByID[targetID] else {
            return nil
        }

        let removedIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        let remainingParentChildIDs = (updatedChildIDs[parentID] ?? []).filter { !removedIDs.contains($0) }
        if remainingParentChildIDs.isEmpty {
            updatedChildIDs.removeValue(forKey: parentID)
        } else {
            updatedChildIDs[parentID] = remainingParentChildIDs
        }

        var cursor: String? = parentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            if sortedChildRecords.isEmpty {
                updatedChildIDs.removeValue(forKey: currentID)
            } else {
                updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            }
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            rootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
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
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
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
        try cancellationCheck()
        guard nodesByID[targetID] != nil else { return nil }

        let oldParentID = parentIDByID[targetID]
        let oldSubtreeIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        try preflightReplacement(
            replacement,
            removing: oldSubtreeIDs,
            cancellationCheck: cancellationCheck
        )
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, oldID) in oldSubtreeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        for (offset, entry) in replacement.nodesByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes[entry.key] = entry.value
        }
        for (offset, entry) in replacement.childIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedChildIDs[entry.key] = entry.value
        }
        for (offset, entry) in replacement.parentIDByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedParentIDs[entry.key] = entry.value
        }

        let updatedRootID: String
        if let oldParentID {
            let previousChildIDs = childIDsByID[oldParentID] ?? []
            updatedChildIDs[oldParentID] = previousChildIDs.map { childID in
                childID == targetID ? replacement.rootID : childID
            }
            updatedParentIDs[replacement.rootID] = oldParentID
            updatedRootID = rootID
        } else {
            updatedParentIDs.removeValue(forKey: replacement.rootID)
            updatedRootID = replacement.rootID
        }

        var cursor = oldParentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            rootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func preflightReplacement(
        _ replacement: FileTreeStore,
        removing oldSubtreeIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        for (offset, replacementID) in replacement.nodesByID.keys.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if nodesByID[replacementID] != nil && !oldSubtreeIDs.contains(replacementID) {
                throw StoreError.replacementIDCollision(replacementID)
            }
        }
    }

    nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil else { return nil }

        var scopedNodes: [String: FileNodeRecord] = [:]
        var scopedChildIDs: [String: [String]] = [:]
        var scopedParentIDs: [String: String] = [:]
        var stack = [targetID]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            guard let node = nodesByID[currentID] else { continue }
            scopedNodes[currentID] = node

            let childIDs = childIDsByID[currentID] ?? []
            guard !childIDs.isEmpty else { continue }

            var scopedChildren: [String] = []
            scopedChildren.reserveCapacity(childIDs.count)
            for (offset, childID) in childIDs.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard nodesByID[childID] != nil else { continue }
                scopedChildren.append(childID)
                scopedParentIDs[childID] = currentID
                stack.append(childID)
            }

            if !scopedChildren.isEmpty {
                scopedChildIDs[currentID] = scopedChildren
            }
        }

        let scopedStore = FileTreeStore(
            rootID: targetID,
            nodesByID: scopedNodes,
            childIDsByID: scopedChildIDs,
            parentIDByID: scopedParentIDs
        )
        return try HardLinkDeduplicator.rebalancedStore(scopedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func subtreeNodeIDs(rootedAt id: String) -> [String] {
        (try? subtreeNodeIDs(rootedAt: id, cancellationCheck: {})) ?? []
    }

    private nonisolated func subtreeNodeIDs(
        rootedAt id: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        var result: [String] = []
        var stack = [id]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            result.append(currentID)
            let childIDs = childIDsByID[currentID] ?? []
            stack.append(contentsOf: childIDs)
        }

        return result
    }

    private nonisolated static func makeOrderedNodeIDs(
        rootID: String,
        childIDsByID: [String: [String]],
        nodesByID: [String: FileNodeRecord]
    ) -> [String] {
        guard nodesByID[rootID] != nil else { return [] }
        var result: [String] = []
        var stack: [String] = [rootID]
        var visited: Set<String> = []

        while let nodeID = stack.popLast() {
            guard nodesByID[nodeID] != nil, visited.insert(nodeID).inserted else { continue }
            result.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
        }

        return result
    }

    private nonisolated static func sanitizedTopology(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]]
    ) -> SanitizedTopology {
        guard let root = inputNodesByID[rootID] else {
            return SanitizedTopology(
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                parentIDByID: [:],
                orderedNodeIDs: [],
                materializedDirectoryIDs: [],
                didDropReferences: true
            )
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
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
                parentIDByID[childID] = parentID
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
            parentIDByID: parentIDByID,
            orderedNodeIDs: orderedNodeIDs,
            materializedDirectoryIDs: materializedDirectoryIDs,
            didDropReferences: didDropReferences
        )
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

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        let allocatedSize = children.reduce(into: Int64(0)) { result, child in
            result += child.allocatedSize
        }
        let logicalSize = children.reduce(into: Int64(0)) { result, child in
            result += child.logicalSize
        }
        let descendantFileCount = children.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }

        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: node.lastModified,
            fileIdentity: node.fileIdentity,
            linkCount: node.linkCount,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && children.allSatisfy(\.isAccessible),
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }
}
