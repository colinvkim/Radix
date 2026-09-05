//
//  FileNodeRecord.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated struct FileNodeRecord: Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let unduplicatedAllocatedSize: Int64
    let dataAllocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let lastModified: Date?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
    let cloneIdentity: CloneIdentity?
    let mayShareDataBlocks: Bool
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
        unduplicatedAllocatedSize: Int64? = nil,
        dataAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        cloneIdentity: CloneIdentity? = nil,
        mayShareDataBlocks: Bool = false,
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
        self.unduplicatedAllocatedSize = unduplicatedAllocatedSize ?? allocatedSize
        self.dataAllocatedSize = min(
            max(dataAllocatedSize ?? unduplicatedAllocatedSize ?? allocatedSize, 0),
            max(unduplicatedAllocatedSize ?? allocatedSize, 0)
        )
        self.logicalSize = logicalSize
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.cloneIdentity = cloneIdentity
        self.mayShareDataBlocks = mayShareDataBlocks
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSelfAccessible = isSelfAccessible
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
    }

    var itemKind: String {
        if isSynthetic {
            return String(localized: "System Data", comment: "Kind label for storage that cannot be attributed to a regular file.")
        }
        if isAutoSummarized {
            return String(localized: "Summarized", comment: "Kind label for a directory whose contents are summarized for performance.")
        }
        if isSymbolicLink {
            return String(localized: "Alias", comment: "Kind label for a symbolic link.")
        }
        if isPackage {
            return String(localized: "Package", comment: "Kind label for an app bundle or package.")
        }
        return isDirectory
            ? String(localized: "Folder", comment: "Kind label for a directory.")
            : String(localized: "File", comment: "Kind label for a regular file.")
    }

    func itemKind(activeTarget: ScanTarget?) -> String {
        if let activeTarget,
           activeTarget.kind == .volume,
           isDirectory,
           !isSynthetic,
           url.standardizedFileURL.path == activeTarget.url.standardizedFileURL.path {
            return String(localized: "Volume", comment: "Kind label for the root of a scanned disk volume.")
        }
        return itemKind
    }

    var supportsFileActions: Bool {
        !isSynthetic
    }

    static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool
    ) -> FileNodeRecord {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true
        for child in children {
            allocatedSize += child.allocatedSize
            logicalSize += child.logicalSize
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount += 1
            }
        }
        let isFullyAccessible = isAccessible && childrenAreAccessible

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
    nonisolated func replacingAllocatedSize(_ allocatedSize: Int64) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            dataAllocatedSize: dataAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            cloneIdentity: cloneIdentity,
            mayShareDataBlocks: mayShareDataBlocks,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }

    nonisolated var systemImageName: String {
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
            return String(localized: "Estimated from volume usage", comment: "Secondary status shown for system storage estimated from volume usage.")
        }
        if isAutoSummarized {
            return String(localized: "Summarized (\(descendantFileCount) files)", comment: "Secondary status showing how many files are represented by a summarized directory.")
        }
        if !isAccessible {
            return String(localized: "Limited access", comment: "Secondary status for a file or folder that could not be fully read.")
        }
        return sharedStorageStatusText
    }

    var sharedStorageStatusText: String? {
        if cloneIdentity != nil {
            return String(localized: "APFS clone · shared storage", comment: "Secondary status for a full APFS clone whose data storage is shared with another file.")
        }
        if mayShareDataBlocks {
            return String(localized: "May share APFS storage", comment: "Secondary status for a file that may still share some APFS data blocks with another file.")
        }
        return nil
    }

    var sharedStorageDescription: String? {
        if cloneIdentity != nil {
            return String(
                localized: "APFS lets files share storage, but Finder may show the full file size for every clone. Radix counts shared bytes once, so one file carries the allocated size and the others may show zero. That file is only an accounting representative, not an original. Deleting one clone may not free the displayed amount.",
                comment: "Inspector explanation for a full APFS clone, Finder's size display, and Radix's shared-storage accounting."
            )
        }
        if mayShareDataBlocks {
            return String(
                localized: "Parts of this file may share APFS storage. macOS does not expose enough information for Radix to calculate exact shared or reclaimable bytes.",
                comment: "Inspector explanation for a file that may still share some APFS data blocks."
            )
        }
        return nil
    }

}
