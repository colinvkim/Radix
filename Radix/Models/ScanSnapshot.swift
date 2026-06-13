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

struct ScanSnapshot: Identifiable, Sendable {
    let id = UUID()
    let target: ScanTarget
    let treeStore: FileTreeStore
    let startedAt: Date
    let finishedAt: Date?
    let scanWarnings: [ScanWarning]
    let aggregateStats: ScanAggregateStats
    let isComplete: Bool

    nonisolated var root: FileNodeRecord {
        treeStore.root
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
            isComplete: isComplete
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
            isComplete: isComplete
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
