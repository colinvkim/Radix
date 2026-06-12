//
//  ScanModels.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum ScanTargetKind: String, Hashable, Codable, Sendable {
    case folder
    case volume
}

struct ScanTarget: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let kind: ScanTargetKind

    nonisolated init(
        url: URL,
        kind: ScanTargetKind? = nil
    ) {
        let normalizedURL = ScanTarget.normalizedURL(from: url)
        self.id = normalizedURL.path
        self.url = normalizedURL
        self.displayName = ScanTarget.displayName(for: normalizedURL)
        self.kind = kind ?? ScanTarget.inferredKind(for: normalizedURL)
    }

    private nonisolated static func normalizedURL(from url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        for syntheticPrefix in ["/.nofollow", "/.resolve"] {
            guard path == syntheticPrefix || path.hasPrefix(syntheticPrefix + "/") else { continue }

            let trimmedPath = String(path.dropFirst(syntheticPrefix.count))
            let normalizedPath = trimmedPath.isEmpty ? "/" : trimmedPath
            let syntheticResolvedURL = URL(
                fileURLWithPath: normalizedPath,
                isDirectory: standardizedURL.hasDirectoryPath
            )
            return normalizedRootURL(from: syntheticResolvedURL)
        }

        return normalizedRootURL(from: standardizedURL)
    }

    private nonisolated static func normalizedRootURL(from url: URL) -> URL {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: resolvedURL.path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    nonisolated static func inferredKind(
        for url: URL,
        mountedVolumeURLs: [URL]? = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )
    ) -> ScanTargetKind {
        let path = url.standardizedFileURL.path
        if path == "/" {
            return .volume
        }

        guard let mountedVolumeURLs else {
            return .folder
        }

        let mountedVolumePaths = Set(mountedVolumeURLs.map { $0.standardizedFileURL.path })
        return mountedVolumePaths.contains(path) ? .volume : .folder
    }

    nonisolated static func displayName(for url: URL) -> String {
        if url.path == "/" {
            do {
                let volumeName = try url.resourceValues(forKeys: [.volumeNameKey]).volumeName
                return volumeName ?? "Startup Disk"
            } catch {
                return "Startup Disk"
            }
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }
}

struct ScanOptions: Hashable, Sendable {
    var includeHiddenFiles = false
    var treatPackagesAsDirectories = false
    var autoSummarizeDirectories = true
    var includeCloudStorage = false
    var cloudStorageRootPath = ScanOptions.defaultCloudStorageRootPath
    var exclusionPatterns: [String] = []
    var exclusionRootPath: String?
    /// Override for the minimum file count to trigger auto-summarization.
    /// When nil, the ScanEngine default (5,000) is used.
    var autoSummarizeMinFileCount: Int?
    /// Override for the maximum average file size to trigger auto-summarization.
    /// When nil, the ScanEngine default (4 KB) is used.
    var autoSummarizeMaxAverageFileSize: Int64?
    /// Override for the minimum depth at which auto-summarization applies.
    /// When nil, the ScanEngine default (2) is used.
    var autoSummarizeMinDepthForSummarization: Int?
    /// Override for bounded package/atomic summary parallelism.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var atomicSummaryWorkerLimit: Int?
    /// Override for bounded immediate-child metadata classification.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var directoryClassificationWorkerLimit: Int?
    /// Override for bounded ordinary directory traversal parallelism.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var directoryTraversalWorkerLimit: Int?

    nonisolated static let defaultCloudStorageRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        .standardizedFileURL
        .path
}

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

struct FileNodeRecord: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let lastModified: Date?
    let isPackage: Bool
    let isAccessible: Bool
    let isSelfAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    nonisolated var itemKind: String {
        if isSynthetic {
            return "System Data"
        }
        if isAutoSummarized {
            return "Summarized"
        }
        if isSymbolicLink {
            return "Alias"
        }
        if isPackage {
            return "Package"
        }
        return isDirectory ? "Folder" : "File"
    }

    nonisolated var supportsFileActions: Bool {
        !isSynthetic
    }

    nonisolated static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        isPackage: Bool,
        isAccessible: Bool,
        childrenAreSorted: Bool = false
    ) -> FileNodeRecord {
        let sortedChildren = childrenAreSorted ? children : FileTreeStore.sortedChildren(children)
        let allocatedSize = sortedChildren.reduce(into: Int64(0)) { result, child in
            result += child.allocatedSize
        }
        let logicalSize = sortedChildren.reduce(into: Int64(0)) { result, child in
            result += child.logicalSize
        }
        let descendantFileCount = sortedChildren.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }
        let isFullyAccessible = isAccessible && sortedChildren.allSatisfy(\.isAccessible)

        return FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
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

