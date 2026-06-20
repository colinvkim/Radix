//
//  FileNodeRecord.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

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
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
    let isPackage: Bool
    let isAccessible: Bool
    let isSelfAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    init(
        id: String,
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSelfAccessible = isSelfAccessible
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
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

    nonisolated static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
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
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false
        )
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

}
