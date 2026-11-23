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
    var availableCapacityForImportantUsage: Int64?

    var estimatedReclaimableCapacity: Int64? {
        guard availableCapacity >= 0,
              let availableCapacityForImportantUsage,
              availableCapacityForImportantUsage > availableCapacity else { return nil }
        return availableCapacityForImportantUsage - availableCapacity
    }

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

nonisolated struct ScanBrowserSource: Sendable {
    let snapshotID: UUID
    let treeStore: FileTreeStore

    fileprivate init(snapshot: ScanSnapshot) {
        snapshotID = snapshot.id
        treeStore = snapshot.treeStore
    }
}

nonisolated enum ScanDirectoryMaterialization: Sendable {
    case automatic
    case expandFully
    case preserving(ScanSnapshot)

    init(preserving baseline: ScanSnapshot?) {
        if let baseline, !baseline.expandedDirectories.isEmpty {
            self = .preserving(baseline)
        } else {
            self = .automatic
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
    var expandedDirectories: [String: Set<FileIdentity>]

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
        incrementalCheckpoint: ScanIncrementalCheckpoint? = nil,
        preservingExpansionsFrom baseline: ScanSnapshot? = nil
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
        self.expandedDirectories = baseline?.expandedDirectories(in: treeStore) ?? [:]
    }

    /// Each expansion freezes the identities of the directories it opened.
    /// Keep their ancestors traversable so the expanded contents remain reachable.
    func expandedDirectoryMatcher() -> (@Sendable (String, FileIdentity?) -> Bool)? {
        guard !expandedDirectories.isEmpty else { return nil }
        var memberships: [FileTreeNodeIndex: Set<FileIdentity>] = [:]
        var ancestorIDs: Set<String> = []
        for (id, members) in expandedDirectories {
            guard let index = treeStore.nodeIndex(id: id) else { continue }
            memberships[index] = members
            ancestorIDs.formUnion(treeStore.path(to: id).map(\.id))
        }
        return { [memberships, ancestorIDs] id, identity in
            guard let identity, wasMaterializedDirectory(id: id, identity: identity) else { return false }
            if ancestorIDs.contains(id) { return true }
            var cursor = treeStore.nodeIndex(id: id)
            while let index = cursor {
                if let members = memberships[index], let match = members.firstIndex(of: identity),
                   !members[match].hasConflictingTrashEvidence(with: identity) { return true }
                cursor = treeStore.parentIndex(of: index)
            }
            return false
        }
    }

    private func expandedDirectories(in tree: FileTreeStore) -> [String: Set<FileIdentity>] {
        guard !expandedDirectories.isEmpty, tree.contentID != treeStore.contentID else { return expandedDirectories }
        var retained: [String: Set<FileIdentity>] = [:]
        for (rootID, members) in expandedDirectories {
            let id = Self.path(tree.rootID, isContainedIn: rootID) ? tree.rootID : rootID
            guard let node = tree.node(id: id), node.isDirectory, !node.isAutoSummarized,
                  let identity = node.fileIdentity, members.contains(identity),
                  wasMaterializedDirectory(id: id, identity: identity) else { continue }
            if retained[id] == nil {
                retained[id] = members
            } else {
                retained[id]?.formUnion(members)
            }
        }
        return retained
    }

    private func wasMaterializedDirectory(id: String, identity: FileIdentity?) -> Bool {
        guard let identity, let node = treeStore.node(id: id), node.isDirectory, !node.isAutoSummarized,
              let original = node.fileIdentity else { return false }
        return original == identity && !original.hasConflictingTrashEvidence(with: identity)
    }

    nonisolated var root: FileNodeRecord {
        treeStore.root
    }

    nonisolated var browserSource: ScanBrowserSource {
        ScanBrowserSource(snapshot: self)
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
            incrementalCheckpoint: incrementalCheckpoint,
            preservingExpansionsFrom: self
        )
        return updatedSnapshot.reconcilingVolumeCapacity()
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
            incrementalCheckpoint: incrementalCheckpoint,
            preservingExpansionsFrom: self
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
            incrementalCheckpoint: incrementalCheckpoint,
            preservingExpansionsFrom: self
        )
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
            incrementalCheckpoint: incrementalCheckpoint,
            preservingExpansionsFrom: self
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
            incrementalCheckpoint: incrementalCheckpoint,
            preservingExpansionsFrom: self
        )
    }
}
