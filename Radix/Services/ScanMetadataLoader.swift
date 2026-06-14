//
//  ScanMetadataLoader.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Darwin
import Foundation

nonisolated struct ScanMetadataLoader: Sendable {
    static let scanResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    static let rootResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey
    ]
    static let atomicSummaryResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)
    static let atomicProbeResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey
    ]
    static let atomicProbeResourceKeySet = Set(atomicProbeResourceKeys)

    let diagnostics: ScanDiagnostics?

    func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? Self.rootResourceKeys : Self.scanResourceKeys
        let start = diagnostics?.start()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
            diagnostics?.record(operation: "metadata.resource_values", url: url, startedAt: start)
        } catch {
            diagnostics?.record(
                operation: "metadata.resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            throw error
        }
        return Self.nodeMetadata(
            for: url,
            resourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            diagnostics: diagnostics
        )
    }

    func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
        let start = diagnostics?.start()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            diagnostics?.record(operation: "metadata.atomic_resource_values", url: url, startedAt: start)
        } catch {
            diagnostics?.record(
                operation: "metadata.atomic_resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            throw error
        }
        return Self.nodeMetadata(for: url, resourceValues: values, diagnostics: diagnostics)
    }

    nonisolated static func nodeMetadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        diagnostics: ScanDiagnostics? = nil
    ) -> NodeMetadata {
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        let isReadable = values.isReadable ?? false
        var fileIdentity = Self.fileIdentity(from: values.fileResourceIdentifier)
        var linkCount = values.linkCount.map(UInt64.init) ?? 1
        if shouldReadFileSystemIdentity(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount
        ) {
            let fileSystemInfo = fileSystemInfo(for: url, diagnostics: diagnostics)
            fileIdentity = fileIdentity ?? fileSystemInfo.identity
            linkCount = values.linkCount.map(UInt64.init) ?? fileSystemInfo.linkCount
        }
        let volumeUsedCapacity: Int64?
        if includeVolumeDetails,
           let totalCapacity = values.volumeTotalCapacity,
           let availableCapacity = values.volumeAvailableCapacity {
            volumeUsedCapacity = Int64(max(totalCapacity - availableCapacity, 0))
        } else {
            volumeUsedCapacity = nil
        }

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable,
            volumeUsedCapacity: volumeUsedCapacity,
            fileIdentity: fileIdentity,
            linkCount: linkCount
        )
    }

    private nonisolated static func shouldReadFileSystemIdentity(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        fileIdentity: FileIdentity?,
        linkCount: Int?
    ) -> Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        guard let linkCount else { return true }
        return linkCount > 1 && fileIdentity == nil
    }

    private nonisolated static func fileSystemInfo(
        for url: URL,
        diagnostics: ScanDiagnostics? = nil
    ) -> (identity: FileIdentity?, linkCount: UInt64) {
        var fileStat = stat()
        let start = diagnostics?.start()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        diagnostics?.record(operation: "metadata.lstat", url: url, startedAt: start)
        guard result == 0 else {
            return (nil, 1)
        }

        return (
            FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            max(UInt64(fileStat.st_nlink), 1)
        )
    }

    private nonisolated static func fileIdentity(
        from resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> FileIdentity? {
        guard let identifierData = resourceIdentifier as? Data else { return nil }
        return FileIdentity(resourceIdentifier: identifierData)
    }
}

nonisolated struct NodeMetadata: Sendable {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeUsedCapacity: Int64?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
}

nonisolated enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64)

    nonisolated init(device: UInt64, inode: UInt64) {
        self = .fileSystem(device: device, inode: inode)
    }

    nonisolated init(resourceIdentifier: Data) {
        self = .resourceIdentifier(resourceIdentifier)
    }
}