actor ScanSnapshotTransformService {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) throws -> ScanSnapshot? {
        try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) throws -> ScanSnapshot? {
        try snapshot.scoped(
            to: target,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

enum ScanPostTrashAction: Equatable {
    case clearActiveScan
    case rescanActiveScan
    case none

    static func afterRemovingNode(activeTargetID: String?, removedNodeID: String) -> ScanPostTrashAction {
        guard let activeTargetID else { return .none }
        return activeTargetID == removedNodeID ? .clearActiveScan : .rescanActiveScan
    }
}

struct ScanMetrics: Sendable {
    var filesVisited = 0
    var directoriesVisited = 0
    var bytesDiscovered: Int64 = 0
    var currentPath = ""
    var discoveredItems = 0
    var completedItems = 0
    var estimatedTotalBytes: Int64 = 0
    var progressFraction = 0.0
    var isFinalizing = false

    nonisolated var progressPercentage: Int {
        Int((progressFraction * 100).rounded(.down))
    }

    nonisolated mutating func recalculateProgress(isComplete: Bool = false) {
        if isComplete {
            progressFraction = 1
            return
        }

        let discoveredWork = max(discoveredItems, 1)
        let pendingItems = max(discoveredItems - completedItems, 0)
        let weightedRemainingWork = Double(pendingItems) * 1.35 + 6
        let traversalFraction = min(
            Double(completedItems) / (Double(completedItems) + weightedRemainingWork),
            0.97
        )

        let byteFraction: Double
        if estimatedTotalBytes > 0 {
            byteFraction = min(Double(bytesDiscovered) / Double(estimatedTotalBytes), 0.96)
        } else {
            byteFraction = 0
        }

        let discoveryFraction = min(Double(completedItems) / Double(discoveredWork), 0.92)
        let blendedFraction: Double
        if estimatedTotalBytes > 0 {
            blendedFraction = (byteFraction * 0.65) + (traversalFraction * 0.25) + (discoveryFraction * 0.10)
        } else {
            blendedFraction = (traversalFraction * 0.75) + (discoveryFraction * 0.25)
        }

        let hasStarted = filesVisited > 0 || directoriesVisited > 0 || discoveredItems > 0
        let minimumVisibleProgress = hasStarted ? 0.01 : 0
        progressFraction = max(progressFraction, max(blendedFraction, minimumVisibleProgress))
    }
}

enum ScanProgressEvent: Sendable {
    case progress(ScanMetrics)
    case warning(ScanWarning)
    case finished(ScanSnapshot)
}

struct FileTreeStore: Sendable {
    let rootID: String
    let nodesByID: [String: FileNodeRecord]
    let childIDsByID: [String: [String]]
    let parentIDByID: [String: String]
    private let orderedNodeIDs: [String]
    private let precomputedAggregateStats: ScanAggregateStats?

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let parentIDByID: [String: String]
        let orderedNodeIDs: [String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            }
        }
    }

    nonisolated var root: FileNodeRecord {
        guard let root = nodesByID[rootID] else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var nodeCount: Int {
        nodesByID.count
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        if let precomputedAggregateStats {
            return precomputedAggregateStats
        }

        return computedAggregateStats()
    }

    private nonisolated func computedAggregateStats() -> ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        for nodeID in orderedNodeIDs {
            guard let node = nodesByID[nodeID] else { continue }

            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !containsChildren(id: node.id) {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    nonisolated init(root: FileNodeRecord) {
        self.init(
            rootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [:],
            parentIDByID: [:]
        )
    }

    nonisolated init(root: FileNodeRecord, childrenByID inputChildrenByID: [String: [FileNodeRecord]]) {
        var nodesByID = [root.id: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var seenNodeIDs: Set<String> = [root.id]
        var stack = [root]

        while let parent = stack.popLast() {
            guard let inputChildren = inputChildrenByID[parent.id] else { continue }
            let (uniqueChildren, droppedChildIDs) = Self.uniqueChildrenAndDroppedIDs(
                inputChildren,
                seenNodeIDs: &seenNodeIDs
            )
            let children = Self.sortedChildren(uniqueChildren)
            childIDsByID[parent.id] = children.map(\.id) + droppedChildIDs
            guard !children.isEmpty else { continue }

            for child in children {
                nodesByID[child.id] = child
                parentIDByID[child.id] = parent.id
                stack.append(child)
            }
        }

        self.init(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
    }

    nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.rootID = rootID
        self.nodesByID = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                orderedNodeIDs: topology.orderedNodeIDs,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.childIDsByID = topology.childIDsByID
        self.parentIDByID = topology.parentIDByID
        self.precomputedAggregateStats = topology.didDropReferences ? nil : aggregateStats
        self.orderedNodeIDs = topology.orderedNodeIDs
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        children.sorted { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }
    }

    private nonisolated static func uniqueChildrenAndDroppedIDs(
        _ children: [FileNodeRecord],
        seenNodeIDs: inout Set<String>
    ) -> (uniqueChildren: [FileNodeRecord], droppedChildIDs: [String]) {
        var uniqueChildren: [FileNodeRecord] = []
        var droppedChildIDs: [String] = []
        uniqueChildren.reserveCapacity(children.count)

        for child in children {
            if seenNodeIDs.insert(child.id).inserted {
                uniqueChildren.append(child)
            } else {
                droppedChildIDs.append(child.id)
            }
        }

        return (uniqueChildren, droppedChildIDs)
    }

    nonisolated func node(id: String?) -> FileNodeRecord? {
        guard let id else { return nil }
        return nodesByID[id]
    }

    nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let id, let parentID = parentIDByID[id] else { return nil }
        return nodesByID[parentID]
    }

    nonisolated func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    nonisolated func childrenPrefix(of id: String?, maxCount: Int) -> [FileNodeRecord] {
        (try? childrenPrefix(of: id, maxCount: maxCount, cancellationCheck: {})) ?? []
    }

    nonisolated func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        let resolvedID = id ?? rootID
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIDs.count)
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
                children.append(node)
            }
        }
        return children
    }

    nonisolated func childrenPrefix(
        of id: String?,
        maxCount: Int,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        guard maxCount > 0 else { return [] }

        let resolvedID = id ?? rootID
        guard let childIDs = childIDsByID[resolvedID] else { return [] }

        var children: [FileNodeRecord] = []
        children.reserveCapacity(min(maxCount, childIDs.count))
        for childID in childIDs {
            try cancellationCheck()
            if let node = nodesByID[childID] {
                children.append(node)
                if children.count == maxCount {
                    break
                }
            }
        }
        return children
    }

    nonisolated func containsChildren(id: String?) -> Bool {
        let resolvedID = id ?? rootID
        return childIDsByID[resolvedID]?.isEmpty == false
    }

    nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        guard excludingRoot else {
            return orderedNodeIDs
        }
        return orderedNodeIDs.filter { $0 != rootID }
    }

    nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for nodeID in orderedNodeIDs {
            if excludingRoot && nodeID == rootID {
                continue
            }
            try body(nodeID)
        }
    }

    nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let id, let node = nodesByID[id] else {
            return [root]
        }

        var result: [FileNodeRecord] = [node]
        var cursor = id
        while let parentID = parentIDByID[cursor], let parent = nodesByID[parentID] {
            result.append(parent)
            cursor = parentID
        }
        return result.reversed()
    }

    nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let descendantID else { return false }
        if ancestorID == descendantID {
            return true
        }

        var cursor = descendantID
        while let parentID = parentIDByID[cursor] {
            if parentID == ancestorID {
                return true
            }
            cursor = parentID
        }
        return false
    }

    nonisolated func replacingSubtree(id targetID: String, with replacement: FileTreeStore) -> FileTreeStore? {
        try? replacingSubtree(id: targetID, with: replacement, cancellationCheck: {})
    }

    nonisolated func replacingSubtree(
        id targetID: String,
        with replacement: FileTreeStore,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil else { return nil }

        let oldParentID = parentIDByID[targetID]
        let oldSubtreeIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        try preflightReplacement(
            replacement,
            removing: oldSubtreeIDs,
            cancellationCheck: cancellationCheck
        )
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for (offset, oldID) in oldSubtreeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        for (offset, entry) in replacement.nodesByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes[entry.key] = entry.value
        }
        for (offset, entry) in replacement.childIDsByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedChildIDs[entry.key] = entry.value
        }
        for (offset, entry) in replacement.parentIDByID.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedParentIDs[entry.key] = entry.value
        }

        let updatedRootID: String
        if let oldParentID {
            let previousChildIDs = childIDsByID[oldParentID] ?? []
            updatedChildIDs[oldParentID] = previousChildIDs.map { childID in
                childID == targetID ? replacement.rootID : childID
            }
            updatedParentIDs[replacement.rootID] = oldParentID
            updatedRootID = rootID
        } else {
            updatedParentIDs.removeValue(forKey: replacement.rootID)
            updatedRootID = replacement.rootID
        }

        var cursor = oldParentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            cursor = updatedParentIDs[currentID]
        }

        return FileTreeStore(
            rootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
    }

    private nonisolated func preflightReplacement(
        _ replacement: FileTreeStore,
        removing oldSubtreeIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        for (offset, replacementID) in replacement.nodesByID.keys.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if nodesByID[replacementID] != nil && !oldSubtreeIDs.contains(replacementID) {
                throw StoreError.replacementIDCollision(replacementID)
            }
        }
    }

    nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard nodesByID[targetID] != nil else { return nil }

        var scopedNodes: [String: FileNodeRecord] = [:]
        var scopedChildIDs: [String: [String]] = [:]
        var scopedParentIDs: [String: String] = [:]
        var stack = [targetID]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            guard let node = nodesByID[currentID] else { continue }
            scopedNodes[currentID] = node

            let childIDs = childIDsByID[currentID] ?? []
            guard !childIDs.isEmpty else { continue }

            var scopedChildren: [String] = []
            scopedChildren.reserveCapacity(childIDs.count)
            for (offset, childID) in childIDs.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard nodesByID[childID] != nil else { continue }
                scopedChildren.append(childID)
                scopedParentIDs[childID] = currentID
                stack.append(childID)
            }

            if !scopedChildren.isEmpty {
                scopedChildIDs[currentID] = scopedChildren
            }
        }

        return FileTreeStore(
            rootID: targetID,
            nodesByID: scopedNodes,
            childIDsByID: scopedChildIDs,
            parentIDByID: scopedParentIDs
        )
    }

    private nonisolated func subtreeNodeIDs(rootedAt id: String) -> [String] {
        (try? subtreeNodeIDs(rootedAt: id, cancellationCheck: {})) ?? []
    }

    private nonisolated func subtreeNodeIDs(
        rootedAt id: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        var result: [String] = []
        var stack = [id]

        while let currentID = stack.popLast() {
            try cancellationCheck()
            result.append(currentID)
            let childIDs = childIDsByID[currentID] ?? []
            stack.append(contentsOf: childIDs)
        }

        return result
    }

    private nonisolated static func makeOrderedNodeIDs(
        rootID: String,
        childIDsByID: [String: [String]],
        nodesByID: [String: FileNodeRecord]
    ) -> [String] {
        guard nodesByID[rootID] != nil else { return [] }
        var result: [String] = []
        var stack: [String] = [rootID]
        var visited: Set<String> = []

        while let nodeID = stack.popLast() {
            guard nodesByID[nodeID] != nil, visited.insert(nodeID).inserted else { continue }
            result.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
        }

        return result
    }

    private nonisolated static func sanitizedTopology(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]]
    ) -> SanitizedTopology {
        guard let root = inputNodesByID[rootID] else {
            return SanitizedTopology(
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                parentIDByID: [:],
                orderedNodeIDs: [],
                materializedDirectoryIDs: [],
                didDropReferences: true
            )
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var orderedNodeIDs: [String] = []
        var materializedDirectoryIDs = Set<String>()
        var visited: Set<String> = [rootID]
        var stack = [rootID]

        while let parentID = stack.popLast() {
            orderedNodeIDs.append(parentID)
            guard let childIDs = inputChildIDsByID[parentID] else { continue }
            if inputNodesByID[parentID]?.isDirectory == true {
                materializedDirectoryIDs.insert(parentID)
            }
            guard !childIDs.isEmpty else { continue }

            var sanitizedChildIDs: [String] = []
            sanitizedChildIDs.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let child = inputNodesByID[childID] else { continue }
                guard visited.insert(childID).inserted else { continue }
                nodesByID[childID] = child
                parentIDByID[childID] = parentID
                sanitizedChildIDs.append(childID)
            }

            if !sanitizedChildIDs.isEmpty {
                childIDsByID[parentID] = sanitizedChildIDs
                stack.append(contentsOf: sanitizedChildIDs.reversed())
            }
        }

        let materializedInputChildIDsByID = inputChildIDsByID.filter { !$0.value.isEmpty }
        let didDropReferences =
            nodesByID.count != inputNodesByID.count ||
            childIDsByID != materializedInputChildIDsByID

        return SanitizedTopology(
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            orderedNodeIDs: orderedNodeIDs,
            materializedDirectoryIDs: materializedDirectoryIDs,
            didDropReferences: didDropReferences
        )
    }

    private nonisolated static func repairMaterializedDirectoryTotals(
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        orderedNodeIDs: [String],
        materializedDirectoryIDs: Set<String>
    ) -> [String: FileNodeRecord] {
        guard !materializedDirectoryIDs.isEmpty else { return nodesByID }

        var repairedNodes = nodesByID
        for nodeID in orderedNodeIDs.reversed() where materializedDirectoryIDs.contains(nodeID) {
            guard let node = repairedNodes[nodeID], node.isDirectory else { continue }
            let childIDs = childIDsByID[nodeID] ?? []
            let children = childIDs.compactMap { repairedNodes[$0] }
            repairedNodes[nodeID] = repairingDirectoryRecord(node, children: children)
        }
        return repairedNodes
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        let allocatedSize = children.reduce(into: Int64(0)) { result, child in
            result += child.allocatedSize
        }
        let logicalSize = children.reduce(into: Int64(0)) { result, child in
            result += child.logicalSize
        }
        let descendantFileCount = children.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }

        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: node.lastModified,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && children.allSatisfy(\.isAccessible),
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }
}

