//
//  ScanComparisonService.swift
//  Radix
//

import Foundation

nonisolated enum ScanComparisonIntegerMath {
    static func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? .max : -.max
    }
}

nonisolated struct ComparedSnapshotSummary: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let rootPath: String
    let startedAt: Date
    let finishedAt: Date?
    let sourceURL: URL?

    init(snapshot: ScanSnapshot) {
        self.id = snapshot.id
        self.displayName = snapshot.target.displayName
        self.rootPath = snapshot.target.url.path
        self.startedAt = snapshot.startedAt
        self.finishedAt = snapshot.finishedAt
        if case .imported(let context) = snapshot.source {
            self.sourceURL = context.sourceURL
        } else {
            self.sourceURL = nil
        }
    }

    var comparisonDate: Date {
        finishedAt ?? startedAt
    }
}

nonisolated enum ScanComparisonChangeKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case added
    case removed
    case grew
    case shrank
    case moved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .added:
            return String(localized: "Added", comment: "Comparison change type for an item present only in the later scan.")
        case .removed:
            return String(localized: "Removed", comment: "Comparison change type for an item present only in the earlier scan.")
        case .grew:
            return String(localized: "Grew", comment: "Comparison change type for an item whose size increased.")
        case .shrank:
            return String(localized: "Shrank", comment: "Comparison change type for an item whose size decreased.")
        case .moved:
            return String(localized: "Moved", comment: "Comparison change type for an item whose location changed.")
        }
    }

    var sortRank: Int {
        switch self {
        case .added:
            return 0
        case .removed:
            return 1
        case .grew:
            return 2
        case .shrank:
            return 3
        case .moved:
            return 4
        }
    }
}

nonisolated struct ScanComparisonSummary: Equatable, Sendable {
    let beforeAllocatedSize: Int64
    let afterAllocatedSize: Int64
    let beforeLogicalSize: Int64
    let afterLogicalSize: Int64
    let beforeFileCount: Int
    let afterFileCount: Int
    let beforeDirectoryCount: Int
    let afterDirectoryCount: Int
    let beforeWarningCount: Int
    let afterWarningCount: Int
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int
    let movedCount: Int
    /// Sum of positive allocated deltas represented by the final, non-overlapping rows.
    let grossIncreasedAllocatedSize: Int64
    /// Sum of reclaimed allocated bytes represented by the final, non-overlapping rows.
    let grossReclaimedAllocatedSize: Int64

    init(
        before: ScanSnapshot,
        after: ScanSnapshot,
        addedCount: Int,
        removedCount: Int,
        grewCount: Int,
        shrankCount: Int,
        movedCount: Int,
        grossIncreasedAllocatedSize: Int64,
        grossReclaimedAllocatedSize: Int64
    ) {
        self.beforeAllocatedSize = before.aggregateStats.totalAllocatedSize
        self.afterAllocatedSize = after.aggregateStats.totalAllocatedSize
        self.beforeLogicalSize = before.aggregateStats.totalLogicalSize
        self.afterLogicalSize = after.aggregateStats.totalLogicalSize
        self.beforeFileCount = before.aggregateStats.fileCount
        self.afterFileCount = after.aggregateStats.fileCount
        self.beforeDirectoryCount = before.aggregateStats.directoryCount
        self.afterDirectoryCount = after.aggregateStats.directoryCount
        self.beforeWarningCount = before.scanWarnings.count
        self.afterWarningCount = after.scanWarnings.count

        self.addedCount = addedCount
        self.removedCount = removedCount
        self.grewCount = grewCount
        self.shrankCount = shrankCount
        self.movedCount = movedCount
        self.grossIncreasedAllocatedSize = grossIncreasedAllocatedSize
        self.grossReclaimedAllocatedSize = grossReclaimedAllocatedSize
    }

    var allocatedDelta: Int64 {
        afterAllocatedSize - beforeAllocatedSize
    }

    var logicalDelta: Int64 {
        afterLogicalSize - beforeLogicalSize
    }

    var fileCountDelta: Int {
        afterFileCount - beforeFileCount
    }

    var directoryCountDelta: Int {
        afterDirectoryCount - beforeDirectoryCount
    }

    var warningCountDelta: Int {
        afterWarningCount - beforeWarningCount
    }

    /// Items at the same relative path in both scans whose tracked size changed.
    var changedCount: Int {
        grewCount + shrankCount
    }

    /// Net allocated change that can be attributed to final comparison rows.
    ///
    /// This can differ from `allocatedDelta` when incomplete scan coverage suppresses uncertain
    /// additions, removals, or size changes.
    var attributedAllocatedDelta: Int64 {
        grossIncreasedAllocatedSize - grossReclaimedAllocatedSize
    }
}

nonisolated struct ScanComparisonRow: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let kind: ScanComparisonChangeKind
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let beforeAllocatedSize: Int64?
    let afterAllocatedSize: Int64?
    let beforeLogicalSize: Int64?
    let afterLogicalSize: Int64?
    let isDirectory: Bool
    let itemKind: String
    let beforeDescendantFileCount: Int?
    let afterDescendantFileCount: Int?
    let lastModified: Date?
    /// The former relative path for an unambiguous file move or rename.
    ///
    /// A non-`nil` value is only produced when the same `FileIdentity` appears exactly once
    /// among the visible removed paths and exactly once among the visible added paths.
    let movedFromRelativePath: String?

    init(
        relativePath: String,
        kind: ScanComparisonChangeKind,
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?,
        beforeAllocatedSize: Int64? = nil,
        afterAllocatedSize: Int64? = nil,
        movedFromRelativePath: String? = nil
    ) {
        let displayNode = afterNode ?? beforeNode
        self.id = if let movedFromRelativePath {
            "\(kind.rawValue):\(movedFromRelativePath)->\(relativePath)"
        } else {
            "\(kind.rawValue):\(relativePath)"
        }
        self.relativePath = relativePath
        self.name = displayNode?.name ?? URL(filePath: relativePath).lastPathComponent
        self.kind = kind
        self.beforeNode = beforeNode
        self.afterNode = afterNode
        self.beforeAllocatedSize = beforeNode.map { beforeAllocatedSize ?? $0.allocatedSize }
        self.afterAllocatedSize = afterNode.map { afterAllocatedSize ?? $0.allocatedSize }
        self.beforeLogicalSize = beforeNode?.logicalSize
        self.afterLogicalSize = afterNode?.logicalSize
        self.isDirectory = displayNode?.isDirectory ?? false
        self.itemKind = displayNode?.itemKind ?? "Item"
        self.beforeDescendantFileCount = beforeNode?.descendantFileCount
        self.afterDescendantFileCount = afterNode?.descendantFileCount
        self.lastModified = afterNode?.lastModified ?? beforeNode?.lastModified
        self.movedFromRelativePath = movedFromRelativePath
    }

    var allocatedDelta: Int64 {
        (afterAllocatedSize ?? 0) - (beforeAllocatedSize ?? 0)
    }

    var logicalDelta: Int64 {
        (afterLogicalSize ?? 0) - (beforeLogicalSize ?? 0)
    }

    var absoluteAllocatedDelta: Int64 {
        abs(allocatedDelta)
    }

    /// The filesystem location this row points at — the after node when present (added, grew,
    /// shrank), otherwise the before node (removed). Used for Finder reveal and path copy.
    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }
}

/// A non-overlapping, top-level attribution of the comparison rows.
///
/// Each final comparison row belongs to exactly one location: its first relative-path
/// component. This lets the UI rank locations without summing a directory and its changed
/// descendants twice. A move belongs to its destination location.
nonisolated struct ScanComparisonLocationChange: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let allocatedDelta: Int64
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int
    let movedCount: Int
    /// A changed row within this location, chosen by the largest absolute allocated delta.
    let representativeRelativePath: String
    /// The node at `relativePath` in the before snapshot, when it was indexed.
    let beforeNode: FileNodeRecord?
    /// The node at `relativePath` in the after snapshot, when it was indexed.
    let afterNode: FileNodeRecord?

    /// Non-overlapping comparison rows attributed to this location.
    var affectedCount: Int {
        addedCount + removedCount + grewCount + shrankCount + movedCount
    }

    var absoluteAllocatedDelta: Int64 {
        abs(allocatedDelta)
    }

    var grossChangedAllocatedSize: Int64 {
        ScanComparisonIntegerMath.addingClamped(increasedAllocatedSize, reclaimedAllocatedSize)
    }

    /// Prefer the current node so an overview can navigate to the location in the active scan.
    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }
}

