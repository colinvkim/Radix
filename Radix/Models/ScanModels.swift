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
}

enum ScanWarningCategory: String, Hashable, Sendable {
    case permissionDenied
    case fileSystem
    case cancelled
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

    nonisolated var containsChildren: Bool {
        !children.isEmpty
    }

    nonisolated var itemKind: String {
        if isSynthetic {
            return "System Data"
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

        let byteFraction: Double
        if estimatedTotalBytes > 0 {
            byteFraction = min(Double(bytesDiscovered) / Double(estimatedTotalBytes), 0.99)
        } else {
            byteFraction = 0
        }

        let itemFraction: Double
        if estimatedTotalBytes == 0, discoveredItems > 0 {
            itemFraction = min(Double(completedItems) / Double(discoveredItems), 0.9)
        } else {
            itemFraction = 0
        }

        let hasStarted = filesVisited > 0 || directoriesVisited > 0 || discoveredItems > 0
        let minimumVisibleProgress = hasStarted ? 0.01 : 0
        progressFraction = max(progressFraction, max(byteFraction, itemFraction, minimumVisibleProgress))
    }
}

enum ScanProgressEvent: Sendable {
    case progress(ScanMetrics)
    case warning(ScanWarning)
    case snapshot(ScanSnapshot)
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