enum FileNodeAction: CaseIterable, Equatable, Identifiable, Sendable {
    case quickLook
    case revealInFinder
    case open
    case copyPath
    case moveToTrash

    var id: Self { self }

    var title: String {
        switch self {
        case .quickLook:
            return "Quick Look"
        case .revealInFinder:
            return "Reveal in Finder"
        case .open:
            return "Open"
        case .copyPath:
            return "Copy Path"
        case .moveToTrash:
            return "Move to Trash"
        }
    }

    var systemImageName: String {
        switch self {
        case .quickLook:
            if #available(macOS 15.0, *) {
                return "document.viewfinder"
            }
            return "doc.viewfinder"
        case .revealInFinder:
            if #available(macOS 26.0, *) {
                return "finder"
            }
            return "folder"
        case .open:
            return "arrow.up.forward.app"
        case .copyPath:
            if #available(macOS 15.0, *) {
                return "document.on.document"
            }
            return "doc.on.doc"
        case .moveToTrash:
            return "trash"
        }
    }

    func isEnabled(in availability: FileNodeActionAvailability) -> Bool {
        switch self {
        case .quickLook:
            return availability.canPreviewWithQuickLook
        case .revealInFinder:
            return availability.canRevealInFinder
        case .open:
            return availability.canOpen
        case .copyPath:
            return availability.canCopyPath
        case .moveToTrash:
            return availability.canMoveToTrash
        }
    }
}

