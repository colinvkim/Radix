import Foundation
@testable import RadixCore

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = []
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
}
