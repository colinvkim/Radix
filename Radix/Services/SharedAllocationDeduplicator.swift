//
//  SharedAllocationDeduplicator.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated struct SharedAllocationDeduplicator {
    nonisolated static func claim(
        for metadata: NodeMetadata,
        ownerNodeID: String,
        path: @autoclosure () -> String
    ) -> SharedAllocationClaim? {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink else {
            return nil
        }

        let hardLinkIdentity = metadata.linkCount > 1 ? metadata.fileIdentity : nil
        guard hardLinkIdentity != nil || metadata.cloneIdentity != nil else {
            return nil
        }

        return SharedAllocationClaim(
            fileIdentity: metadata.fileIdentity,
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: metadata.cloneIdentity,
            ownerNodeID: ownerNodeID,
            path: path(),
            allocatedSize: metadata.allocatedSize,
            cloneAllocatedSize: metadata.dataAllocatedSize
        )
    }

    nonisolated static func deduplicatedStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        sharedAllocationClaims: [SharedAllocationClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        deduplicatedStore(
            rootID: rootID,
            nodesByID: inputNodesByID,
            childIDsByID: inputChildIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: aggregateStats,
            sharedAllocationAccumulator: SharedAllocationOwnerAccumulator(sharedAllocationClaims),
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
    }

    nonisolated static func deduplicatedStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        sharedAllocationAccumulator: SharedAllocationOwnerAccumulator,
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        let duplicateAllocatedSizeByOwner = sharedAllocationAccumulator.duplicateAllocatedSizeByOwner
        guard !duplicateAllocatedSizeByOwner.isEmpty else {
            return FileTreeStore(
                verifiedRootID: rootID,
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                aggregateStats: aggregateStats
            )
        }

        var nodesByID = inputNodesByID
        var childIDsByID = inputChildIDsByID
        var changedNodeIDs: Set<String> = []

        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            guard let node = nodesByID[nodeID] else { continue }
            let minimumAllocatedSize = minimumAllocatedSizeByNodeID[nodeID] ?? 0
            let allocatedSize = max(minimumAllocatedSize, node.allocatedSize - duplicateAllocatedSize)
            nodesByID[nodeID] = node.replacingAllocatedSize(allocatedSize)
            changedNodeIDs.insert(nodeID)
        }

        rebuildAffectedAncestorDirectories(
            for: changedNodeIDs,
            nodesByID: &nodesByID,
            childIDsByID: &childIDsByID,
            parentIDByID: parentIDByID,
            cancellationCheck: {}
        )

        let root = nodesByID[rootID] ?? inputNodesByID[rootID]
        let deduplicatedStats = ScanAggregateStats(
            totalAllocatedSize: root?.allocatedSize ?? aggregateStats.totalAllocatedSize,
            totalLogicalSize: root?.logicalSize ?? aggregateStats.totalLogicalSize,
            fileCount: aggregateStats.fileCount,
            directoryCount: aggregateStats.directoryCount,
            accessibleItemCount: aggregateStats.accessibleItemCount,
            inaccessibleItemCount: aggregateStats.inaccessibleItemCount
        )

        return FileTreeStore(
            verifiedRootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            aggregateStats: deduplicatedStats
        )
    }

    nonisolated static func deduplicatedNode(
        _ node: FileNodeRecord,
        duplicateAllocatedSize: Int64,
        minimumAllocatedSize: Int64
    ) -> FileNodeRecord {
        let allocatedSize = max(
            minimumAllocatedSize,
            node.allocatedSize - duplicateAllocatedSize
        )
        guard allocatedSize != node.allocatedSize else { return node }
        return node.replacingAllocatedSize(allocatedSize)
    }

    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var claimNodeIndices: [FileTreeNodeIndex] = []

        for (offset, nodeIndex) in store.indexedNodeIndices().enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard let node = store.node(at: nodeIndex),
                  let claim = claim(for: node) else {
                continue
            }
            sharedAllocationAccumulator.record(claim)
            claimNodeIndices.append(nodeIndex)
        }

        return try rebalancedStore(
            store,
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: claimNodeIndices,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        sharedAllocationAccumulator: SharedAllocationOwnerAccumulator,
        claimNodeIndices: [FileTreeNodeIndex],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        let replacements = try rebalancedAllocatedSizeReplacements(
            sharedAllocationAccumulator: sharedAllocationAccumulator,
            claimNodeIndices: claimNodeIndices,
            nodeAt: { nodeIndex in
                guard let node = store.node(at: nodeIndex) else {
                    preconditionFailure("Shared-allocation claim index is out of range.")
                }
                return node
            },
            cancellationCheck: cancellationCheck
        )
        guard !replacements.isEmpty else { return store }

        return try store.replacingAllocatedSizes(
            replacements,
            cancellationCheck: cancellationCheck
        )
    }

    nonisolated static func rebalancedAllocatedSizeReplacements(
        sharedAllocationAccumulator: SharedAllocationOwnerAccumulator,
        claimNodeIndices: [FileTreeNodeIndex],
        nodeAt: (FileTreeNodeIndex) -> FileNodeRecord,
        cancellationCheck: () throws -> Void
    ) throws -> [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)] {
        guard !sharedAllocationAccumulator.isEmpty else { return [] }

        let duplicateAllocatedSizeByOwner = try sharedAllocationAccumulator.duplicateAllocatedSizeByOwner(
            cancellationCheck: cancellationCheck
        )
        var replacements: [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)] = []
        for (offset, nodeIndex) in claimNodeIndices.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let node = nodeAt(nodeIndex)
            let duplicateAllocatedSize = duplicateAllocatedSizeByOwner[node.id] ?? 0
            let targetAllocatedSize = max(
                0,
                node.unduplicatedAllocatedSize - duplicateAllocatedSize
            )
            guard node.allocatedSize != targetAllocatedSize else { continue }
            replacements.append((nodeIndex, targetAllocatedSize))
        }
        return replacements
    }

    private nonisolated static func rebuildAffectedAncestorDirectories(
        for changedNodeIDs: Set<String>,
        nodesByID: inout [String: FileNodeRecord],
        childIDsByID: inout [String: [String]],
        parentIDByID: [String: String],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        let affectedDirectoryIDs = affectedAncestorDirectoryIDs(
            for: changedNodeIDs,
            nodesByID: nodesByID,
            parentIDByID: parentIDByID
        )
        for nodeID in affectedDirectoryIDs {
            try cancellationCheck()
            guard let node = nodesByID[nodeID], node.isDirectory else { continue }
            let children = (childIDsByID[nodeID] ?? []).compactMap { nodesByID[$0] }
            let sortedChildren = FileTreeStore.sortedChildren(children)
            nodesByID[nodeID] = FileNodeRecord.directory(
                id: node.id,
                url: node.url,
                name: node.name,
                children: sortedChildren,
                lastModified: node.lastModified,
                fileIdentity: node.fileIdentity,
                linkCount: node.linkCount,
                isPackage: node.isPackage,
                isAccessible: node.isSelfAccessible
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
        }
    }

    nonisolated static func claim(for node: FileNodeRecord) -> SharedAllocationClaim? {
        guard !node.isDirectory,
              !node.isSymbolicLink,
              !node.isSynthetic else {
            return nil
        }

        let hardLinkIdentity = node.linkCount > 1 ? node.fileIdentity : nil
        guard hardLinkIdentity != nil || node.cloneIdentity != nil else {
            return nil
        }

        return SharedAllocationClaim(
            fileIdentity: node.fileIdentity,
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: node.cloneIdentity,
            ownerNodeID: node.id,
            path: node.url.path,
            allocatedSize: node.unduplicatedAllocatedSize,
            cloneAllocatedSize: node.dataAllocatedSize
        )
    }

    private nonisolated static func affectedAncestorDirectoryIDs(
        for changedNodeIDs: Set<String>,
        nodesByID: [String: FileNodeRecord],
        parentIDByID: [String: String]
    ) -> [String] {
        guard !changedNodeIDs.isEmpty else { return [] }

        var affectedDirectoryIDs = Set<String>()
        var visitedAncestorIDs = Set<String>()
        for changedNodeID in changedNodeIDs {
            var cursor = parentIDByID[changedNodeID]
            while let currentID = cursor {
                guard visitedAncestorIDs.insert(currentID).inserted else { break }
                if nodesByID[currentID]?.isDirectory == true {
                    affectedDirectoryIDs.insert(currentID)
                }
                cursor = parentIDByID[currentID]
            }
        }

        var depthByDirectoryID: [String: Int] = [:]
        depthByDirectoryID.reserveCapacity(affectedDirectoryIDs.count)
        for directoryID in affectedDirectoryIDs {
            depthByDirectoryID[directoryID] = treeDepth(of: directoryID, parentIDByID: parentIDByID)
        }

        return affectedDirectoryIDs.sorted { lhs, rhs in
            let lhsDepth = depthByDirectoryID[lhs] ?? 0
            let rhsDepth = depthByDirectoryID[rhs] ?? 0
            if lhsDepth == rhsDepth {
                return lhs < rhs
            }
            return lhsDepth > rhsDepth
        }
    }

    private nonisolated static func treeDepth(
        of nodeID: String,
        parentIDByID: [String: String]
    ) -> Int {
        var depth = 0
        var cursor = nodeID

        while let parentID = parentIDByID[cursor] {
            depth += 1
            cursor = parentID
        }

        return depth
    }
}

