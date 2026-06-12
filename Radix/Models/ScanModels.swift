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
        var stack = [root]

        while let parent = stack.popLast() {
            let children = Self.sortedChildren(inputChildrenByID[parent.id] ?? [])
            guard !children.isEmpty else { continue }

            childIDsByID[parent.id] = children.map(\.id)
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
        self.rootID = rootID
        self.nodesByID = nodesByID
        self.childIDsByID = childIDsByID
        self.parentIDByID = parentIDByID
        self.precomputedAggregateStats = aggregateStats
        self.orderedNodeIDs = Self.makeOrderedNodeIDs(rootID: rootID, childIDsByID: childIDsByID, nodesByID: nodesByID)
    }

    nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        children.sorted { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }
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
                isAccessible: current.isAccessible,
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

        while let nodeID = stack.popLast() {
            guard nodesByID[nodeID] != nil else { continue }
            result.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
        }

        return result
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

    init(node: FileNodeRecord?, activeTarget: ScanTarget?) {
        let supportsFileActions = node?.supportsFileActions == true
        self.init(
            canOpen: supportsFileActions,
            canPreviewWithQuickLook: supportsFileActions,
            canRevealInFinder: supportsFileActions,
            canCopyPath: supportsFileActions,
            canMoveToTrash: node?.supportsMoveToTrash(activeTarget: activeTarget) == true
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
        supportsFileActions && TrashSafetyPolicy.blockReason(for: url) == nil
    }

    func supportsMoveToTrash(activeTarget: ScanTarget?) -> Bool {
        guard supportsMoveToTrash else { return false }
        guard let activeTarget else { return true }
        return !(activeTarget.kind == .volume && activeTarget.id == id)
    }

    func actionAvailability(activeTarget: ScanTarget?) -> FileNodeActionAvailability {
        FileNodeActionAvailability(node: self, activeTarget: activeTarget)
    }
}
