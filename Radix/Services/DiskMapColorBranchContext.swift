import Foundation

nonisolated struct DiskMapColorBranch {
    let id: String
    let index: Int
    let count: Int
}

/// Keeps global color positions while retaining lookup entries only for branches
/// used by this layout. Focused layouts need just their containing root branch.
nonisolated struct DiskMapColorBranchContext {
    private let indexByID: [String: Int]
    private let focusedBranchID: String?
    private let count: Int

    init(
        in treeStore: some DiskMapTreeReading,
        layoutRootID: String,
        layoutRootChildren: [FileNodeRecord],
        visibleNodeIDs: some Sequence<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        var retainedBranchIDs = Set<String>()
        var focusedBranchID: String?
        if layoutRootID == treeStore.rootID {
            for id in visibleNodeIDs {
                try cancellationCheck()
                retainedBranchIDs.insert(id)
            }
        } else if visibleNodeIDs.contains(where: { _ in true }) {
            let branchID = try Self.topLevelBranchID(
                for: layoutRootID, in: treeStore, cancellationCheck: cancellationCheck
            )
            focusedBranchID = branchID
            retainedBranchIDs.insert(branchID)
        }

        var indexByID: [String: Int] = [:]
        var branchCount = 0
        // Aggregate-only layouts never consult branch positions.
        if !retainedBranchIDs.isEmpty {
            let rootChildren = layoutRootID == treeStore.rootID
                ? layoutRootChildren
                : try treeStore.children(of: treeStore.rootID, cancellationCheck: cancellationCheck)
            indexByID.reserveCapacity(retainedBranchIDs.count)
            for child in rootChildren {
                try cancellationCheck()
                guard !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(child.id) else { continue }
                if retainedBranchIDs.contains(child.id) {
                    indexByID[child.id] = branchCount
                }
                branchCount += 1
            }
        }
        self.indexByID = indexByID
        self.focusedBranchID = focusedBranchID
        self.count = max(branchCount, 1)
    }

    func branch(forNodeID nodeID: String?) -> DiskMapColorBranch? {
        guard let nodeID else { return nil }
        let branchID = focusedBranchID ?? nodeID
        guard let index = indexByID[branchID] else { return nil }
        return DiskMapColorBranch(id: branchID, index: index, count: count)
    }

    private static func topLevelBranchID(
        for nodeID: String,
        in treeStore: some DiskMapTreeReading,
        cancellationCheck: () throws -> Void
    ) throws -> String {
        var currentID = nodeID
        while true {
            try cancellationCheck()
            guard let parentID = treeStore.parentID(of: currentID) else { return nodeID }
            if parentID == treeStore.rootID { return currentID }
            currentID = parentID
        }
    }
}