/// Inclusive change totals for one path in the comparison hierarchy.
///
/// Every final, non-overlapping evidence row contributes to each of its path ancestors. Growth
/// and reclamation remain separate so a high-churn, zero-net folder cannot disappear.
nonisolated struct ScanComparisonAggregateChange: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let name: String
    let parentPath: String?
    let childPaths: [String]
    let directChangeKind: ScanComparisonChangeKind?
    let beforeNode: FileNodeRecord?
    let afterNode: FileNodeRecord?
    let increasedAllocatedSize: Int64
    let reclaimedAllocatedSize: Int64
    let addedCount: Int
    let removedCount: Int
    let grewCount: Int
    let shrankCount: Int
    let movedCount: Int
    let increasedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64]
    let reclaimedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64]

    var allocatedDelta: Int64 {
        increasedAllocatedSize - reclaimedAllocatedSize
    }

    var grossChangedAllocatedSize: Int64 {
        ScanComparisonIntegerMath.addingClamped(increasedAllocatedSize, reclaimedAllocatedSize)
    }

    var affectedCount: Int {
        addedCount + removedCount + grewCount + shrankCount + movedCount
    }

    var isDirectory: Bool {
        (afterNode ?? beforeNode)?.isDirectory ?? !childPaths.isEmpty
    }

    var itemKind: String {
        (afterNode ?? beforeNode)?.itemKind ?? (isDirectory ? "Folder" : "Item")
    }

    var fileURL: URL? {
        (afterNode ?? beforeNode)?.url
    }

    func changeCount(for kind: ScanComparisonChangeKind) -> Int {
        switch kind {
        case .added: addedCount
        case .removed: removedCount
        case .grew: grewCount
        case .shrank: shrankCount
        case .moved: movedCount
        }
    }

    func includes(any changeKinds: Set<ScanComparisonChangeKind>) -> Bool {
        changeKinds.contains { changeCount(for: $0) > 0 }
    }

    func increasedAllocatedSize(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        changeKinds.reduce(0) {
            ScanComparisonIntegerMath.addingClamped(
                $0,
                increasedAllocatedSizeByKind[$1, default: 0]
            )
        }
    }

    func reclaimedAllocatedSize(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        changeKinds.reduce(0) {
            ScanComparisonIntegerMath.addingClamped(
                $0,
                reclaimedAllocatedSizeByKind[$1, default: 0]
            )
        }
    }

    func impact(for kind: ScanComparisonChangeKind) -> Int64 {
        if kind == .moved {
            return Int64(movedCount)
        }
        return ScanComparisonIntegerMath.addingClamped(
            increasedAllocatedSizeByKind[kind, default: 0],
            reclaimedAllocatedSizeByKind[kind, default: 0]
        )
    }

    func impact(for changeKinds: Set<ScanComparisonChangeKind>) -> Int64 {
        var storageImpact: Int64 = 0
        var hasStorageKind = false
        for kind in changeKinds where kind != .moved {
            hasStorageKind = true
            storageImpact = ScanComparisonIntegerMath.addingClamped(storageImpact, impact(for: kind))
        }
        if hasStorageKind { return storageImpact }
        return changeKinds.contains(.moved) ? Int64(movedCount) : 0
    }
}


nonisolated enum ScanComparisonConfidence: String, Equatable, Sendable {
    /// Both scans are complete, target the same root, use matching known options, and report
    /// no scan warnings.
    case high
    /// The comparison is usable, but warning coverage or unknown scan options limit certainty.
    case limited
    /// A fundamental mismatch means the result should be treated as forensic, not a baseline.
    case low
}

nonisolated enum ScanComparisonCoverageIssue: Hashable, Sendable {
    case differentTargets
    case differentScanOptions
    case unknownScanOptions
    case beforeIncomplete
    case afterIncomplete
    case beforeWarnings(Int)
    case afterWarnings(Int)
}

/// Facts about whether two snapshots cover comparable filesystem state.
///
/// This is deliberately descriptive rather than blocking: callers can reserve low-confidence
/// comparisons for an advanced workflow while still explaining why the result is uncertain.
nonisolated struct ScanComparisonCoverage: Equatable, Sendable {
    let confidence: ScanComparisonConfidence
    let issues: [ScanComparisonCoverageIssue]
    let beforeWarningCount: Int
    let afterWarningCount: Int
    let targetsMatch: Bool
    let scanOptionsMatch: Bool?
    let beforeIsComplete: Bool
    let afterIsComplete: Bool

    init(before: ScanSnapshot, after: ScanSnapshot) {
        self.beforeWarningCount = before.scanWarnings.count
        self.afterWarningCount = after.scanWarnings.count
        self.targetsMatch = before.target.id == after.target.id
        self.beforeIsComplete = before.isComplete
        self.afterIsComplete = after.isComplete

        switch (before.scanOptions, after.scanOptions) {
        case let (beforeOptions?, afterOptions?):
            self.scanOptionsMatch = beforeOptions == afterOptions
        default:
            self.scanOptionsMatch = nil
        }

        var issues: [ScanComparisonCoverageIssue] = []
        if !targetsMatch {
            issues.append(.differentTargets)
        }
        if scanOptionsMatch == false {
            issues.append(.differentScanOptions)
        } else if scanOptionsMatch == nil {
            issues.append(.unknownScanOptions)
        }
        if !beforeIsComplete {
            issues.append(.beforeIncomplete)
        }
        if !afterIsComplete {
            issues.append(.afterIncomplete)
        }
        if beforeWarningCount > 0 {
            issues.append(.beforeWarnings(beforeWarningCount))
        }
        if afterWarningCount > 0 {
            issues.append(.afterWarnings(afterWarningCount))
        }
        self.issues = issues

        if !targetsMatch || scanOptionsMatch == false || !beforeIsComplete || !afterIsComplete {
            self.confidence = .low
        } else if !issues.isEmpty {
            self.confidence = .limited
        } else {
            self.confidence = .high
        }
    }
}

nonisolated struct ScanComparison: Identifiable, Equatable, Sendable {
    let id: UUID
    let before: ComparedSnapshotSummary
    let after: ComparedSnapshotSummary
    let summary: ScanComparisonSummary
    let coverage: ScanComparisonCoverage
    let rows: [ScanComparisonRow]
    /// Inclusive path rollups built from the final, non-overlapping evidence rows.
    let changeTree: ScanComparisonChangeTree
    /// Non-overlapping first-level locations derived from `rows`, ordered by impact.
    let topLevelChanges: [ScanComparisonLocationChange]

    init(
        beforeSnapshot: ScanSnapshot,
        afterSnapshot: ScanSnapshot,
        rows: [ScanComparisonRow],
        summary: ScanComparisonSummary,
        changeTree: ScanComparisonChangeTree,
        topLevelChanges: [ScanComparisonLocationChange]
    ) {
        self.id = UUID()
        self.before = ComparedSnapshotSummary(snapshot: beforeSnapshot)
        self.after = ComparedSnapshotSummary(snapshot: afterSnapshot)
        self.rows = rows
        self.summary = summary
        self.coverage = ScanComparisonCoverage(before: beforeSnapshot, after: afterSnapshot)
        self.changeTree = changeTree
        self.topLevelChanges = topLevelChanges
    }
}

nonisolated enum ScanComparisonProfilePhase: String, CaseIterable, Sendable {
    case prepareInputs = "prepare_inputs"
    case inspectSharedNodes = "inspect_shared_nodes"
    case hydrateAncestors = "hydrate_ancestors"
    case classifyPaths = "classify_paths"
    case buildRows = "build_rows"
    case sortRows = "sort_rows"
    case buildChangeTree = "build_change_tree"
    case buildTopLevelChanges = "build_top_level_changes"
    case finalize
}