nonisolated struct SharedAllocationClaim: Sendable {
    let fileIdentity: FileIdentity?
    let hardLinkIdentity: FileIdentity?
    let cloneIdentity: CloneIdentity?
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
    let cloneAllocatedSize: Int64

    init(
        identity: FileIdentity,
        ownerNodeID: String,
        path: String,
        allocatedSize: Int64
    ) {
        self.init(
            fileIdentity: identity,
            hardLinkIdentity: identity,
            cloneIdentity: nil,
            ownerNodeID: ownerNodeID,
            path: path,
            allocatedSize: allocatedSize,
            cloneAllocatedSize: 0
        )
    }

    init(
        fileIdentity: FileIdentity?,
        hardLinkIdentity: FileIdentity?,
        cloneIdentity: CloneIdentity?,
        ownerNodeID: String,
        path: String,
        allocatedSize: Int64,
        cloneAllocatedSize: Int64
    ) {
        self.fileIdentity = fileIdentity
        self.hardLinkIdentity = hardLinkIdentity
        self.cloneIdentity = cloneIdentity
        self.ownerNodeID = ownerNodeID
        self.path = path
        self.allocatedSize = allocatedSize
        self.cloneAllocatedSize = min(max(cloneAllocatedSize, 0), max(allocatedSize, 0))
    }
}
