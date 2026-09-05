//
//  VolumeCapacityAccounting.swift
//  Radix
//

import Foundation

nonisolated enum VolumeCapacityAccounting {
    private static let unattributedSuffix = "#system-unattributed"
    private static let minimumNewRemainder: Int64 = 64 * 1_024 * 1_024

    static func overlappingAllocatedBytes(
        in treeStore: FileTreeStore,
        capacity: VolumeCapacitySnapshot?
    ) -> Int64? {
        guard let capacity else { return nil }
        let overlap = treeStore.root.allocatedSize - capacity.usedCapacity
        return overlap >= minimumNewRemainder ? overlap : nil
    }

    static func reconciledStore(
        _ treeStore: FileTreeStore,
        target: ScanTarget,
        capacity: VolumeCapacitySnapshot?,
        hasActiveExclusions: Bool
    ) -> FileTreeStore {
        guard target.kind == .volume, let capacity else { return treeStore }

        let root = treeStore.root
        let currentRootChildren = treeStore.children(of: root.id)
        let existingRemainder = currentRootChildren.first {
            isUnattributedNodeID($0.id)
        }
        let ordinaryChildren = currentRootChildren.filter {
            !isUnattributedNodeID($0.id)
        }
        let scannedRoot = rebuiltRoot(root, children: ordinaryChildren)
        let missingBytes = max(capacity.usedCapacity - scannedRoot.allocatedSize, 0)
        let shouldIncludeRemainder = missingBytes >= minimumNewRemainder || existingRemainder != nil

        guard shouldIncludeRemainder, missingBytes > 0 else {
            let reconciledStats = adjustedStats(
                treeStore.aggregateStats,
                root: scannedRoot,
                removing: existingRemainder,
                adding: nil
            )
            if let existingRemainder,
               let updatedStore = treeStore.replacingRootLeaf(
                    removing: existingRemainder.id,
                    adding: nil,
                    root: scannedRoot,
                    orderedChildIDs: ordinaryChildren.map(\.id),
                    aggregateStats: reconciledStats
               ) {
                return updatedStore
            }
            if existingRemainder == nil,
               let updatedStore = treeStore.replacingRecordsPreservingTopology(
                    [scannedRoot],
                    orderedChildIDs: ordinaryChildren.map(\.id),
                    of: root.id,
                    aggregateStats: reconciledStats
               ) {
                return updatedStore
            }
            return rebuiltStore(
                treeStore,
                root: scannedRoot,
                children: ordinaryChildren,
                removing: existingRemainder,
                adding: nil
            )
        }

        let unattributedNode = FileNodeRecord(
            id: root.id + unattributedSuffix,
            url: target.url,
            name: hasActiveExclusions ? "Excluded & Unattributed" : "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let rootChildren = FileTreeStore.sortedChildren(ordinaryChildren + [unattributedNode])
        let reconciledRoot = rebuiltRoot(root, children: rootChildren)
        let reconciledStats = adjustedStats(
            treeStore.aggregateStats,
            root: reconciledRoot,
            removing: existingRemainder,
            adding: unattributedNode
        )
        if existingRemainder != nil {
            if let updatedStore = treeStore.replacingRecordsPreservingTopology(
                [reconciledRoot, unattributedNode],
                orderedChildIDs: rootChildren.map(\.id),
                of: root.id,
                aggregateStats: reconciledStats
            ) {
                return updatedStore
            }
        }
        if let updatedStore = treeStore.replacingRootLeaf(
            removing: existingRemainder?.id,
            adding: unattributedNode,
            root: reconciledRoot,
            orderedChildIDs: rootChildren.map(\.id),
            aggregateStats: reconciledStats
        ) {
            return updatedStore
        }
        return rebuiltStore(
            treeStore,
            root: reconciledRoot,
            children: rootChildren,
            removing: existingRemainder,
            adding: unattributedNode
        )
    }

    static func hasActiveExclusions(in treeStore: FileTreeStore) -> Bool {
        treeStore.children(of: treeStore.rootID).contains {
            isUnattributedNodeID($0.id) && $0.name == "Excluded & Unattributed"
        }
    }

    static func hasUnattributedRemainder(in treeStore: FileTreeStore) -> Bool {
        treeStore.children(of: treeStore.rootID).contains {
            isUnattributedNodeID($0.id)
        }
    }

    private static func isUnattributedNodeID(_ nodeID: String) -> Bool {
        nodeID.hasSuffix(unattributedSuffix)
    }

    private static func adjustedStats(
        _ existing: ScanAggregateStats,
        root: FileNodeRecord,
        removing removedLeaf: FileNodeRecord?,
        adding addedLeaf: FileNodeRecord?
    ) -> ScanAggregateStats {
        var accessibleItemCount = existing.accessibleItemCount
        var inaccessibleItemCount = existing.inaccessibleItemCount
        if let removedLeaf {
            if removedLeaf.isAccessible {
                accessibleItemCount -= 1
            } else {
                inaccessibleItemCount -= 1
            }
        }
        if let addedLeaf {
            if addedLeaf.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }
        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: existing.fileCount,
            directoryCount: existing.directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    private static func rebuiltStore(
        _ treeStore: FileTreeStore,
        root: FileNodeRecord,
        children: [FileNodeRecord],
        removing removedLeaf: FileNodeRecord?,
        adding addedLeaf: FileNodeRecord?
    ) -> FileTreeStore {
        var nodesByID = treeStore.nodesByID
        var childIDsByID = treeStore.childIDsByID
        if let removedLeaf {
            nodesByID.removeValue(forKey: removedLeaf.id)
            childIDsByID.removeValue(forKey: removedLeaf.id)
        }
        nodesByID[root.id] = root
        if let addedLeaf {
            nodesByID[addedLeaf.id] = addedLeaf
        }
        childIDsByID[root.id] = children.map(\.id)
        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
    }

    private static func rebuiltRoot(
        _ root: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: children,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible
        )
    }
}
