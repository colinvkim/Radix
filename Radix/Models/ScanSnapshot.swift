//
//  ScanSnapshot.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated enum ScanWarningCategory: String, Hashable, Sendable {
    case permissionDenied
    case fileSystem
}

nonisolated struct ScanWarning: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let message: String
    let category: ScanWarningCategory
}

nonisolated struct ScanAggregateStats: Sendable {
    let totalAllocatedSize: Int64
    let totalLogicalSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let accessibleItemCount: Int
    let inaccessibleItemCount: Int

    nonisolated struct Accumulator {
        private var fileCount = 0
        private var directoryCount = 0
        private var accessibleItemCount = 0
        private var inaccessibleItemCount = 0

        @inline(__always)
        mutating func include(_ node: FileNodeRecord, hasMaterializedChildren: Bool) {
            if node.isDirectory {
                directoryCount = ScanIntegerMath.addingClamped(directoryCount, 1)
                // Descendants are counted individually when present in the tree.
                // A collapsed package or summary contributes its file count once.
                if !hasMaterializedChildren && (node.isPackage || node.isAutoSummarized) {
                    fileCount = ScanIntegerMath.addingClamped(fileCount, node.descendantFileCount)
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount = ScanIntegerMath.addingClamped(fileCount, 1)
            }

            if node.isAccessible {
                accessibleItemCount = ScanIntegerMath.addingClamped(accessibleItemCount, 1)
            } else {
                inaccessibleItemCount = ScanIntegerMath.addingClamped(inaccessibleItemCount, 1)
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
}

nonisolated struct VolumeCapacitySnapshot: Codable, Hashable, Sendable {
    let totalCapacity: Int64
    let availableCapacity: Int64

    nonisolated var usedCapacity: Int64 {
        max(totalCapacity - availableCapacity, 0)
    }
}

nonisolated enum ScanArchivePathMode: String, Codable, Sendable {
    case absolute

    var allowsArchivedPathCopy: Bool {
        switch self {
        case .absolute:
            return true
        }
    }
}

nonisolated enum ImportedSnapshotLiveActionCapability: String, Codable, Sendable {
    case disabled
    case pathValidation
}

nonisolated struct ImportedSnapshotContext: Sendable {
    let sourceURL: URL
    let importedAt: Date
    let pathMode: ScanArchivePathMode
    let liveActionCapability: ImportedSnapshotLiveActionCapability

    nonisolated init(
        sourceURL: URL,
        importedAt: Date = Date(),
        pathMode: ScanArchivePathMode,
        liveActionCapability: ImportedSnapshotLiveActionCapability
    ) {
        self.sourceURL = sourceURL
        self.importedAt = importedAt
        self.pathMode = pathMode
        self.liveActionCapability = liveActionCapability
    }
}

nonisolated enum ScanSnapshotSource: Sendable {
    case live
    case imported(ImportedSnapshotContext)

    nonisolated var isImported: Bool {
        if case .imported = self {
            return true
        }
        return false
    }

    nonisolated var allowsLivePathActions: Bool {
        switch self {
        case .live:
            return true
        case .imported(let context):
            return context.liveActionCapability == .pathValidation
        }
    }

    nonisolated var allowsArchivedPathCopy: Bool {
        switch self {
        case .live:
            return true
        case .imported(let context):
            return context.pathMode.allowsArchivedPathCopy
        }
    }

    nonisolated var allowsFileMutation: Bool {
        switch self {
        case .live:
            return true
        case .imported:
            return false
        }
    }
}

nonisolated struct ScanSnapshot: Identifiable, Sendable {
    let id: UUID
    let target: ScanTarget
    let treeStore: FileTreeStore
    let startedAt: Date
    let finishedAt: Date?
    let scanWarnings: [ScanWarning]
    let isComplete: Bool
    let scanOptions: ScanOptions?
    let volumeCapacity: VolumeCapacitySnapshot?
    let source: ScanSnapshotSource
    let incrementalCheckpoint: ScanIncrementalCheckpoint?

    nonisolated init(
        id: UUID = UUID(),
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        scanWarnings: [ScanWarning],
        isComplete: Bool,
        scanOptions: ScanOptions? = nil,
        volumeCapacity: VolumeCapacitySnapshot? = nil,
        source: ScanSnapshotSource = .live,
        incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
    ) {
        self.id = id
        self.target = target
        self.treeStore = treeStore
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scanWarnings = scanWarnings
        self.isComplete = isComplete
        self.scanOptions = scanOptions
        self.volumeCapacity = volumeCapacity
        self.source = source
        self.incrementalCheckpoint = source.allowsFileMutation ? incrementalCheckpoint : nil
    }

    nonisolated var root: FileNodeRecord {
        treeStore.root
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        treeStore.aggregateStats
    }

    nonisolated var overlappingAllocatedBytes: Int64? {
        VolumeCapacityAccounting.overlappingAllocatedBytes(
            in: treeStore,
            capacity: volumeCapacity
        )
    }

    nonisolated func removingNode(id targetID: String) -> ScanSnapshot? {
        try? removingNodes(ids: [targetID], cancellationCheck: {})
    }

    nonisolated func removingNode(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try removingNodes(ids: [targetID], cancellationCheck: cancellationCheck)
    }

    nonisolated func removingNodes(ids targetIDs: [String]) -> ScanSnapshot? {
        try? removingNodes(ids: targetIDs, cancellationCheck: {})
    }

    nonisolated func removingNodes(
        ids targetIDs: [String],
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        let removalIDs = treeStore.topLevelNodeIDs(from: targetIDs)
        guard !removalIDs.isEmpty, !removalIDs.contains(treeStore.rootID) else {
            return nil
        }

        let updatedStore: FileTreeStore
        if removalIDs.count == 1 {
            guard let removedStore = try treeStore.removingSubtree(
                id: removalIDs[0],
                cancellationCheck: cancellationCheck
            ) else { return nil }
            updatedStore = removedStore
        } else {
            updatedStore = try treeStore.removingSubtrees(
                rootedAt: removalIDs,
                cancellationCheck: cancellationCheck
            )
        }

        var retainedWarnings: [ScanWarning] = []
        retainedWarnings.reserveCapacity(scanWarnings.count)
        for warning in scanWarnings {
            try cancellationCheck()
            if !removalIDs.contains(where: { removalID in
                Self.path(warning.path, isContainedIn: removalID)
            }) {
                retainedWarnings.append(warning)
            }
        }

        let updatedSnapshot = ScanSnapshot(
            id: id,
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: retainedWarnings,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity,
            source: source,
            incrementalCheckpoint: incrementalCheckpoint
        )
        return updatedSnapshot.reconcilingVolumeCapacity()
    }

    nonisolated func replacingNode(
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) -> ScanSnapshot? {
        try? replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {}
        )
    }

    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning] = []
    ) -> ScanSnapshot? {
        try? replacingSubtrees(
            replacements,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {}
        )
    }

    /// Applies disjoint subtree rescans as one snapshot update. Warnings from
    /// replaced paths are stale and are pruned before the replacement scans'
    /// warnings are merged and deduplicated.
    nonisolated func replacingSubtrees(
        _ replacements: [String: FileTreeStore],
        additionalWarnings: [ScanWarning] = [],
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard !replacements.isEmpty else { return self }
        guard let updatedStore = try treeStore.replacingSubtrees(
            replacements,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        var retainedWarnings: [ScanWarning] = []
        retainedWarnings.reserveCapacity(scanWarnings.count)
        for warning in scanWarnings {
            try cancellationCheck()
            guard !replacements.keys.contains(where: { replacedRootPath in
                Self.path(warning.path, isContainedIn: replacedRootPath)
            }) else {
                continue
            }
            retainedWarnings.append(warning)
        }

        return ScanSnapshot(
            id: id,
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: Self.mergedWarnings(existing: retainedWarnings, additional: additionalWarnings),
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity,
            source: source,
            incrementalCheckpoint: incrementalCheckpoint
        )
    }

    nonisolated func replacingNode(
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = [],
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try replacingSubtrees(
            [targetID: replacement],
            additionalWarnings: additionalWarnings,
            cancellationCheck: cancellationCheck
        )
    }

    /// Marks a snapshot after one of its subtrees has been refreshed. The
    /// original scan identity and incremental checkpoint are retained because
    /// locations outside the replacement may still reflect the earlier scan.
    nonisolated func updatedAfterSubtreeRescan(
        finishedAt: Date,
        volumeCapacity: VolumeCapacitySnapshot?,
        reconcilesVolumeCapacity: Bool
    ) -> ScanSnapshot {
        let updatedCapacity = target.kind == .volume
            ? volumeCapacity ?? self.volumeCapacity
            : self.volumeCapacity
        let updatedStore: FileTreeStore
        if reconcilesVolumeCapacity {
            updatedStore = VolumeCapacityAccounting.reconciledStore(
                treeStore,
                target: target,
                capacity: updatedCapacity,
                hasActiveExclusions: scanOptions?.exclusionPatterns.isEmpty == false
                    || VolumeCapacityAccounting.hasActiveExclusions(in: treeStore)
            )
        } else {
            updatedStore = treeStore
        }

        return ScanSnapshot(
            id: id,
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scanWarnings,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: updatedCapacity,
            source: source,
            incrementalCheckpoint: incrementalCheckpoint
        )
    }

    nonisolated func scoped(to target: ScanTarget) -> ScanSnapshot? {
        try? scoped(to: target, cancellationCheck: {})
    }

    nonisolated func scoped(
        to target: ScanTarget,
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let scopedStore = try treeStore.logicalScope(
            rootedAt: target.id,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        var scopedWarnings: [ScanWarning] = []
        scopedWarnings.reserveCapacity(scanWarnings.count)
        for warning in scanWarnings {
            try cancellationCheck()
            if Self.path(warning.path, isContainedIn: target.id) {
                scopedWarnings.append(warning)
            }
        }

        return ScanSnapshot(
            target: target,
            treeStore: scopedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scopedWarnings,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity,
            source: source,
            incrementalCheckpoint: incrementalCheckpoint
        )
    }

    private nonisolated static func mergedWarnings(
        existing: [ScanWarning],
        additional: [ScanWarning]
    ) -> [ScanWarning] {
        var seen = Set<String>()
        var result: [ScanWarning] = []

        for warning in existing + additional {
            let key = [
                warning.category.rawValue,
                warning.path,
                warning.message,
            ].joined(separator: "\u{0}")
            if seen.insert(key).inserted {
                result.append(warning)
            }
        }

        return result
    }

    private nonisolated static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        guard rootPath != "/" else { return true }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private nonisolated func reconcilingVolumeCapacity() -> ScanSnapshot {
        guard target.kind == .volume,
              volumeCapacity != nil,
              VolumeCapacityAccounting.hasUnattributedRemainder(in: treeStore) else {
            return self
        }
        let reconciledStore = VolumeCapacityAccounting.reconciledStore(
            treeStore,
            target: target,
            capacity: volumeCapacity,
            hasActiveExclusions: VolumeCapacityAccounting.hasActiveExclusions(in: treeStore)
        )
        return ScanSnapshot(
            id: id,
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scanWarnings,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity,
            source: source,
            incrementalCheckpoint: incrementalCheckpoint
        )
    }
}
