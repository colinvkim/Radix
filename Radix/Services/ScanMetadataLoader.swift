//
//  ScanMetadataLoader.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Darwin
import Foundation

nonisolated final class LinkCountCapabilityCache: @unchecked Sendable {
    nonisolated struct ProbeResult: Sendable {
        let volumeRootPath: String?
        let supportsHardLinks: Bool?
        let errorDescription: String?

        init(
            volumeRootPath: String?,
            supportsHardLinks: Bool?,
            errorDescription: String? = nil
        ) {
            self.volumeRootPath = volumeRootPath
            self.supportsHardLinks = supportsHardLinks
            self.errorDescription = errorDescription
        }
    }

    typealias ProbeProvider = @Sendable (URL) -> ProbeResult

    private let lock = NSLock()
    private let probeProvider: ProbeProvider
    private var requiresFileSystemInfoByRootPath: [String: Bool] = [:]

    init(probeProvider: @escaping ProbeProvider = LinkCountCapabilityCache.defaultProbe) {
        self.probeProvider = probeProvider
    }

    func requiresFileSystemInfoWhenLinkCountMissing(
        for url: URL,
        diagnostics: ScanDiagnostics?
    ) -> Bool {
        let path = Self.standardizedPath(for: url)
        lock.lock()
        if let cachedRequirement = cachedRequirementLocked(for: path) {
            lock.unlock()
            return cachedRequirement
        }
        lock.unlock()

        let start = diagnostics?.start()
        let probe = probeProvider(url)
        let requiresFileSystemInfo = probe.supportsHardLinks != false
        if let rootPath = Self.cacheRootPath(for: probe, path: path) {
            lock.lock()
            requiresFileSystemInfoByRootPath[rootPath] = requiresFileSystemInfo
            lock.unlock()
        }

        diagnostics?.record(
            operation: "metadata.link_count_capability_probe",
            url: url,
            startedAt: start,
            detail: Self.diagnosticDetail(for: probe, requiresFileSystemInfo: requiresFileSystemInfo)
        )
        return requiresFileSystemInfo
    }

    private func cachedRequirementLocked(for path: String) -> Bool? {
        var bestMatch: (rootLength: Int, requiresFileSystemInfo: Bool)?
        for (rootPath, requiresFileSystemInfo) in requiresFileSystemInfoByRootPath
        where Self.path(path, isUnder: rootPath) {
            if bestMatch == nil || rootPath.count > bestMatch!.rootLength {
                bestMatch = (rootPath.count, requiresFileSystemInfo)
            }
        }
        return bestMatch?.requiresFileSystemInfo
    }

    private static func defaultProbe(for url: URL) -> ProbeResult {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeURLKey,
                .volumeSupportsHardLinksKey
            ])
            return ProbeResult(
                volumeRootPath: values.volume?.standardizedFileURL.path,
                supportsHardLinks: values.volumeSupportsHardLinks
            )
        } catch {
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil,
                errorDescription: ScanWarningFactory.diagnosticErrorDescription(error)
            )
        }
    }

    private static func diagnosticDetail(
        for probe: ProbeResult,
        requiresFileSystemInfo: Bool
    ) -> String {
        var fields = [
            "supports_hard_links=\(probe.supportsHardLinks.map(String.init) ?? "unknown")",
            "fallback_lstat=\(requiresFileSystemInfo)"
        ]
        if let volumeRootPath = probe.volumeRootPath {
            fields.append("volume=\(volumeRootPath)")
        }
        if let errorDescription = probe.errorDescription {
            fields.append("error=\(errorDescription)")
        }
        return fields.joined(separator: " ")
    }

    private static func path(_ path: String, isUnder rootPath: String) -> Bool {
        guard rootPath != "/" else {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func standardizedPath(for url: URL) -> String {
        normalizedRootPath(url.standardizedFileURL.path)
    }

    private static func normalizedRootPath(_ path: String) -> String {
        var normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return normalizedPath
    }

    private static func cacheRootPath(for probe: ProbeResult, path: String) -> String? {
        if let volumeRootPath = probe.volumeRootPath {
            return normalizedRootPath(volumeRootPath)
        }
        return inferredMountedVolumeRootPath(for: path)
    }

    private static func inferredMountedVolumeRootPath(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            return "/Volumes/\(components[1])"
        }
        return nil
    }
}

nonisolated struct ScanMetadataLoader: Sendable {
    typealias FileSystemInfoProvider = @Sendable (
        URL,
        ScanDiagnostics?
    ) -> (identity: FileIdentity?, linkCount: UInt64)

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
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let fileSystemInfoProvider: FileSystemInfoProvider

    init(
        diagnostics: ScanDiagnostics?,
        linkCountCapabilityCache: LinkCountCapabilityCache = LinkCountCapabilityCache(),
        fileSystemInfoProvider: @escaping FileSystemInfoProvider = ScanMetadataLoader.defaultFileSystemInfo
    ) {
        self.diagnostics = diagnostics
        self.linkCountCapabilityCache = linkCountCapabilityCache
        self.fileSystemInfoProvider = fileSystemInfoProvider
    }

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
        return metadata(for: url, prefetchedResourceValues: values, includeVolumeDetails: includeVolumeDetails)
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
        return metadata(for: url, prefetchedResourceValues: values)
    }

    nonisolated func metadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false
    ) -> NodeMetadata {
        Self.nodeMetadata(
            for: url,
            resourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )
    }

    private nonisolated static func nodeMetadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        diagnostics: ScanDiagnostics? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        fileSystemInfoProvider: FileSystemInfoProvider
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
            url: url,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount,
            linkCountCapabilityCache: linkCountCapabilityCache,
            diagnostics: diagnostics
        ) {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
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
        url: URL,
        fileIdentity: FileIdentity?,
        linkCount: Int?,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        diagnostics: ScanDiagnostics?
    ) -> Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        guard let linkCount else {
            return linkCountCapabilityCache.requiresFileSystemInfoWhenLinkCountMissing(
                for: url,
                diagnostics: diagnostics
            )
        }
        return linkCount > 1 && fileIdentity == nil
    }

    private nonisolated static func defaultFileSystemInfo(
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
