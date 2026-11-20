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
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: metadata.cloneIdentity,
            ownerNodeID: ownerNodeID,
            path: path(),
            allocatedSize: metadata.allocatedSize,
            cloneAllocatedSize: metadata.dataAllocatedSize
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
        cancellationCheck: () throws -> Void
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
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: node.cloneIdentity,
            ownerNodeID: node.id,
            path: node.url.path,
            allocatedSize: node.unduplicatedAllocatedSize,
            cloneAllocatedSize: node.dataAllocatedSize
        )
    }

}

nonisolated struct SharedAllocationClaim: Sendable {
    let hardLinkIdentity: FileIdentity?
    let cloneIdentity: CloneIdentity?
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
    let cloneAllocatedSize: Int64

    init(
        hardLinkIdentity: FileIdentity?,
        cloneIdentity: CloneIdentity?,
        ownerNodeID: String,
        path: String,
        allocatedSize: Int64,
        cloneAllocatedSize: Int64
    ) {
        self.hardLinkIdentity = hardLinkIdentity
        self.cloneIdentity = cloneIdentity
        self.ownerNodeID = ownerNodeID
        self.path = path
        self.allocatedSize = allocatedSize
        self.cloneAllocatedSize = min(max(cloneAllocatedSize, 0), max(allocatedSize, 0))
    }
}
