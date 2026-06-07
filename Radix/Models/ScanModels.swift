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

    init(
        url: URL,
        kind: ScanTargetKind? = nil
    ) {
        let normalizedURL = ScanTarget.normalizedURL(from: url)
        self.id = normalizedURL.path
        self.url = normalizedURL
        self.displayName = ScanTarget.displayName(for: normalizedURL)
        self.kind = kind ?? ScanTarget.inferredKind(for: normalizedURL)
    }

    private static func normalizedURL(from url: URL) -> URL {
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

    private static func normalizedRootURL(from url: URL) -> URL {
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

struct ScanOptions: Sendable {
    var includeHiddenFiles = false
    var treatPackagesAsDirectories = false
    var autoSummarizeDirectories = true
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
        guard let updatedStore = treeStore.replacingSubtree(id: targetID, with: replacement) else { return nil }

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

    nonisolated var root: FileNodeRecord {
        guard let root = nodesByID[rootID] else {
            preconditionFailure("FileTreeStore rootID does not exist in nodesByID.")
        }
        return root
    }

    nonisolated var aggregateStats: ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        for nodeID in orderedNodeIDs {
            guard let node = nodesByID[nodeID] else { continue }

            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && children(of: node.id).isEmpty {
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
        parentIDByID: [String: String]
    ) {
        self.rootID = rootID
        self.nodesByID = nodesByID
        self.childIDsByID = childIDsByID
        self.parentIDByID = parentIDByID
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
        guard nodesByID[targetID] != nil else { return nil }

        let oldParentID = parentIDByID[targetID]
        let oldSubtreeIDs = Set(subtreeNodeIDs(rootedAt: targetID))
        var updatedNodes = nodesByID
        var updatedChildIDs = childIDsByID
        var updatedParentIDs = parentIDByID

        for oldID in oldSubtreeIDs {
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        updatedNodes.merge(replacement.nodesByID) { _, new in new }
        updatedChildIDs.merge(replacement.childIDsByID) { _, new in new }
        updatedParentIDs.merge(replacement.parentIDByID) { _, new in new }

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

    private nonisolated func subtreeNodeIDs(rootedAt id: String) -> [String] {
        var result: [String] = []
        var stack = [id]

        while let currentID = stack.popLast() {
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
        supportsFileActions && url.path != "/"
    }

    func supportsMoveToTrash(activeTarget: ScanTarget?) -> Bool {
        guard supportsMoveToTrash else { return false }
        guard let activeTarget else { return true }
        return !(activeTarget.kind == .volume && activeTarget.id == id)
    }
}
