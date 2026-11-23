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
        var allocations = Rebalancer()
        for (offset, nodeIndex) in store.indexedNodeIndices().enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if let node = store.node(at: nodeIndex) {
                allocations.include(node, at: nodeIndex, summaries: store.summarizedAllocations)
            }
        }
        return try allocations.rebalancedStore(store, cancellationCheck: cancellationCheck)
    }

    /// Retains only the claims hidden inside an opaque directory and its own allocation floor.
    nonisolated struct Summary: Sendable {
        let claims: SharedAllocationOwnerAccumulator
        let minimumAllocatedSize: Int64

        init?(claims: SharedAllocationOwnerAccumulator, minimumAllocatedSize: Int64?) {
            guard !claims.summarizedMemberPaths.isEmpty, let minimumAllocatedSize else { return nil }
            self.claims = claims
            self.minimumAllocatedSize = minimumAllocatedSize
        }
    }

    nonisolated struct Rebalancer {
        private var accumulator = SharedAllocationOwnerAccumulator()
        private var claimNodeIndices: [FileTreeNodeIndex] = []
        private(set) var summaries: [String: Summary] = [:]

        mutating func include(
            _ node: FileNodeRecord,
            at index: FileTreeNodeIndex,
            summaries sourceSummaries: [String: Summary] = [:]
        ) {
            if node.isDirectory {
                guard let summary = sourceSummaries[node.id] else { return }
                accumulator.merge(summary.claims)
                summaries[node.id] = summary
            } else if let claim = SharedAllocationDeduplicator.claim(for: node) {
                accumulator.record(claim)
            } else {
                return
            }
            claimNodeIndices.append(index)
        }

        func rebalancedStore(
            _ store: FileTreeStore,
            cancellationCheck: () throws -> Void
        ) throws -> FileTreeStore {
            let replacements = try allocatedSizeReplacements(
                nodeAt: { nodeIndex in
                    guard let node = store.node(at: nodeIndex) else {
                        preconditionFailure("Shared-allocation claim index is out of range.")
                    }
                    return node
                },
                cancellationCheck: cancellationCheck
            )
            var result = try store.replacingAllocatedSizes(replacements, cancellationCheck: cancellationCheck)
            result.summarizedAllocations = summaries
            return result
        }

        func allocatedSizeReplacements(
            nodeAt: (FileTreeNodeIndex) -> FileNodeRecord,
            cancellationCheck: () throws -> Void
        ) throws -> [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)] {
            guard !accumulator.isEmpty else { return [] }

            let duplicates = try accumulator.duplicateAllocatedSizeByOwner(cancellationCheck: cancellationCheck)
            var replacements: [(nodeIndex: FileTreeNodeIndex, allocatedSize: Int64)] = []
            for (offset, nodeIndex) in claimNodeIndices.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                let node = nodeAt(nodeIndex)
                let minimum = node.isDirectory ? summaries[node.id]?.minimumAllocatedSize ?? 0 : 0
                let allocatedSize = max(minimum, node.unduplicatedAllocatedSize - (duplicates[node.id] ?? 0))
                if allocatedSize != node.allocatedSize {
                    replacements.append((nodeIndex, allocatedSize))
                }
            }
            return replacements
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
