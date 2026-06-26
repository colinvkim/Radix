//
//  ScanSnapshot.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum ScanWarningCategory: String, Hashable, Sendable {
    case permissionDenied
    case fileSystem
}

struct ScanWarning: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let message: String
    let category: ScanWarningCategory
}

struct ScanAggregateStats: Sendable {
    let totalAllocatedSize: Int64
    let totalLogicalSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let accessibleItemCount: Int
    let inaccessibleItemCount: Int
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

struct ScanSnapshot: Identifiable, Sendable {
    let id: UUID
    let target: ScanTarget
    let treeStore: FileTreeStore
    let startedAt: Date
    let finishedAt: Date?
    let scanWarnings: [ScanWarning]
    let aggregateStats: ScanAggregateStats
    let isComplete: Bool
    let scanOptions: ScanOptions?
    let source: ScanSnapshotSource

    nonisolated init(
        id: UUID = UUID(),
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        scanWarnings: [ScanWarning],
        aggregateStats: ScanAggregateStats,
        isComplete: Bool,
        scanOptions: ScanOptions? = nil,
        source: ScanSnapshotSource = .live
    ) {
        self.id = id
        self.target = target
        self.treeStore = treeStore
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scanWarnings = scanWarnings
        self.aggregateStats = aggregateStats
        self.isComplete = isComplete
        self.scanOptions = scanOptions
        self.source = source
    }

    nonisolated var root: FileNodeRecord {
        treeStore.root
    }

    nonisolated func removingNode(id targetID: String) -> ScanSnapshot? {
        try? removingNode(id: targetID, cancellationCheck: {})
    }

    nonisolated func removingNode(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let updatedStore = try treeStore.removingSubtree(
            id: targetID,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        return ScanSnapshot(
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scanWarnings,
            aggregateStats: updatedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
        )
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

    nonisolated func replacingNode(
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = [],
        cancellationCheck: () throws -> Void
    ) throws -> ScanSnapshot? {
        try cancellationCheck()
        guard let updatedStore = try treeStore.replacingSubtree(
            id: targetID,
            with: replacement,
            cancellationCheck: cancellationCheck
        ) else { return nil }

        return ScanSnapshot(
            target: target,
            treeStore: updatedStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: Self.mergedWarnings(existing: scanWarnings, additional: additionalWarnings),
            aggregateStats: updatedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
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
        guard let scopedStore = try treeStore.subtree(
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
            aggregateStats: scopedStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source
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
}
