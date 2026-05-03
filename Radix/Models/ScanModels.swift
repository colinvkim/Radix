//
//  ScanModels.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation
import SwiftUI

enum ScanTargetKind: String, Hashable, Codable, Sendable {
    case folder
    case volume
}

enum AuthorizationState: String, Hashable, Codable, Sendable {
    case notEvaluated
    case readable
    case limited
    case inaccessible
}

struct ScanTarget: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let kind: ScanTargetKind
    let authorizationState: AuthorizationState

    init(
        url: URL,
        kind: ScanTargetKind? = nil,
        authorizationState: AuthorizationState = .notEvaluated
    ) {
        let normalizedURL = ScanTarget.normalizedURL(from: url)
        self.id = normalizedURL.path
        self.url = normalizedURL
        self.displayName = ScanTarget.displayName(for: normalizedURL)
        self.kind = kind ?? (normalizedURL.path == "/" ? .volume : .folder)
        self.authorizationState = authorizationState
    }

    private static func normalizedURL(from url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        for syntheticPrefix in ["/.nofollow", "/.resolve"] {
            guard path == syntheticPrefix || path.hasPrefix(syntheticPrefix + "/") else { continue }

            let trimmedPath = String(path.dropFirst(syntheticPrefix.count))
            let normalizedPath = trimmedPath.isEmpty ? "/" : trimmedPath
            return URL(fileURLWithPath: normalizedPath, isDirectory: standardizedURL.hasDirectoryPath).standardizedFileURL
        }

        return standardizedURL
    }

    private static func displayName(for url: URL) -> String {
        if url.path == "/" {
            let volumeName = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
            return volumeName ?? "Startup Disk"
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }
}

struct ScanOptions: Sendable {
    var includeHiddenFiles = false
    var treatPackagesAsDirectories = false
    var maxRenderedDepth = 6
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

struct FileNode: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let logicalSize: Int64
    let children: [FileNode]
    let descendantFileCount: Int
    let lastModified: Date?
    let isPackage: Bool
    let isAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    nonisolated var containsChildren: Bool {
        !children.isEmpty
    }

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

    nonisolated var aggregateStats: ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        walk { node in
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && node.children.isEmpty {
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
            totalAllocatedSize: allocatedSize,
            totalLogicalSize: logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    nonisolated static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNode],
        lastModified: Date?,
        isPackage: Bool,
        isAccessible: Bool
    ) -> FileNode {
        let sortedChildren = children.sorted { lhs, rhs in
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }

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

        return FileNode(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            children: sortedChildren,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private nonisolated func walk(visit: (FileNode) -> Void) {
        visit(self)
        for child in children {
            child.walk(visit: visit)
        }
    }

    fileprivate nonisolated func replacingNode(
        targetID: String,
        with replacement: FileNode,
        affectedIDs: Set<String>
    ) -> FileNode {
        if id == targetID {
            return replacement
        }

        guard affectedIDs.contains(id) else { return self }

        let newChildren = children.map { child in
            child.replacingNode(targetID: targetID, with: replacement, affectedIDs: affectedIDs)
        }

        return .directory(
            id: id,
            url: url,
            name: name,
            children: newChildren,
            lastModified: lastModified,
            isPackage: isPackage,
            isAccessible: isAccessible
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
    let root: FileNode
    let startedAt: Date
    let finishedAt: Date?
    let scanWarnings: [ScanWarning]
    let aggregateStats: ScanAggregateStats
    let isComplete: Bool

    func replacingNode(
        id targetID: String,
        with replacement: FileNode,
        additionalWarnings: [ScanWarning] = []
    ) -> ScanSnapshot? {
        let index = FileTreeIndex(root: root)
        guard index.node(id: targetID) != nil else { return nil }

        var affectedIDs: Set<String> = [targetID]
        var cursor = targetID
        while let parentID = index.parentByID[cursor] {
            affectedIDs.insert(parentID)
            cursor = parentID
        }

        let updatedRoot = root.replacingNode(
            targetID: targetID,
            with: replacement,
            affectedIDs: affectedIDs
        )

        return ScanSnapshot(
            target: target,
            root: updatedRoot,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: Self.mergedWarnings(existing: scanWarnings, additional: additionalWarnings),
            aggregateStats: updatedRoot.aggregateStats,
            isComplete: isComplete
        )
    }

    private static func mergedWarnings(
        existing: [ScanWarning],
        additional: [ScanWarning]
    ) -> [ScanWarning] {
        var seen = Set<ScanWarningKey>()
        var result: [ScanWarning] = []

        for warning in existing + additional {
            let key = ScanWarningKey(warning: warning)
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

private struct ScanWarningKey: Hashable {
    let path: String
    let message: String
    let category: ScanWarningCategory

    init(warning: ScanWarning) {
        self.path = warning.path
        self.message = warning.message
        self.category = warning.category
    }
}

struct ScanMetrics: Sendable {
    var filesVisited = 0
    var directoriesVisited = 0
    var inaccessibleDirectories = 0
    var bytesDiscovered: Int64 = 0
    var currentPath = ""
    var startedAt = Date()
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

struct SunburstSegment: Identifiable, Hashable {
    let id: String
    let nodeID: String?
    let label: String
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let depth: Int
    let colorKey: String
    let totalSize: Int64
    let isAggregate: Bool
}

struct FileTreeIndex {
    static let empty = FileTreeIndex(root: nil)

    private(set) var nodesByID: [String: FileNode] = [:]
    private(set) var parentByID: [String: String] = [:]
    let rootID: String?

    init(root: FileNode?) {
        rootID = root?.id
        guard let root else { return }
        index(node: root, parentID: nil)
    }

    func node(id: String?) -> FileNode? {
        guard let id else { return nil }
        return nodesByID[id]
    }

    func parent(of id: String?) -> FileNode? {
        guard let id, let parentID = parentByID[id] else { return nil }
        return nodesByID[parentID]
    }

    func children(of id: String?) -> [FileNode] {
        if let node = node(id: id) {
            return node.children
        }
        if let rootID {
            return nodesByID[rootID]?.children ?? []
        }
        return []
    }

    func path(to id: String?) -> [FileNode] {
        guard let id, let node = nodesByID[id] else {
            guard let rootID, let root = nodesByID[rootID] else { return [] }
            return [root]
        }

        var result: [FileNode] = [node]
        var cursor = id
        while let parentID = parentByID[cursor], let parent = nodesByID[parentID] {
            result.append(parent)
            cursor = parentID
        }
        return result.reversed()
    }

    func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let descendantID else { return false }
        if ancestorID == descendantID {
            return true
        }

        var cursor = descendantID
        while let parentID = parentByID[cursor] {
            if parentID == ancestorID {
                return true
            }
            cursor = parentID
        }
        return false
    }

    private mutating func index(node: FileNode, parentID: String?) {
        nodesByID[node.id] = node
        if let parentID {
            parentByID[node.id] = parentID
        }

        for child in node.children {
            index(node: child, parentID: node.id)
        }
    }
}

extension FileNode {
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
}