struct FileNodeActionAvailability: Equatable, Sendable {
    let canOpen: Bool
    let canPreviewWithQuickLook: Bool
    let canRevealInFinder: Bool
    let canCopyPath: Bool
    let canMoveToTrash: Bool

    init(
        canOpen: Bool,
        canPreviewWithQuickLook: Bool,
        canRevealInFinder: Bool,
        canCopyPath: Bool,
        canMoveToTrash: Bool
    ) {
        self.canOpen = canOpen
        self.canPreviewWithQuickLook = canPreviewWithQuickLook
        self.canRevealInFinder = canRevealInFinder
        self.canCopyPath = canCopyPath
        self.canMoveToTrash = canMoveToTrash
    }

    init(
        node: FileNodeRecord?,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) {
        let supportsFileActions = node?.supportsFileActions == true
        self.init(
            canOpen: supportsFileActions,
            canPreviewWithQuickLook: supportsFileActions,
            canRevealInFinder: supportsFileActions,
            canCopyPath: supportsFileActions,
            canMoveToTrash: node?.supportsMoveToTrash(
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy
            ) == true
        )
    }
}

enum TrashSafetyBlockReason: Equatable, Sendable {
    case protectedRoot(path: String)

    var path: String {
        switch self {
        case .protectedRoot(let path):
            return path
        }
    }
}

