import Foundation

nonisolated enum ScanSnapshotTransformError: Error, Sendable {
    case sharedAllocationRequiresFullScan
}

nonisolated protocol ScanSnapshotTransforming: Sendable {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot?

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot?

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot?

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot?
}

actor ScanSnapshotTransformService {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) async throws -> ScanSnapshot? {
        return try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func replacingNodeForSubtreeRescan(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = [],
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) async throws -> ScanSnapshot? {
        if try snapshot.treeStore.subtreeContainsSharedAllocationMetadata(
            rootedAt: targetID,
            cancellationCheck: { try Task.checkCancellation() }
        ) || replacement.subtreeContainsSharedAllocationMetadata(
            rootedAt: replacement.rootID,
            cancellationCheck: { try Task.checkCancellation() }
        ) {
            throw ScanSnapshotTransformError.sharedAllocationRequiresFullScan
        }
        return try await replacingNode(
            in: snapshot,
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings
        )?.updatedAfterSubtreeRescan(
            finishedAt: Date(),
            volumeCapacity: volumeCapacity,
            reconcilesVolumeCapacity: reconcilesVolumeCapacity
        )
    }

    func removingNodes(
        in snapshot: ScanSnapshot,
        ids targetIDs: [String]
    ) async throws -> ScanSnapshot? {
        try snapshot.removingNodes(
            ids: targetIDs,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try snapshot.scoped(
            to: target,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

extension ScanSnapshotTransformService: ScanSnapshotTransforming {}
