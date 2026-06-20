//
//  HardLinkDeduplicator.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated struct HardLinkDeduplicator {
    nonisolated static func claim(
        for metadata: NodeMetadata,
        ownerNodeID: String,
        path: String
    ) -> HardLinkClaim? {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.linkCount > 1,
              let fileIdentity = metadata.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: ownerNodeID,
            path: path,
            allocatedSize: metadata.allocatedSize
        )
    }

    nonisolated static func deduplicatedStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        let duplicateAllocatedSizeByOwner = duplicateHardLinkAllocatedSizeByOwner(from: hardLinkClaims)
        guard !duplicateAllocatedSizeByOwner.isEmpty else {
            return FileTreeStore(
                rootID: rootID,
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                parentIDByID: parentIDByID,
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

        let affectedDirectoryIDs = affectedAncestorDirectoryIDs(
            for: changedNodeIDs,
            nodesByID: nodesByID,
            parentIDByID: parentIDByID
        )
        for nodeID in affectedDirectoryIDs {
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
                isAccessible: node.isSelfAccessible,
                childrenAreSorted: true
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
        }

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
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: deduplicatedStats
        )
    }

    private nonisolated static func duplicateHardLinkAllocatedSizeByOwner(
        from claims: [HardLinkClaim]
    ) -> [String: Int64] {
        let claimsByIdentity = Dictionary(grouping: claims.filter { $0.allocatedSize > 0 }, by: \.identity)
        var duplicateAllocatedSizeByOwner: [String: Int64] = [:]

        for identityClaims in claimsByIdentity.values where identityClaims.count > 1 {
            let sortedClaims = identityClaims.sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.ownerNodeID < rhs.ownerNodeID
                }
                return lhs.path < rhs.path
            }

            for duplicateClaim in sortedClaims.dropFirst() {
                duplicateAllocatedSizeByOwner[duplicateClaim.ownerNodeID, default: 0] += duplicateClaim.allocatedSize
            }
        }

        return duplicateAllocatedSizeByOwner
    }

    private nonisolated static func affectedAncestorDirectoryIDs(
        for changedNodeIDs: Set<String>,
        nodesByID: [String: FileNodeRecord],
        parentIDByID: [String: String]
    ) -> [String] {
        guard !changedNodeIDs.isEmpty else { return [] }

        var affectedDirectoryIDs = Set<String>()
        for changedNodeID in changedNodeIDs {
            var cursor = parentIDByID[changedNodeID]
            while let currentID = cursor {
                if nodesByID[currentID]?.isDirectory == true {
                    affectedDirectoryIDs.insert(currentID)
                }
                cursor = parentIDByID[currentID]
            }
        }

        return affectedDirectoryIDs.sorted { lhs, rhs in
            let lhsDepth = treeDepth(of: lhs, parentIDByID: parentIDByID)
            let rhsDepth = treeDepth(of: rhs, parentIDByID: parentIDByID)
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

nonisolated struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}

private extension FileNodeRecord {
    nonisolated func replacingAllocatedSize(_ allocatedSize: Int64) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }
}
