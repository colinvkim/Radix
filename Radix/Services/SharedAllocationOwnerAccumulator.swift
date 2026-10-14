import Foundation

/// Assigns hard-linked storage to one path, then assigns each APFS clone
/// group's shared data-fork allocation to one distinct inode.
///
/// Hard links share every fork, while APFS clone IDs describe the data fork.
/// Keeping those stages separate preserves allocation that belongs only to a
/// clone's resource fork and prevents hard-linked paths from entering clone
/// accounting more than once.
///
/// Standalone clone claims are reduced without retaining per-file identities.
/// Callers must therefore record each standalone filesystem entry once and
/// merge only accumulators whose standalone entries are disjoint.
nonisolated struct SharedAllocationOwnerAccumulator: Sendable {
    private struct CloneWinner: Sendable {
        let ownerNodeID: String
        let path: String
        let cloneAllocatedSize: Int64
    }

    private var hardLinkWinnerByIdentity: [FileIdentity: SharedAllocationClaim] = [:]
    private var standaloneCloneWinnerByIdentity: [CloneIdentity: CloneWinner] = [:]
    private var hardLinkDuplicateAllocatedSizeByOwner: [String: Int64] = [:]
    private var standaloneCloneDuplicateAllocatedSizeByOwner: [String: Int64] = [:]

    nonisolated init() {}

    nonisolated init<S: Sequence>(_ claims: S) where S.Element == SharedAllocationClaim {
        record(contentsOf: claims)
    }

    nonisolated var duplicateAllocatedSizeByOwner: [String: Int64] {
        duplicateAllocatedSizeByOwner(cancellationCheck: {})
    }

    nonisolated func duplicateAllocatedSizeByOwner(
        cancellationCheck: () throws -> Void
    ) rethrows -> [String: Int64] {
        var corrections = hardLinkDuplicateAllocatedSizeByOwner
        for (offset, correction) in standaloneCloneDuplicateAllocatedSizeByOwner.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let (ownerNodeID, allocatedSize) = correction
            corrections[ownerNodeID, default: 0] += allocatedSize
        }
        var hardLinkCloneWinnerByIdentity: [CloneIdentity: CloneWinner] = [:]

        for (offset, claim) in hardLinkWinnerByIdentity.values.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard let cloneIdentity = claim.cloneIdentity,
                  claim.cloneAllocatedSize > 0 else {
                continue
            }
            if hardLinkCloneWinnerByIdentity[cloneIdentity] == nil,
               let standaloneWinner = standaloneCloneWinnerByIdentity[cloneIdentity] {
                hardLinkCloneWinnerByIdentity[cloneIdentity] = standaloneWinner
            }
            Self.recordCloneCorrection(
                identity: cloneIdentity,
                winner: CloneWinner(
                    ownerNodeID: claim.ownerNodeID,
                    path: claim.path,
                    cloneAllocatedSize: claim.cloneAllocatedSize
                ),
                winnerByIdentity: &hardLinkCloneWinnerByIdentity,
                corrections: &corrections
            )
        }
        return corrections
    }

    nonisolated var identityCount: Int {
        var cloneIdentities = Set<CloneIdentity>()
        for claim in hardLinkWinnerByIdentity.values {
            if let cloneIdentity = claim.cloneIdentity,
               claim.cloneAllocatedSize > 0 {
                cloneIdentities.insert(cloneIdentity)
            }
        }
        cloneIdentities.formUnion(standaloneCloneWinnerByIdentity.keys)
        return hardLinkWinnerByIdentity.count + cloneIdentities.count
    }

    nonisolated var isEmpty: Bool {
        hardLinkWinnerByIdentity.isEmpty && standaloneCloneWinnerByIdentity.isEmpty
    }

    nonisolated func winner(for identity: FileIdentity) -> SharedAllocationClaim? {
        hardLinkWinnerByIdentity[identity]
    }

    nonisolated mutating func record(_ claim: SharedAllocationClaim) {
        guard claim.allocatedSize > 0 else { return }

        if let hardLinkIdentity = claim.hardLinkIdentity {
            recordHardLink(claim, identity: hardLinkIdentity)
        } else if let cloneIdentity = claim.cloneIdentity,
                  claim.cloneAllocatedSize > 0 {
            Self.recordCloneCorrection(
                identity: cloneIdentity,
                winner: CloneWinner(
                    ownerNodeID: claim.ownerNodeID,
                    path: claim.path,
                    cloneAllocatedSize: claim.cloneAllocatedSize
                ),
                winnerByIdentity: &standaloneCloneWinnerByIdentity,
                corrections: &standaloneCloneDuplicateAllocatedSizeByOwner
            )
        }
    }

    nonisolated mutating func record<S: Sequence>(contentsOf claims: S) where S.Element == SharedAllocationClaim {
        for claim in claims {
            record(claim)
        }
    }

    /// Merges disjoint package-local state without reconstructing discarded claims.
    nonisolated mutating func merge(_ other: Self) {
        for (ownerNodeID, allocatedSize) in other.hardLinkDuplicateAllocatedSizeByOwner {
            hardLinkDuplicateAllocatedSizeByOwner[ownerNodeID, default: 0] += allocatedSize
        }
        for (ownerNodeID, allocatedSize) in other.standaloneCloneDuplicateAllocatedSizeByOwner {
            standaloneCloneDuplicateAllocatedSizeByOwner[ownerNodeID, default: 0] += allocatedSize
        }
        for winner in other.hardLinkWinnerByIdentity.values {
            record(winner)
        }
        for (identity, winner) in other.standaloneCloneWinnerByIdentity {
            Self.recordCloneCorrection(
                identity: identity,
                winner: winner,
                winnerByIdentity: &standaloneCloneWinnerByIdentity,
                corrections: &standaloneCloneDuplicateAllocatedSizeByOwner
            )
        }
    }

    private nonisolated mutating func recordHardLink(_ claim: SharedAllocationClaim, identity: FileIdentity) {
        guard let currentWinner = hardLinkWinnerByIdentity[identity] else {
            hardLinkWinnerByIdentity[identity] = claim
            return
        }

        if Self.precedes(claim, currentWinner) {
            addHardLinkDuplicate(currentWinner)
            hardLinkWinnerByIdentity[identity] = claim
        } else {
            addHardLinkDuplicate(claim)
        }
    }

    private nonisolated static func recordCloneCorrection(
        identity: CloneIdentity,
        winner: CloneWinner,
        winnerByIdentity: inout [CloneIdentity: CloneWinner],
        corrections: inout [String: Int64]
    ) {
        guard let currentWinner = winnerByIdentity[identity] else {
            winnerByIdentity[identity] = winner
            return
        }

        if precedes(winner, currentWinner) {
            corrections[currentWinner.ownerNodeID, default: 0] += currentWinner.cloneAllocatedSize
            winnerByIdentity[identity] = winner
        } else {
            corrections[winner.ownerNodeID, default: 0] += winner.cloneAllocatedSize
        }
    }

    private nonisolated static func precedes(_ lhs: CloneWinner, _ rhs: CloneWinner) -> Bool {
        if lhs.path == rhs.path {
            return lhs.ownerNodeID < rhs.ownerNodeID
        }
        return lhs.path < rhs.path
    }

    private nonisolated static func precedes(_ lhs: SharedAllocationClaim, _ rhs: SharedAllocationClaim) -> Bool {
        if lhs.path == rhs.path {
            return lhs.ownerNodeID < rhs.ownerNodeID
        }
        return lhs.path < rhs.path
    }

    private nonisolated mutating func addHardLinkDuplicate(_ claim: SharedAllocationClaim) {
        hardLinkDuplicateAllocatedSizeByOwner[claim.ownerNodeID, default: 0] += claim.allocatedSize
    }
}