struct TrashSafetyPolicy: Sendable {
    struct FirmlinkEntry: Equatable, Sendable {
        let visiblePath: String
        let dataRelativePath: String

        init(visiblePath: String, dataRelativePath: String) {
            self.visiblePath = visiblePath
            self.dataRelativePath = dataRelativePath
        }
    }

    private static let staticProtectedRootPaths = [
        "/",
        "/Applications",
        "/Library",
        "/System",
        "/System/Volumes",
        "/System/Volumes/Data",
        "/Users",
        "/Volumes",
        "/bin",
        "/dev",
        "/etc",
        "/private",
        "/sbin",
        "/tmp",
        "/usr",
        "/var"
    ]

    private static let fallbackFirmlinkEntries = [
        FirmlinkEntry(visiblePath: "/AppleInternal", dataRelativePath: "AppleInternal"),
        FirmlinkEntry(visiblePath: "/Applications", dataRelativePath: "Applications"),
        FirmlinkEntry(visiblePath: "/Library", dataRelativePath: "Library"),
        FirmlinkEntry(visiblePath: "/System/Library/Caches", dataRelativePath: "System/Library/Caches"),
        FirmlinkEntry(visiblePath: "/System/Library/Assets", dataRelativePath: "System/Library/Assets"),
        FirmlinkEntry(visiblePath: "/System/Library/PreinstalledAssets", dataRelativePath: "System/Library/PreinstalledAssets"),
        FirmlinkEntry(visiblePath: "/System/Library/AssetsV2", dataRelativePath: "System/Library/AssetsV2"),
        FirmlinkEntry(visiblePath: "/System/Library/PreinstalledAssetsV2", dataRelativePath: "System/Library/PreinstalledAssetsV2"),
        FirmlinkEntry(visiblePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library", dataRelativePath: "System/Library/CoreServices/CoreTypes.bundle/Contents/Library"),
        FirmlinkEntry(visiblePath: "/System/Library/Speech", dataRelativePath: "System/Library/Speech"),
        FirmlinkEntry(visiblePath: "/Users", dataRelativePath: "Users"),
        FirmlinkEntry(visiblePath: "/Volumes", dataRelativePath: "Volumes"),
        FirmlinkEntry(visiblePath: "/cores", dataRelativePath: "cores"),
        FirmlinkEntry(visiblePath: "/opt", dataRelativePath: "opt"),
        FirmlinkEntry(visiblePath: "/pkg", dataRelativePath: "pkg"),
        FirmlinkEntry(visiblePath: "/private", dataRelativePath: "private"),
        FirmlinkEntry(visiblePath: "/usr/local", dataRelativePath: "usr/local"),
        FirmlinkEntry(visiblePath: "/usr/libexec/cups", dataRelativePath: "usr/libexec/cups"),
        FirmlinkEntry(visiblePath: "/usr/share/snmp", dataRelativePath: "usr/share/snmp")
    ]

    private static let defaultFirmlinkEntries: [FirmlinkEntry] = {
        entriesFromFirmlinkFile(at: URL(fileURLWithPath: "/usr/share/firmlinks"))
            ?? fallbackFirmlinkEntries
    }()

    private let protectedRootPaths: Set<String>

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        mountedVolumeURLs: [URL]? = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ),
        firmlinkEntries: [FirmlinkEntry] = TrashSafetyPolicy.defaultFirmlinkEntries
    ) {
        var paths = Set(Self.staticProtectedRootPaths.map(Self.standardizedPath(forPath:)))

        let homePath = Self.standardizedPath(for: homeDirectory)
        paths.insert(homePath)
        if let dataHomePath = Self.dataVolumePath(forAbsolutePath: homePath) {
            paths.insert(dataHomePath)
        }

        for volumeURL in mountedVolumeURLs ?? [] {
            paths.insert(Self.standardizedPath(for: volumeURL))
        }

        for entry in firmlinkEntries {
            paths.insert(Self.standardizedPath(forPath: entry.visiblePath))
            if let dataPath = Self.dataVolumePath(forRelativePath: entry.dataRelativePath) {
                paths.insert(dataPath)
            }
        }

        self.protectedRootPaths = paths
    }

    static func live() -> TrashSafetyPolicy {
        TrashSafetyPolicy()
    }

    static func blockReason(for url: URL) -> TrashSafetyBlockReason? {
        live().blockReason(for: url)
    }

    func blockReason(for url: URL) -> TrashSafetyBlockReason? {
        let path = Self.standardizedPath(for: url)
        guard protectedRootPaths.contains(path) else { return nil }
        return .protectedRoot(path: path)
    }

    static func parseFirmlinkEntries(_ contents: String) -> [FirmlinkEntry] {
        contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> FirmlinkEntry? in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }

                let parts = trimmedLine
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)

                guard let visiblePath = parts.first else { return nil }
                let dataRelativePath = parts.dropFirst().first ?? String(visiblePath.drop { $0 == "/" })
                guard !dataRelativePath.isEmpty else { return nil }

                return FirmlinkEntry(
                    visiblePath: visiblePath,
                    dataRelativePath: dataRelativePath
                )
            }
    }

    private static func entriesFromFirmlinkFile(at url: URL) -> [FirmlinkEntry]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let entries = parseFirmlinkEntries(contents)
        return entries.isEmpty ? nil : entries
    }

    private static func dataVolumePath(forAbsolutePath path: String) -> String? {
        dataVolumePath(forRelativePath: String(path.drop { $0 == "/" }))
    }

    private static func dataVolumePath(forRelativePath path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        return standardizedPath(forPath: "/System/Volumes/Data/" + trimmedPath)
    }

    private static func standardizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func standardizedPath(forPath path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

extension FileNodeRecord {
    var systemImageName: String {
        if isSynthetic {
            return "internaldrive.fill"
        }
        if isSymbolicLink {
            return "arrowshape.turn.up.right.circle.fill"
        }
        if isPackage {
            return "shippingbox.fill"
        }
        return isDirectory ? "folder.fill" : "doc.fill"
    }

    var secondaryStatusText: String? {
        if isSynthetic {
            return "Estimated from volume usage"
        }
        if isAutoSummarized {
            return "Summarized (\(descendantFileCount) files)"
        }
        if !isAccessible {
            return "Limited access"
        }
        return nil
    }

    var accessDescription: String {
        if isSynthetic {
            return "Estimated"
        }
        return isAccessible ? "Readable" : "Limited"
    }

    var supportsMoveToTrash: Bool {
        supportsMoveToTrash(trashSafetyPolicy: .live())
    }

    func supportsMoveToTrash(trashSafetyPolicy: TrashSafetyPolicy) -> Bool {
        supportsFileActions && trashSafetyPolicy.blockReason(for: url) == nil
    }

    func supportsMoveToTrash(
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) -> Bool {
        guard supportsMoveToTrash(trashSafetyPolicy: trashSafetyPolicy) else { return false }
        guard let activeTarget else { return true }
        return !(activeTarget.kind == .volume && activeTarget.id == id)
    }

    func actionAvailability(
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) -> FileNodeActionAvailability {
        FileNodeActionAvailability(
            node: self,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy
        )
    }
}