nonisolated struct ScanComparisonService: Sendable {
    private let profileReporter: (@Sendable (ScanComparisonProfilePhase, Duration) -> Void)?

    init(
        profileReporter: (@Sendable (ScanComparisonProfilePhase, Duration) -> Void)? = nil
    ) {
        self.profileReporter = profileReporter
    }

    private func profileStart() -> ContinuousClock.Instant? {
        profileReporter == nil ? nil : ContinuousClock.now
    }

    private func finishProfile(
        _ phase: ScanComparisonProfilePhase,
        startedAt: ContinuousClock.Instant?
    ) {
        guard let profileReporter, let startedAt else { return }
        profileReporter(phase, startedAt.duration(to: .now))
    }

    func compare(before: ScanSnapshot, after: ScanSnapshot) async throws -> ScanComparison {
        if before.treeStore.rootID == after.treeStore.rootID {
            return try await compareSameRoot(before: before, after: after)
        }
        return try await compareByRelativePath(before: before, after: after)
    }

    private func compareByRelativePath(
        before: ScanSnapshot,
        after: ScanSnapshot
    ) async throws -> ScanComparison {
        let preparationStartedAt = profileStart()
        try Task.checkCancellation()
        async let beforeNodesTask = Self.indexedNodes(in: before)
        async let afterNodesTask = Self.indexedNodes(in: after)
        let (beforeNodes, afterNodes) = try await (beforeNodesTask, afterNodesTask)
        try Task.checkCancellation()
        async let allocatedSizesTask = Self.normalizedAllocatedSizes(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )

        let pathPartition = Self.partitionPaths(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        let allocatedSizes = await allocatedSizesTask
        finishProfile(.prepareInputs, startedAt: preparationStartedAt)
        return try makeComparison(
            before: before,
            after: after,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            pathPartition: pathPartition,
            allocatedSizes: allocatedSizes
        )
    }

    private func compareSameRoot(
        before: ScanSnapshot,
        after: ScanSnapshot
    ) async throws -> ScanComparison {
        let preparationStartedAt = profileStart()
        try Task.checkCancellation()
        let rootID = before.treeStore.rootID
        async let allocatedSizesTask = Self.normalizedAllocatedSizes(
            before: before,
            after: after
        )
        async let removedTask = Self.missingPathNodes(
            in: before.treeStore,
            absentFrom: after.treeStore,
            rootID: rootID
        )
        async let addedTask = Self.missingPathNodes(
            in: after.treeStore,
            absentFrom: before.treeStore,
            rootID: rootID
        )

        let (removed, added) = try await (removedTask, addedTask)
        let allocatedSizes = await allocatedSizesTask
        finishProfile(.prepareInputs, startedAt: preparationStartedAt)
        var beforeNodes = removed.nodes
        var afterNodes = added.nodes
        var sharedPaths: [String] = []

        let sharedInspectionStartedAt = profileStart()
        for nodeIndex in before.treeStore.indexedNodeIndices() {
            let offset = Int(nodeIndex.rawValue)
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let beforeNode = before.treeStore.node(at: nodeIndex),
                  beforeNode.id != rootID,
                  let afterNode = after.treeStore.node(id: beforeNode.id),
                  let relativePath = Self.relativePath(for: beforeNode.id, rootID: rootID) else {
                continue
            }
            let beforeSize = allocatedSizes.before[relativePath] ?? beforeNode.allocatedSize
            let afterSize = allocatedSizes.after[relativePath] ?? afterNode.allocatedSize
            guard beforeSize != afterSize else { continue }
            sharedPaths.append(relativePath)
            beforeNodes[relativePath] = beforeNode
            afterNodes[relativePath] = afterNode
        }
        finishProfile(.inspectSharedNodes, startedAt: sharedInspectionStartedAt)

        let ancestorHydrationStartedAt = profileStart()
        let pathPartition = PathPartition(
            added: added.paths,
            removed: removed.paths,
            shared: sharedPaths
        )
        let ancestorPaths = Self.changedPathAncestors(
            addedPaths: added.paths,
            removedPaths: removed.paths,
            sharedPaths: sharedPaths
        )
        Self.addNodes(
            at: ancestorPaths,
            from: before.treeStore,
            rootID: rootID,
            to: &beforeNodes
        )
        Self.addNodes(
            at: ancestorPaths,
            from: after.treeStore,
            rootID: rootID,
            to: &afterNodes
        )
        finishProfile(.hydrateAncestors, startedAt: ancestorHydrationStartedAt)

        return try makeComparison(
            before: before,
            after: after,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            pathPartition: pathPartition,
            allocatedSizes: allocatedSizes
        )
    }

    private func makeComparison(
        before: ScanSnapshot,
        after: ScanSnapshot,
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        pathPartition: PathPartition,
        allocatedSizes: (before: [String: Int64], after: [String: Int64])
    ) throws -> ScanComparison {
        let pathClassificationStartedAt = profileStart()
        let addedPaths = pathPartition.added
        let removedPaths = pathPartition.removed
        let sharedPaths = pathPartition.shared
        let materializationBoundaryPaths = Self.materializationBoundaryPaths(
            addedPaths: addedPaths,
            removedPaths: removedPaths,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            beforeStore: before.treeStore,
            afterStore: after.treeStore
        )
        let visibleAddedPaths = Self.visibleTopLevelPaths(
            in: addedPaths,
            excludingDescendantsOf: materializationBoundaryPaths,
            nodes: afterNodes,
            treeStore: after.treeStore
        )
        let visibleRemovedPaths = Self.visibleTopLevelPaths(
            in: removedPaths,
            excludingDescendantsOf: materializationBoundaryPaths,
            nodes: beforeNodes,
            treeStore: before.treeStore
        )
        let warningBoundaries = Self.warningBoundaryPaths(in: before)
            .union(Self.warningBoundaryPaths(in: after))
        let warningBoundaryIndex = RelativePathPrefixTree(paths: warningBoundaries)
        // A warning represents unknown coverage, never proof that a path was created or
        // deleted. Suppress a collapsed ancestor row too when it contains a warning boundary.
        let coveredAddedPaths = Set(visibleAddedPaths.filter { relativePath in
            !warningBoundaryIndex.overlaps(relativePath)
        })
        let coveredRemovedPaths = Set(visibleRemovedPaths.filter { relativePath in
            !warningBoundaryIndex.overlaps(relativePath)
        })
        let movedPathPairs = try Self.movedPathPairs(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes,
            removedPaths: coveredRemovedPaths,
            addedPaths: coveredAddedPaths,
            beforeVolumeToken: Self.darwinResourceIdentityComponents(before.root.fileIdentity)?.volumeToken,
            afterVolumeToken: Self.darwinResourceIdentityComponents(after.root.fileIdentity)?.volumeToken
        )
        let movedRemovedPaths = Set(movedPathPairs.map(\.beforeRelativePath))
        let movedAddedPaths = Set(movedPathPairs.map(\.afterRelativePath))
        finishProfile(.classifyPaths, startedAt: pathClassificationStartedAt)

        let rowBuildingStartedAt = profileStart()
        var rows: [ScanComparisonRow] = []
        rows.reserveCapacity(coveredAddedPaths.count + coveredRemovedPaths.count)

        for movedPathPair in movedPathPairs {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: movedPathPair.afterRelativePath,
                kind: .moved,
                beforeNode: beforeNodes[movedPathPair.beforeRelativePath],
                afterNode: afterNodes[movedPathPair.afterRelativePath],
                beforeAllocatedSize: allocatedSizes.before[movedPathPair.beforeRelativePath],
                afterAllocatedSize: allocatedSizes.after[movedPathPair.afterRelativePath],
                movedFromRelativePath: movedPathPair.beforeRelativePath
            ))
        }

        for relativePath in coveredAddedPaths.subtracting(movedAddedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .added,
                beforeNode: nil,
                afterNode: afterNodes[relativePath],
                afterAllocatedSize: allocatedSizes.after[relativePath]
            ))
        }

        for relativePath in coveredRemovedPaths.subtracting(movedRemovedPaths) {
            try Task.checkCancellation()
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: .removed,
                beforeNode: beforeNodes[relativePath],
                afterNode: nil,
                beforeAllocatedSize: allocatedSizes.before[relativePath]
            ))
        }

        for relativePath in sharedPaths {
            try Task.checkCancellation()
            guard let beforeNode = beforeNodes[relativePath],
                  let afterNode = afterNodes[relativePath] else {
                continue
            }
            let beforeAllocatedSize = allocatedSizes.before[relativePath] ?? beforeNode.allocatedSize
            let afterAllocatedSize = allocatedSizes.after[relativePath] ?? afterNode.allocatedSize
            let delta = afterAllocatedSize - beforeAllocatedSize
            guard delta != 0, !warningBoundaryIndex.overlaps(relativePath) else { continue }
            // A normal materialized directory's aggregate is already represented by descendant
            // additions, removals, and size changes. This includes a directory that was empty
            // in one snapshot and gained or lost indexed children in the other; emitting its
            // aggregate too would double-count those child rows. Opaque leaf directories remain
            // direct evidence because their descendants were not indexed.
            let beforeHasIndexedChildren = before.treeStore.containsChildren(id: beforeNode.id)
            let afterHasIndexedChildren = after.treeStore.containsChildren(id: afterNode.id)
            let beforeIsOpaque = Self.isOpaqueDirectory(
                beforeNode,
                hasIndexedChildren: beforeHasIndexedChildren
            )
            let afterIsOpaque = Self.isOpaqueDirectory(
                afterNode,
                hasIndexedChildren: afterHasIndexedChildren
            )
            let isRedundantDirectory = beforeNode.isDirectory && afterNode.isDirectory
                && !beforeIsOpaque
                && !afterIsOpaque
                && (beforeHasIndexedChildren || afterHasIndexedChildren)
            guard !isRedundantDirectory else { continue }
            rows.append(ScanComparisonRow(
                relativePath: relativePath,
                kind: delta > 0 ? .grew : .shrank,
                beforeNode: beforeNode,
                afterNode: afterNode,
                beforeAllocatedSize: beforeAllocatedSize,
                afterAllocatedSize: afterAllocatedSize
            ))
        }
        finishProfile(.buildRows, startedAt: rowBuildingStartedAt)

        try Task.checkCancellation()
        let rowSortingStartedAt = profileStart()
        let sortedRows = try ScanComparisonRowComparator.sorted(
            rows, using: ScanComparisonRowComparator.defaultSortOrder,
            cancellationCheck: { try Task.checkCancellation() }
        )
        finishProfile(.sortRows, startedAt: rowSortingStartedAt)

        let changeTreeStartedAt = profileStart()
        let changeTreeBuild = try Self.changeTree(
            from: sortedRows,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        finishProfile(.buildChangeTree, startedAt: changeTreeStartedAt)

        let topLevelChangesStartedAt = profileStart()
        let topLevelChanges = try Self.topLevelChanges(
            from: changeTreeBuild.topLevelAggregates,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
        finishProfile(.buildTopLevelChanges, startedAt: topLevelChangesStartedAt)

        let finalizationStartedAt = profileStart()
        let rowAggregate = changeTreeBuild.rowAggregate
        let summary = ScanComparisonSummary(
            before: before,
            after: after,
            addedCount: rowAggregate.addedCount,
            removedCount: rowAggregate.removedCount,
            grewCount: rowAggregate.grewCount,
            shrankCount: rowAggregate.shrankCount,
            movedCount: rowAggregate.movedCount,
            grossIncreasedAllocatedSize: rowAggregate.increasedAllocatedSize,
            grossReclaimedAllocatedSize: rowAggregate.reclaimedAllocatedSize
        )
        let comparison = ScanComparison(
            beforeSnapshot: before,
            afterSnapshot: after,
            rows: sortedRows,
            summary: summary,
            changeTree: changeTreeBuild.tree,
            topLevelChanges: topLevelChanges
        )
        finishProfile(.finalize, startedAt: finalizationStartedAt)
        return comparison
    }

    private struct PathPartition {
        var added: Set<String>
        var removed: Set<String>
        var shared: [String]
    }

    private struct MissingPathNodes: Sendable {
        var paths: Set<String> = []
        var nodes: [String: FileNodeRecord] = [:]
    }

    /// Partitions paths without first materializing complete key sets for both
    /// snapshots. The after-path set becomes the final added set as matches are
    /// removed, while only removed paths need a second set.
    private static func partitionPaths(
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) -> PathPartition {
        var added = Set(afterNodes.keys)
        var removed = Set<String>()
        removed.reserveCapacity(max(beforeNodes.count - afterNodes.count, 0))
        var shared: [String] = []
        shared.reserveCapacity(min(beforeNodes.count, afterNodes.count))

        for relativePath in beforeNodes.keys {
            if added.remove(relativePath) != nil {
                shared.append(relativePath)
            } else {
                removed.insert(relativePath)
            }
        }

        return PathPartition(added: added, removed: removed, shared: shared)
    }

    private static func missingPathNodes(
        in treeStore: FileTreeStore,
        absentFrom otherStore: FileTreeStore,
        rootID: String
    ) throws -> MissingPathNodes {
        var result = MissingPathNodes()
        for (position, nodeIndex) in treeStore.indexedNodeIndices().enumerated() {
            if position.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let node = treeStore.node(at: nodeIndex),
                  node.id != rootID,
                  otherStore.nodeIndex(id: node.id) == nil,
                  let relativePath = relativePath(for: node.id, rootID: rootID) else {
                continue
            }
            result.paths.insert(relativePath)
            result.nodes[relativePath] = node
        }
        return result
    }

    private static func addNodes(
        at relativePaths: Set<String>,
        from treeStore: FileTreeStore,
        rootID: String,
        to nodes: inout [String: FileNodeRecord]
    ) {
        for relativePath in relativePaths where nodes[relativePath] == nil {
            let id = nodeID(for: relativePath, rootID: rootID)
            nodes[relativePath] = treeStore.node(id: id)
        }
    }

    private static func nodeID(for relativePath: String, rootID: String) -> String {
        if rootID == "/" {
            return "/" + relativePath
        }
        return rootID + (rootID.hasSuffix("/") ? "" : "/") + relativePath
    }

    private static func indexedNodes(in snapshot: ScanSnapshot) throws -> [String: FileNodeRecord] {
        var nodesByRelativePath: [String: FileNodeRecord] = [:]
        nodesByRelativePath.reserveCapacity(max(snapshot.treeStore.nodeCount - 1, 0))

        for nodeIndex in snapshot.treeStore.indexedNodeIndices() {
            try Task.checkCancellation()
            guard let node = snapshot.treeStore.node(at: nodeIndex),
                  node.id != snapshot.treeStore.rootID,
                  let relativePath = Self.relativePath(for: node.id, rootID: snapshot.treeStore.rootID) else {
                continue
            }
            nodesByRelativePath[relativePath] = node
        }

        return nodesByRelativePath
    }

    static func relativePath(for nodeID: String, rootID: String) -> String? {
        guard nodeID != rootID else { return nil }

        if rootID == "/" {
            let relativePath = nodeID.trimmingPrefix("/")
            return relativePath.isEmpty ? nil : relativePath
        }

        let rootPrefix = rootID.hasSuffix("/") ? rootID : rootID + "/"
        guard nodeID.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(nodeID.dropFirst(rootPrefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func visibleTopLevelPaths(
        in paths: Set<String>,
        excludingDescendantsOf boundaryPaths: Set<String>,
        nodes: [String: FileNodeRecord],
        treeStore: FileTreeStore
    ) -> Set<String> {
        var ancestorIndices = Set<FileTreeNodeIndex>()
        ancestorIndices.reserveCapacity(paths.count + boundaryPaths.count)
        for relativePath in paths {
            if let node = nodes[relativePath],
               let nodeIndex = treeStore.nodeIndex(id: node.id) {
                ancestorIndices.insert(nodeIndex)
            }
        }
        for relativePath in boundaryPaths {
            if let node = nodes[relativePath],
               let nodeIndex = treeStore.nodeIndex(id: node.id) {
                ancestorIndices.insert(nodeIndex)
            }
        }

        return Set(paths.filter { relativePath in
            guard let node = nodes[relativePath],
                  let nodeIndex = treeStore.nodeIndex(id: node.id) else {
                return false
            }
            return !treeStore.hasAncestor(in: ancestorIndices, of: nodeIndex)
        })
    }

    private struct MovedPathPair: Sendable {
        let beforeRelativePath: String
        let afterRelativePath: String
    }

    private enum ComparableMoveIdentity: Hashable {
        case exact(FileIdentity)
        case darwin(volumeToken: UInt64, fileID: UInt64)
    }

    private struct DarwinResourceIdentityComponents {
        let fileID: UInt64
        let volumeToken: UInt64
    }

    private struct MoveCandidateOccurrence {
        let firstRelativePath: String
        var count: Int
    }

    /// Matches only a one-to-one regular-file identity that is visible as both a removal and an
    /// addition. Hard links, directories, aliases, and synthetic nodes are intentionally
    /// excluded because a path-level move inference would be ambiguous for them.
    private static func movedPathPairs(
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        removedPaths: Set<String>,
        addedPaths: Set<String>,
        beforeVolumeToken: UInt64?,
        afterVolumeToken: UInt64?
    ) throws -> [MovedPathPair] {
        let removedCandidates = try moveCandidateOccurrences(
            in: beforeNodes,
            paths: removedPaths,
            volumeToken: beforeVolumeToken
        )
        let addedCandidates = try moveCandidateOccurrences(
            in: afterNodes,
            paths: addedPaths,
            volumeToken: afterVolumeToken
        )

        var pairs = try removedCandidates.compactMap { identity, removedOccurrence -> MovedPathPair? in
            try Task.checkCancellation()
            guard removedOccurrence.count == 1,
                  let addedOccurrence = addedCandidates[identity],
                  addedOccurrence.count == 1 else {
                return nil
            }
            return MovedPathPair(
                beforeRelativePath: removedOccurrence.firstRelativePath,
                afterRelativePath: addedOccurrence.firstRelativePath
            )
        }
        return try CancellableSort.sorted(
            &pairs, cancellationCheck: { try Task.checkCancellation() }
        ) { lhs, rhs in
            lhs.afterRelativePath.localizedStandardCompare(rhs.afterRelativePath) == .orderedAscending
        }
    }

    private static func moveCandidateOccurrences(
        in nodes: [String: FileNodeRecord],
        paths: Set<String>,
        volumeToken: UInt64?
    ) throws -> [ComparableMoveIdentity: MoveCandidateOccurrence] {
        var occurrences: [ComparableMoveIdentity: MoveCandidateOccurrence] = [:]
        occurrences.reserveCapacity(paths.count)
        for relativePath in paths {
            try Task.checkCancellation()
            guard let node = nodes[relativePath],
                  let identity = moveIdentity(for: node, volumeToken: volumeToken) else {
                continue
            }
            if var occurrence = occurrences[identity] {
                occurrence.count += 1
                occurrences[identity] = occurrence
            } else {
                occurrences[identity] = MoveCandidateOccurrence(
                    firstRelativePath: relativePath,
                    count: 1
                )
            }
        }
        return occurrences
    }

    private static func moveIdentity(
        for node: FileNodeRecord,
        volumeToken: UInt64?
    ) -> ComparableMoveIdentity? {
        guard !node.isDirectory,
              !node.isSymbolicLink,
              !node.isSynthetic,
              node.linkCount == 1,
              let identity = node.fileIdentity else {
            return nil
        }

        switch identity {
        case .resourceIdentifier:
            guard let components = darwinResourceIdentityComponents(identity) else {
                return .exact(identity)
            }
            return .darwin(
                volumeToken: components.volumeToken,
                fileID: components.fileID
            )
        case .fileSystem(_, let inode):
            guard let volumeToken else { return .exact(identity) }
            return .darwin(volumeToken: volumeToken, fileID: inode)
        }
    }

    /// Darwin's persisted file resource identifier is a 16-byte pair containing
    /// the filesystem file ID followed by a stable volume token. Older Radix
    /// archives store this form, while bulk scans obtain the equivalent file ID
    /// directly from ATTR_CMN_FILEID. Reject unfamiliar encodings rather than
    /// making a speculative cross-version match.
    private static func darwinResourceIdentityComponents(
        _ identity: FileIdentity?
    ) -> DarwinResourceIdentityComponents? {
        guard case .resourceIdentifier(let data) = identity,
              data.count == MemoryLayout<UInt64>.size * 2 else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            let fileID = UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
            let volumeToken = UInt64(littleEndian: bytes.loadUnaligned(
                fromByteOffset: MemoryLayout<UInt64>.size,
                as: UInt64.self
            ))
            return DarwinResourceIdentityComponents(
                fileID: fileID,
                volumeToken: volumeToken
            )
        }
    }

    private struct AggregateAccumulator {
        let parentPath: String?
        var directChangeKind: ScanComparisonChangeKind?
        var representativeRelativePath: String?
        var allocatedDelta: Int64 = 0
        var increasedAllocatedSize: Int64 = 0
        var reclaimedAllocatedSize: Int64 = 0
        var addedCount = 0
        var removedCount = 0
        var grewCount = 0
        var shrankCount = 0
        var movedCount = 0
        var increasedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64] = [:]
        var reclaimedAllocatedSizeByKind: [ScanComparisonChangeKind: Int64] = [:]

        mutating func include(_ row: ScanComparisonRow, isDirect: Bool) {
            if representativeRelativePath == nil {
                representativeRelativePath = row.relativePath
            }
            if isDirect {
                directChangeKind = row.kind
            }
            allocatedDelta = ScanComparisonIntegerMath.addingClamped(
                allocatedDelta,
                row.allocatedDelta
            )
            if row.allocatedDelta > 0 {
                increasedAllocatedSize = ScanComparisonIntegerMath.addingClamped(
                    increasedAllocatedSize,
                    row.allocatedDelta
                )
                increasedAllocatedSizeByKind[row.kind, default: 0] =
                    ScanComparisonIntegerMath.addingClamped(
                        increasedAllocatedSizeByKind[row.kind, default: 0],
                        row.allocatedDelta
                    )
            } else if row.allocatedDelta < 0 {
                reclaimedAllocatedSize = ScanComparisonIntegerMath.addingClamped(
                    reclaimedAllocatedSize,
                    -row.allocatedDelta
                )
                reclaimedAllocatedSizeByKind[row.kind, default: 0] =
                    ScanComparisonIntegerMath.addingClamped(
                        reclaimedAllocatedSizeByKind[row.kind, default: 0],
                        -row.allocatedDelta
                    )
            }
            switch row.kind {
            case .added:
                addedCount += 1
            case .removed:
                removedCount += 1
            case .grew:
                grewCount += 1
            case .shrank:
                shrankCount += 1
            case .moved:
                movedCount += 1
            }
        }
    }

    private struct TopLevelAggregate {
        let relativePath: String
        let representativeRelativePath: String
        let allocatedDelta: Int64
        let increasedAllocatedSize: Int64
        let reclaimedAllocatedSize: Int64
        let addedCount: Int
        let removedCount: Int
        let grewCount: Int
        let shrankCount: Int
        let movedCount: Int
    }

    private struct ChangeTreeBuildOutput {
        let tree: ScanComparisonChangeTree
        let topLevelAggregates: [TopLevelAggregate]
        let rowAggregate: AggregateAccumulator
    }

    private struct RelativePathInterner {
        private struct Node {
            let path: String
            var children: [Substring: Int] = [:]
        }

        private var nodes = [Node(path: "")]

        var rootChildIndices: Dictionary<Substring, Int>.Values {
            nodes[0].children.values
        }

        var nodeIndices: Range<Int> {
            1..<nodes.count
        }

        func path(at index: Int) -> String {
            nodes[index].path
        }

        func childIndices(of index: Int) -> Dictionary<Substring, Int>.Values {
            nodes[index].children.values
        }

        mutating func intern(_ component: Substring, under parentIndex: Int) -> Int {
            if let index = nodes[parentIndex].children[component] {
                return index
            }

            let parentPath = nodes[parentIndex].path
            let path = parentPath.isEmpty
                ? String(component)
                : parentPath + "/" + component
            let index = nodes.count
            nodes.append(Node(path: path))
            nodes[parentIndex].children[component] = index
            return index
        }
    }

    /// Builds inclusive path rollups from the final evidence partition. Using the finalized rows
    /// is essential: raw directory sizes would double-count materialized descendants and bypass
    /// warning-boundary and hard-link normalization.
    private static func changeTree(
        from rows: [ScanComparisonRow],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) throws -> ChangeTreeBuildOutput {
        guard !rows.isEmpty else {
            return ChangeTreeBuildOutput(
                tree: .empty,
                topLevelAggregates: [],
                rowAggregate: AggregateAccumulator(parentPath: nil)
            )
        }
        var pathInterner = RelativePathInterner()
        var accumulators = [AggregateAccumulator(parentPath: nil)]
        accumulators.reserveCapacity(rows.count + 1)

        for row in rows {
            try Task.checkCancellation()
            accumulators[0].include(row, isDirect: false)
            let components = row.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            var parentIndex = 0
            var parentPath: String?
            for (index, component) in components.enumerated() {
                let pathIndex = pathInterner.intern(component, under: parentIndex)
                let path = pathInterner.path(at: pathIndex)
                if pathIndex == accumulators.count {
                    accumulators.append(AggregateAccumulator(parentPath: parentPath))
                }
                accumulators[pathIndex].include(row, isDirect: index == components.count - 1)

                parentPath = path
                parentIndex = pathIndex
            }
        }

        func nodeSort(_ lhsIndex: Int, _ rhsIndex: Int) -> Bool {
            let lhs = accumulators[lhsIndex]
            let rhs = accumulators[rhsIndex]
            let lhsGross = ScanComparisonIntegerMath.addingClamped(
                lhs.increasedAllocatedSize,
                lhs.reclaimedAllocatedSize
            )
            let rhsGross = ScanComparisonIntegerMath.addingClamped(
                rhs.increasedAllocatedSize,
                rhs.reclaimedAllocatedSize
            )
            if lhsGross != rhsGross { return lhsGross > rhsGross }
            return pathInterner.path(at: lhsIndex)
                .localizedStandardCompare(pathInterner.path(at: rhsIndex)) == .orderedAscending
        }

        var nodesByPath: [String: ScanComparisonAggregateChange] = [:]
        nodesByPath.reserveCapacity(accumulators.count - 1)
        for nodeIndex in pathInterner.nodeIndices {
            try Task.checkCancellation()
            let path = pathInterner.path(at: nodeIndex)
            let accumulator = accumulators[nodeIndex]
            guard accumulator.representativeRelativePath != nil else { continue }
            let displayNode = afterNodes[path] ?? beforeNodes[path]
            var childIndices = Array(pathInterner.childIndices(of: nodeIndex))
            let sortedChildren = try CancellableSort.sorted(
                &childIndices, cancellationCheck: { try Task.checkCancellation() }, by: nodeSort
            )
            let childPaths = try sortedChildren.map { index in
                try Task.checkCancellation()
                return pathInterner.path(at: index)
            }
            nodesByPath[path] = ScanComparisonAggregateChange(
                id: path,
                relativePath: path,
                name: displayNode?.name ?? URL(filePath: path).lastPathComponent,
                parentPath: accumulator.parentPath,
                childPaths: childPaths,
                directChangeKind: accumulator.directChangeKind,
                beforeNode: beforeNodes[path],
                afterNode: afterNodes[path],
                increasedAllocatedSize: accumulator.increasedAllocatedSize,
                reclaimedAllocatedSize: accumulator.reclaimedAllocatedSize,
                addedCount: accumulator.addedCount,
                removedCount: accumulator.removedCount,
                grewCount: accumulator.grewCount,
                shrankCount: accumulator.shrankCount,
                movedCount: accumulator.movedCount,
                increasedAllocatedSizeByKind: accumulator.increasedAllocatedSizeByKind,
                reclaimedAllocatedSizeByKind: accumulator.reclaimedAllocatedSizeByKind
            )
        }

        var unsortedRoots = Array(pathInterner.rootChildIndices)
        let rootIndices = try CancellableSort.sorted(
            &unsortedRoots, cancellationCheck: { try Task.checkCancellation() }, by: nodeSort
        )
        let rootPaths = try rootIndices.map { index in
            try Task.checkCancellation()
            return pathInterner.path(at: index)
        }
        let topLevelAggregates = try rootIndices.compactMap { rootIndex -> TopLevelAggregate? in
            try Task.checkCancellation()
            let accumulator = accumulators[rootIndex]
            guard let representativeRelativePath = accumulator.representativeRelativePath else {
                return nil
            }
            return TopLevelAggregate(
                relativePath: pathInterner.path(at: rootIndex),
                representativeRelativePath: representativeRelativePath,
                allocatedDelta: accumulator.allocatedDelta,
                increasedAllocatedSize: accumulator.increasedAllocatedSize,
                reclaimedAllocatedSize: accumulator.reclaimedAllocatedSize,
                addedCount: accumulator.addedCount,
                removedCount: accumulator.removedCount,
                grewCount: accumulator.grewCount,
                shrankCount: accumulator.shrankCount,
                movedCount: accumulator.movedCount
            )
        }
        return ChangeTreeBuildOutput(
            tree: ScanComparisonChangeTree(rootPaths: rootPaths, nodesByPath: nodesByPath),
            topLevelAggregates: topLevelAggregates,
            rowAggregate: accumulators[0]
        )
    }

    private static func topLevelChanges(
        from aggregates: [TopLevelAggregate],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) throws -> [ScanComparisonLocationChange] {
        let changes = try aggregates.map { aggregate in
            try Task.checkCancellation()
            let relativePath = aggregate.relativePath
            let beforeNode = beforeNodes[relativePath]
            let afterNode = afterNodes[relativePath]
            let displayNode = afterNode ?? beforeNode
            return ScanComparisonLocationChange(
                id: relativePath,
                relativePath: relativePath,
                name: displayNode?.name ?? URL(filePath: relativePath).lastPathComponent,
                allocatedDelta: aggregate.allocatedDelta,
                increasedAllocatedSize: aggregate.increasedAllocatedSize,
                reclaimedAllocatedSize: aggregate.reclaimedAllocatedSize,
                addedCount: aggregate.addedCount,
                removedCount: aggregate.removedCount,
                grewCount: aggregate.grewCount,
                shrankCount: aggregate.shrankCount,
                movedCount: aggregate.movedCount,
                representativeRelativePath: aggregate.representativeRelativePath,
                beforeNode: beforeNode,
                afterNode: afterNode
            )
        }
        return try CancellableSort.sortedByIndex(
            changes, cancellationCheck: { try Task.checkCancellation() }
        ) { lhs, rhs in
            if lhs.grossChangedAllocatedSize != rhs.grossChangedAllocatedSize {
                return lhs.grossChangedAllocatedSize > rhs.grossChangedAllocatedSize
            }
            if lhs.absoluteAllocatedDelta != rhs.absoluteAllocatedDelta {
                return lhs.absoluteAllocatedDelta > rhs.absoluteAllocatedDelta
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func warningBoundaryPaths(in snapshot: ScanSnapshot) -> Set<String> {
        Set(snapshot.scanWarnings.compactMap { warning in
            relativeWarningPath(warning.path, rootID: snapshot.treeStore.rootID)
        })
    }

    private static func relativeWarningPath(_ warningPath: String, rootID: String) -> String? {
        guard warningPath == rootID else {
            return relativePath(for: warningPath, rootID: rootID)
        }
        // An empty relative path represents a warning at the scan root and therefore affects
        // every addition/removal in the snapshot.
        return ""
    }

    private struct RelativePathPrefixTree {
        private struct Node {
            var isTerminal = false
            var children: [Substring: Int] = [:]
        }

        private var nodes = [Node()]

        init(paths: Set<String>) {
            for path in paths {
                insert(path)
            }
        }

        func overlaps(_ path: String) -> Bool {
            if nodes[0].isTerminal {
                return true
            }

            var nodeIndex = 0
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                guard let childIndex = nodes[nodeIndex].children[component] else {
                    return false
                }
                nodeIndex = childIndex
                if nodes[nodeIndex].isTerminal {
                    return true
                }
            }

            // A child means `path` is a collapsed ancestor of at least one
            // warning boundary, which is equally uncertain.
            return !nodes[nodeIndex].children.isEmpty
        }

        private mutating func insert(_ path: String) {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else {
                nodes[0].isTerminal = true
                return
            }

            var nodeIndex = 0
            for component in components {
                if let childIndex = nodes[nodeIndex].children[component] {
                    nodeIndex = childIndex
                    continue
                }

                let childIndex = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[component] = childIndex
                nodeIndex = childIndex
            }
            nodes[nodeIndex].isTerminal = true
        }
    }

    private static func materializationBoundaryPaths(
        addedPaths: Set<String>,
        removedPaths: Set<String>,
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        beforeStore: FileTreeStore,
        afterStore: FileTreeStore
    ) -> Set<String> {
        let candidatePaths = changedPathAncestors(
            addedPaths: addedPaths,
            removedPaths: removedPaths,
            sharedPaths: []
        )

        return Set(candidatePaths.filter { relativePath in
            guard let beforeNode = beforeNodes[relativePath],
                  let afterNode = afterNodes[relativePath] else {
                return false
            }
            // A file/directory replacement is represented by the shared path's delta.
            // Its indexed descendants must not also contribute additions or removals.
            if beforeNode.isDirectory != afterNode.isDirectory {
                return true
            }
            guard beforeNode.isDirectory else { return false }

            let beforeHasChildren = beforeStore.containsChildren(id: beforeNode.id)
            let afterHasChildren = afterStore.containsChildren(id: afterNode.id)
            guard beforeHasChildren != afterHasChildren else { return false }

            return Self.isOpaqueDirectory(beforeNode, hasIndexedChildren: beforeHasChildren)
                || Self.isOpaqueDirectory(afterNode, hasIndexedChildren: afterHasChildren)
        })
    }

    private static func changedPathAncestors(
        addedPaths: Set<String>,
        removedPaths: Set<String>,
        sharedPaths: [String]
    ) -> Set<String> {
        var candidatePaths = Set<String>()

        func includeAncestors(of relativePath: String) {
            var searchStart = relativePath.startIndex
            while let slashIndex = relativePath[searchStart...].firstIndex(of: "/") {
                let ancestorPath = String(relativePath[..<slashIndex])
                if !ancestorPath.isEmpty {
                    candidatePaths.insert(ancestorPath)
                }
                searchStart = relativePath.index(after: slashIndex)
            }
        }

        for relativePath in addedPaths {
            includeAncestors(of: relativePath)
        }
        for relativePath in removedPaths {
            includeAncestors(of: relativePath)
        }
        for relativePath in sharedPaths {
            includeAncestors(of: relativePath)
        }
        return candidatePaths
    }

    private static func isOpaqueDirectory(
        _ node: FileNodeRecord,
        hasIndexedChildren: Bool
    ) -> Bool {
        guard node.isDirectory, !hasIndexedChildren else { return false }
        return node.isAutoSummarized || node.isPackage || !node.isAccessible
    }

    private struct SharedAllocationReferences: Sendable {
        var hardLinkIdentities = Set<FileIdentity>()
        var cloneIdentities = Set<CloneIdentity>()
        var cloneMemberFileIdentities = Set<FileIdentity>()
        var cloneMemberPaths = Set<String>()

        var isEmpty: Bool {
            hardLinkIdentities.isEmpty && cloneIdentities.isEmpty
        }

        mutating func formUnion(_ other: Self) {
            hardLinkIdentities.formUnion(other.hardLinkIdentities)
            cloneIdentities.formUnion(other.cloneIdentities)
            cloneMemberFileIdentities.formUnion(other.cloneMemberFileIdentities)
            cloneMemberPaths.formUnion(other.cloneMemberPaths)
        }
    }

    private static func normalizedAllocatedSizes(
        before: ScanSnapshot,
        after: ScanSnapshot
    ) async -> (
        before: [String: Int64],
        after: [String: Int64]
    ) {
        async let beforeReferencesTask = sharedAllocationReferences(in: before)
        async let afterReferencesTask = sharedAllocationReferences(in: after)
        var references = await beforeReferencesTask
        references.formUnion(await afterReferencesTask)
        guard !references.isEmpty else { return ([:], [:]) }

        async let beforeNodesTask = sharedAllocationNodes(in: before, references: references)
        async let afterNodesTask = sharedAllocationNodes(in: after, references: references)
        let (beforeNodes, afterNodes) = await (beforeNodesTask, afterNodesTask)
        return await normalizedAllocatedSizes(
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        )
    }

    private static func sharedAllocationReferences(
        in snapshot: ScanSnapshot
    ) -> SharedAllocationReferences {
        var references = SharedAllocationReferences()
        for nodeIndex in snapshot.treeStore.indexedNodeIndices() {
            guard let node = snapshot.treeStore.node(at: nodeIndex),
                  !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic else {
                continue
            }
            if node.linkCount > 1, let identity = node.fileIdentity {
                references.hardLinkIdentities.insert(identity)
            }
            if let cloneIdentity = node.cloneIdentity,
               let path = relativePath(for: node.id, rootID: snapshot.treeStore.rootID) {
                references.cloneIdentities.insert(cloneIdentity)
                references.cloneMemberPaths.insert(path)
                if let fileIdentity = node.fileIdentity {
                    references.cloneMemberFileIdentities.insert(fileIdentity)
                }
            }
        }
        return references
    }

    private static func sharedAllocationNodes(
        in snapshot: ScanSnapshot,
        references: SharedAllocationReferences
    ) -> [String: FileNodeRecord] {
        var nodes: [String: FileNodeRecord] = [:]
        for nodeIndex in snapshot.treeStore.indexedNodeIndices() {
            guard let node = snapshot.treeStore.node(at: nodeIndex),
                  !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  let relativePath = relativePath(
                    for: node.id,
                    rootID: snapshot.treeStore.rootID
                  ) else {
                continue
            }
            let hasHardLinkIdentity = node.fileIdentity.map {
                references.hardLinkIdentities.contains($0)
            } ?? false
            let hasCloneIdentity = node.cloneIdentity.map {
                references.cloneIdentities.contains($0)
            } ?? false
            let hasCloneMemberIdentity = node.fileIdentity.map {
                references.cloneMemberFileIdentities.contains($0)
            } ?? false
            guard hasHardLinkIdentity
                    || hasCloneIdentity
                    || hasCloneMemberIdentity
                    || references.cloneMemberPaths.contains(relativePath) else {
                continue
            }
            nodes[relativePath] = node
        }
        let ancestorPaths = changedPathAncestors(
            addedPaths: Set(nodes.keys),
            removedPaths: [],
            sharedPaths: []
        )
        addNodes(
            at: ancestorPaths,
            from: snapshot.treeStore,
            rootID: snapshot.treeStore.rootID,
            to: &nodes
        )
        return nodes
    }

    private static func normalizedAllocatedSizes(
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) async -> (
        before: [String: Int64],
        after: [String: Int64]
    ) {
        async let beforeReferencesTask = sharedAllocationReferences(in: beforeNodes)
        async let afterReferencesTask = sharedAllocationReferences(in: afterNodes)
        var references = await beforeReferencesTask
        references.formUnion(await afterReferencesTask)
        guard !references.isEmpty else { return ([:], [:]) }

        async let beforeGroupsTask = hardLinkPathsByIdentity(
            in: beforeNodes,
            identities: references.hardLinkIdentities
        )
        async let afterGroupsTask = hardLinkPathsByIdentity(
            in: afterNodes,
            identities: references.hardLinkIdentities
        )
        let (beforeGroups, afterGroups) = await (beforeGroupsTask, afterGroupsTask)
        // Most scans contain few hard links compared with their total node count.
        // Keep only sizes changed by normalization instead of duplicating every
        // path and allocated-size value from both snapshots.
        var beforeSizes: [String: Int64] = [:]
        var afterSizes: [String: Int64] = [:]
        var beforeHardLinkOwners: [FileIdentity: String] = [:]
        var afterHardLinkOwners: [FileIdentity: String] = [:]

        for identity in references.hardLinkIdentities {
            let beforePaths = beforeGroups[identity] ?? []
            let afterPaths = afterGroups[identity] ?? []
            let sharedPaths = Set(beforePaths).intersection(afterPaths)

            if !sharedPaths.isEmpty, let ownerPath = sharedPaths.min() {
                beforeHardLinkOwners[identity] = ownerPath
                afterHardLinkOwners[identity] = ownerPath
                normalizeHardLinkGroup(
                    paths: beforePaths,
                    ownerPath: ownerPath,
                    nodes: beforeNodes,
                    sizes: &beforeSizes
                )
                normalizeHardLinkGroup(
                    paths: afterPaths,
                    ownerPath: ownerPath,
                    nodes: afterNodes,
                    sizes: &afterSizes
                )
            } else {
                if let ownerPath = beforePaths.min() {
                    beforeHardLinkOwners[identity] = ownerPath
                    normalizeHardLinkGroup(
                        paths: beforePaths,
                        ownerPath: ownerPath,
                        nodes: beforeNodes,
                        sizes: &beforeSizes
                    )
                }
                if let ownerPath = afterPaths.min() {
                    afterHardLinkOwners[identity] = ownerPath
                    normalizeHardLinkGroup(
                        paths: afterPaths,
                        ownerPath: ownerPath,
                        nodes: afterNodes,
                        sizes: &afterSizes
                    )
                }
            }
        }

        let beforeCloneGroups = clonePathsByIdentity(
            in: beforeNodes,
            hardLinkOwners: beforeHardLinkOwners
        )
        let afterCloneGroups = clonePathsByIdentity(
            in: afterNodes,
            hardLinkOwners: afterHardLinkOwners
        )
        let beforeRepresentativePaths = representativePathsByFileIdentity(
            in: beforeNodes,
            hardLinkOwners: beforeHardLinkOwners
        )
        let afterRepresentativePaths = representativePathsByFileIdentity(
            in: afterNodes,
            hardLinkOwners: afterHardLinkOwners
        )
        for identity in references.cloneIdentities {
            var beforePaths = beforeCloneGroups[identity] ?? []
            var afterPaths = afterCloneGroups[identity] ?? []
            addSingletonCloneCounterpart(
                to: &beforePaths,
                from: afterPaths,
                currentNodes: beforeNodes,
                otherNodes: afterNodes,
                representativePaths: beforeRepresentativePaths
            )
            addSingletonCloneCounterpart(
                to: &afterPaths,
                from: beforePaths,
                currentNodes: afterNodes,
                otherNodes: beforeNodes,
                representativePaths: afterRepresentativePaths
            )
            normalizeCloneGroups(
                beforePaths: beforePaths,
                afterPaths: afterPaths,
                beforeNodes: beforeNodes,
                afterNodes: afterNodes,
                beforeSizes: &beforeSizes,
                afterSizes: &afterSizes
            )
        }

        return (beforeSizes, afterSizes)
    }

    private static func sharedAllocationReferences(
        in nodes: [String: FileNodeRecord]
    ) -> SharedAllocationReferences {
        var references = SharedAllocationReferences()
        for (path, node) in nodes {
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic else {
                continue
            }
            if node.linkCount > 1, let identity = node.fileIdentity {
                references.hardLinkIdentities.insert(identity)
            }
            if let cloneIdentity = node.cloneIdentity {
                references.cloneIdentities.insert(cloneIdentity)
                references.cloneMemberPaths.insert(path)
                if let fileIdentity = node.fileIdentity {
                    references.cloneMemberFileIdentities.insert(fileIdentity)
                }
            }
        }
        return references
    }

    private static func hardLinkPathsByIdentity(
        in nodes: [String: FileNodeRecord],
        identities: Set<FileIdentity>
    ) -> [FileIdentity: [String]] {
        var pathsByIdentity: [FileIdentity: [String]] = [:]
        for (relativePath, node) in nodes {
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  let identity = node.fileIdentity,
                  identities.contains(identity) else {
                continue
            }
            pathsByIdentity[identity, default: []].append(relativePath)
        }
        return pathsByIdentity
    }

    private static func clonePathsByIdentity(
        in nodes: [String: FileNodeRecord],
        hardLinkOwners: [FileIdentity: String]
    ) -> [CloneIdentity: [String]] {
        var pathsByIdentity: [CloneIdentity: Set<String>] = [:]
        for (path, node) in nodes {
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  let cloneIdentity = node.cloneIdentity else {
                continue
            }
            let representativePath = node.fileIdentity.flatMap { hardLinkOwners[$0] } ?? path
            pathsByIdentity[cloneIdentity, default: []].insert(representativePath)
        }
        return pathsByIdentity.mapValues(Array.init)
    }

    private static func representativePathsByFileIdentity(
        in nodes: [String: FileNodeRecord],
        hardLinkOwners: [FileIdentity: String]
    ) -> [FileIdentity: String] {
        var pathsByIdentity: [FileIdentity: String] = [:]
        for (path, node) in nodes {
            guard !node.isDirectory,
                  !node.isSymbolicLink,
                  !node.isSynthetic,
                  let fileIdentity = node.fileIdentity else {
                continue
            }
            let representativePath = hardLinkOwners[fileIdentity] ?? path
            pathsByIdentity[fileIdentity] = min(
                pathsByIdentity[fileIdentity] ?? representativePath,
                representativePath
            )
        }
        return pathsByIdentity
    }

    /// Clone metadata disappears when only one full-clone member remains. Keep
    /// that one stable file as the comparison owner, but do not carry a group
    /// forward when multiple former members remain and may have diverged.
    private static func addSingletonCloneCounterpart(
        to paths: inout [String],
        from otherPaths: [String],
        currentNodes: [String: FileNodeRecord],
        otherNodes: [String: FileNodeRecord],
        representativePaths: [FileIdentity: String]
    ) {
        guard paths.isEmpty else { return }
        var candidates = Set<String>()
        for otherPath in otherPaths {
            guard let otherNode = otherNodes[otherPath] else { continue }
            if let fileIdentity = otherNode.fileIdentity {
                if let path = representativePaths[fileIdentity] {
                    candidates.insert(path)
                }
            } else if let node = currentNodes[otherPath],
                      !node.isDirectory,
                      !node.isSymbolicLink,
                      !node.isSynthetic {
                candidates.insert(otherPath)
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else { return }
        paths = [candidate]
    }

    private static func normalizeCloneGroups(
        beforePaths: [String],
        afterPaths: [String],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord],
        beforeSizes: inout [String: Int64],
        afterSizes: inout [String: Int64]
    ) {
        if let ownerPaths = stableCloneOwnerPaths(
            beforePaths: beforePaths,
            afterPaths: afterPaths,
            beforeNodes: beforeNodes,
            afterNodes: afterNodes
        ) {
            normalizeCloneGroup(
                paths: beforePaths,
                ownerPath: ownerPaths.before,
                nodes: beforeNodes,
                sizes: &beforeSizes
            )
            normalizeCloneGroup(
                paths: afterPaths,
                ownerPath: ownerPaths.after,
                nodes: afterNodes,
                sizes: &afterSizes
            )
        } else {
            if let ownerPath = beforePaths.min() {
                normalizeCloneGroup(
                    paths: beforePaths,
                    ownerPath: ownerPath,
                    nodes: beforeNodes,
                    sizes: &beforeSizes
                )
            }
            if let ownerPath = afterPaths.min() {
                normalizeCloneGroup(
                    paths: afterPaths,
                    ownerPath: ownerPath,
                    nodes: afterNodes,
                    sizes: &afterSizes
                )
            }
        }
    }

    private static func stableCloneOwnerPaths(
        beforePaths: [String],
        afterPaths: [String],
        beforeNodes: [String: FileNodeRecord],
        afterNodes: [String: FileNodeRecord]
    ) -> (before: String, after: String)? {
        if let sharedPath = Set(beforePaths).intersection(afterPaths).min() {
            return (sharedPath, sharedPath)
        }
        var afterPathByIdentity: [FileIdentity: String] = [:]
        for path in afterPaths {
            guard let identity = afterNodes[path]?.fileIdentity else { continue }
            afterPathByIdentity[identity] = min(afterPathByIdentity[identity] ?? path, path)
        }
        return beforePaths.compactMap { beforePath -> (before: String, after: String)? in
            guard let identity = beforeNodes[beforePath]?.fileIdentity,
                  let afterPath = afterPathByIdentity[identity] else {
                return nil
            }
            return (beforePath, afterPath)
        }
        .min { ($0.before, $0.after) < ($1.before, $1.after) }
    }

    private static func normalizeCloneGroup(
        paths: [String],
        ownerPath: String,
        nodes: [String: FileNodeRecord],
        sizes: inout [String: Int64]
    ) {
        let normalizedSizes = paths.compactMap { path -> (path: String, size: Int64)? in
            guard let node = nodes[path] else { return nil }
            return (
                path,
                path == ownerPath
                    ? node.unduplicatedAllocatedSize
                    : max(node.unduplicatedAllocatedSize - node.dataAllocatedSize, 0)
            )
        }
        guard normalizationIsBalanced(normalizedSizes, nodes: nodes, sizes: sizes) else {
            return
        }
        for (path, normalizedSize) in normalizedSizes {
            setNormalizedAllocatedSize(
                normalizedSize,
                at: path,
                nodes: nodes,
                sizes: &sizes
            )
        }
    }

    private static func normalizeHardLinkGroup(
        paths: [String],
        ownerPath: String,
        nodes: [String: FileNodeRecord],
        sizes: inout [String: Int64]
    ) {
        let groupAllocatedSize = paths.compactMap { nodes[$0]?.unduplicatedAllocatedSize }.max() ?? 0
        let normalizedSizes = paths.compactMap { path -> (path: String, size: Int64)? in
            guard nodes[path] != nil else { return nil }
            return (path, path == ownerPath ? groupAllocatedSize : 0)
        }
        guard normalizationIsBalanced(normalizedSizes, nodes: nodes, sizes: sizes) else {
            return
        }

        for (path, normalizedSize) in normalizedSizes {
            setNormalizedAllocatedSize(
                normalizedSize,
                at: path,
                nodes: nodes,
                sizes: &sizes
            )
        }
    }

    /// Ownership can be moved only when every byte removed from one visible
    /// claim is added to another. A nonzero result means the group has an
    /// opaque or out-of-scope owner that comparison metadata cannot identify.
    private static func normalizationIsBalanced(
        _ normalizedSizes: [(path: String, size: Int64)],
        nodes: [String: FileNodeRecord],
        sizes: [String: Int64]
    ) -> Bool {
        var netAdjustment: Int64 = 0
        for (path, normalizedSize) in normalizedSizes {
            guard let node = nodes[path] else { return false }
            let adjustment = normalizedSize - (sizes[path] ?? node.allocatedSize)
            let (nextAdjustment, overflow) = netAdjustment.addingReportingOverflow(adjustment)
            guard !overflow else { return false }
            netAdjustment = nextAdjustment
        }
        return netAdjustment == 0
    }

    private static func setNormalizedAllocatedSize(
        _ normalizedSize: Int64,
        at path: String,
        nodes: [String: FileNodeRecord],
        sizes: inout [String: Int64]
    ) {
        guard let node = nodes[path] else { return }
        let currentSize = sizes[path] ?? node.allocatedSize
        let adjustment = normalizedSize - currentSize
        guard adjustment != 0 else { return }

        sizes[path] = normalizedSize
        var cursor = path
        while let slashIndex = cursor.lastIndex(of: "/") {
            cursor = String(cursor[..<slashIndex])
            guard let ancestorNode = nodes[cursor] else { continue }
            sizes[cursor] = ScanComparisonIntegerMath.addingClamped(
                sizes[cursor] ?? ancestorNode.allocatedSize,
                adjustment
            )
        }
    }
}

private nonisolated extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
