//
//  ScanMetadataLoader.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Darwin
import Foundation

/// Thread-safe lookup shared by filesystem capabilities that are constant for
/// every item on a mounted volume.
private nonisolated final class VolumeCapabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var valueByRootPath: [String: Bool] = [:]

    func value(for url: URL) -> Bool? {
        let path = Self.normalizedPath(url.path)
        let mountedRoot = Self.inferredMountedRoot(for: path)
        lock.lock()
        defer { lock.unlock() }

        var result: (rootLength: Int, value: Bool)?
        for (root, value) in valueByRootPath
        where Self.contains(path, root: root)
            && mountedRoot.map({ Self.contains(root, root: $0) }) != false {
            if root.count > (result?.rootLength ?? -1) {
                result = (root.count, value)
            }
        }
        return result?.value
    }

    func store(_ value: Bool, for url: URL, volumeRootPath: String?) {
        let path = Self.normalizedPath(url.path)
        guard let root = volumeRootPath.map(Self.normalizedPath) ?? Self.inferredMountedRoot(for: path) else {
            return
        }
        lock.lock()
        valueByRootPath[root] = value
        lock.unlock()
    }

    private static func contains(_ path: String, root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : path == root || path.hasPrefix(root + "/")
    }

    private static func inferredMountedRoot(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return "/Volumes/\(components[1])"
    }

    private static func normalizedPath(_ path: String) -> String {
        // Normalize the cache key without probing whether this path is a directory.
        var result = URL(filePath: path, directoryHint: .inferFromPath).standardizedFileURL.path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

nonisolated final class LinkCountCapabilityCache: @unchecked Sendable {
    nonisolated struct ProbeResult: Sendable {
        let volumeRootPath: String?
        let supportsHardLinks: Bool?
        #if DEBUG
        let errorDescription: String?
        #endif

        init(
            volumeRootPath: String?,
            supportsHardLinks: Bool?,
            errorDescription: String? = nil
        ) {
            self.volumeRootPath = volumeRootPath
            self.supportsHardLinks = supportsHardLinks
            #if DEBUG
            self.errorDescription = errorDescription
            #endif
        }
    }

    typealias ProbeProvider = @Sendable (URL) -> ProbeResult

    private let probeProvider: ProbeProvider
    private let cache = VolumeCapabilityCache()

    init(probeProvider: @escaping ProbeProvider = LinkCountCapabilityCache.defaultProbe) {
        self.probeProvider = probeProvider
    }

    func requiresFileSystemInfoWhenLinkCountMissing(for url: URL, diagnostics: ScanDiagnosticsContext?) -> Bool {
        if let cachedRequirement = cache.value(for: url) {
            return cachedRequirement
        }

        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let probe = probeProvider(url)
        let requiresFileSystemInfo = probe.supportsHardLinks != false
        cache.store(requiresFileSystemInfo, for: url, volumeRootPath: probe.volumeRootPath)

        #if DEBUG
        diagnostics?.record(
            operation: "metadata.link_count_capability_probe",
            url: url,
            startedAt: start,
            detail: Self.diagnosticDetail(for: probe, requiresFileSystemInfo: requiresFileSystemInfo)
        )
        #endif
        return requiresFileSystemInfo
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
            #if DEBUG
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil,
                errorDescription: ScanWarningFactory.diagnosticErrorDescription(error)
            )
            #else
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil
            )
            #endif
        }
    }

    #if DEBUG
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
    #endif
}

/// Avoids requesting APFS clone metadata for every file on volumes that do not
/// expose clone mapping attributes. Supported volumes still require one probe
/// per regular file because the clone identity is file-specific.
nonisolated final class CloneMappingCapabilityCache: @unchecked Sendable {
    nonisolated struct ProbeResult: Sendable {
        let identity: CloneIdentity?
        let mayShareDataBlocks: Bool
        let supportsCloneMapping: Bool?

        init(
            identity: CloneIdentity?,
            mayShareDataBlocks: Bool = false,
            supportsCloneMapping: Bool?
        ) {
            self.identity = identity
            self.mayShareDataBlocks = mayShareDataBlocks
            self.supportsCloneMapping = supportsCloneMapping
        }
    }

    typealias ProbeProvider = @Sendable (URL) -> ProbeResult
    typealias VolumeRootProvider = @Sendable (URL) -> String?

    private let probeProvider: ProbeProvider
    private let volumeRootProvider: VolumeRootProvider
    private let cache = VolumeCapabilityCache()

    init(
        probeProvider: @escaping ProbeProvider = CloneMappingCapabilityCache.defaultProbe,
        volumeRootProvider: @escaping VolumeRootProvider = CloneMappingCapabilityCache.defaultVolumeRootPath
    ) {
        self.probeProvider = probeProvider
        self.volumeRootProvider = volumeRootProvider
    }

    func cloneMetadata(for url: URL) -> (identity: CloneIdentity?, mayShareDataBlocks: Bool) {
        let cachedSupport = cache.value(for: url)
        if cachedSupport == false {
            return (nil, false)
        }

        let probe = probeProvider(url)
        if cachedSupport == nil,
           let supportsCloneMapping = probe.supportsCloneMapping {
            cache.store(
                supportsCloneMapping,
                for: url,
                volumeRootPath: volumeRootProvider(url)
            )
        }
        return (probe.identity, probe.mayShareDataBlocks)
    }

    private static func defaultProbe(for url: URL) -> ProbeResult {
        ScanMetadataLoader.defaultCloneProbe(for: url)
    }

    private static func defaultVolumeRootPath(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL.path
    }
}

nonisolated struct ScanMetadataLoader: Sendable {
    struct FileStatus: Sendable {
        let fileFlags: UInt32
        let isDirectory: Bool
        let fileIdentity: FileIdentity?
        let linkCount: UInt64
        let allocatedSize: Int64?

        init(
            fileFlags: UInt32,
            isDirectory: Bool,
            fileIdentity: FileIdentity? = nil,
            linkCount: UInt64 = 1,
            allocatedSize: Int64? = nil
        ) {
            self.fileFlags = fileFlags
            self.isDirectory = isDirectory
            self.fileIdentity = fileIdentity
            self.linkCount = linkCount
            self.allocatedSize = allocatedSize
        }
    }

    typealias FileSystemInfoProvider = @Sendable (
        URL,
        ScanDiagnosticsContext?
    ) -> (identity: FileIdentity?, linkCount: UInt64)
    typealias FileAllocatedSizeProvider = @Sendable (URL) -> Int64?
    typealias FileStatusProvider = @Sendable (URL) -> FileStatus?

    static let cloneProbeOptions = UInt32(
        FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW | FSOPT_RETURN_REALDEV
    )

    static let scanResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .totalFileSizeKey,
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
        .totalFileSizeKey,
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
        .totalFileSizeKey,
        .isReadableKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]
    static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)
    static let atomicProbeResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileSizeKey
    ]
    static let atomicProbeResourceKeySet = Set(atomicProbeResourceKeys)

    let diagnostics: ScanDiagnosticsContext?
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let cloneMappingCapabilityCache: CloneMappingCapabilityCache
    private let fileSystemInfoProvider: FileSystemInfoProvider?
    private let fileAllocatedSizeProvider: FileAllocatedSizeProvider?
    private let fileStatusProvider: FileStatusProvider
    private let packageClassifier: PackageClassifier

    init(
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache = LinkCountCapabilityCache(),
        cloneMappingCapabilityCache: CloneMappingCapabilityCache = CloneMappingCapabilityCache(),
        fileSystemInfoProvider: FileSystemInfoProvider? = nil,
        fileAllocatedSizeProvider: FileAllocatedSizeProvider? = nil,
        fileStatusProvider: @escaping FileStatusProvider = ScanMetadataLoader.defaultFileStatus,
        packageClassifier: PackageClassifier = PackageClassifier()
    ) {
        self.diagnostics = diagnostics
        self.linkCountCapabilityCache = linkCountCapabilityCache
        self.cloneMappingCapabilityCache = cloneMappingCapabilityCache
        self.fileSystemInfoProvider = fileSystemInfoProvider
        self.fileAllocatedSizeProvider = fileAllocatedSizeProvider
        self.fileStatusProvider = fileStatusProvider
        self.packageClassifier = packageClassifier
    }

    func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? Self.rootResourceKeys : Self.scanResourceKeys
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
            #if DEBUG
            diagnostics?.record(operation: "metadata.resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return metadata(for: url, prefetchedResourceValues: values, includeVolumeDetails: includeVolumeDetails)
    }

    func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            #if DEBUG
            diagnostics?.record(operation: "metadata.atomic_resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.atomic_resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return atomicSummaryMetadata(for: url, prefetchedResourceValues: values)
    }

    func isPackageDirectory(
        at url: URL,
        hasFinderPackageFlag: Bool? = nil
    ) -> Bool {
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let classification = packageClassifier.classification(
            for: url,
            hasFinderPackageFlag: hasFinderPackageFlag
        )
        #if DEBUG
        switch classification.source {
        case .foundation:
            diagnostics?.record(operation: "metadata.package", url: url, startedAt: start)
        case .fastNegative:
            diagnostics?.record(operation: "metadata.package.fast_negative", url: url, startedAt: start)
        case .finderInfo:
            diagnostics?.record(operation: "metadata.package.finder_info", url: url, startedAt: start)
        case .extensionCache:
            diagnostics?.record(operation: "metadata.package.extension_cache", url: url, startedAt: start)
        }
        #endif
        return classification.isPackage
    }

    nonisolated func metadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        loadsSymbolicLinkFileSystemInfo: Bool = true
    ) -> NodeMetadata {
        Self.nodeMetadata(
            for: url,
            resourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            loadsSymbolicLinkFileSystemInfo: loadsSymbolicLinkFileSystemInfo,
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache,
            cloneMappingCapabilityCache: cloneMappingCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider,
            fileAllocatedSizeProvider: fileAllocatedSizeProvider,
            fileStatusProvider: fileStatusProvider
        )
    }

    nonisolated func atomicSummaryMetadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues
    ) -> NodeMetadata {
        metadata(
            for: url,
            prefetchedResourceValues: values,
            loadsSymbolicLinkFileSystemInfo: false
        )
    }

    /// Loads the descriptor-independent identity used to protect Foundation's
    /// path-based directory enumeration from persistent replacement.
    nonisolated func fileSystemIdentity(at url: URL) throws -> FileIdentity {
        guard let identity = (fileSystemInfoProvider ?? Self.defaultFileSystemInfo)(url, diagnostics).identity,
              identity.isFileSystemIdentity else {
            throw Self.staleFileSystemIdentityError(for: url)
        }
        return identity
    }

    /// Best-effort callers pass `nil`; protected callers fail closed when the
    /// current path no longer names the filesystem object they discovered.
    nonisolated func validateFileSystemIdentity(
        _ expectedIdentity: FileIdentity?,
        at url: URL
    ) throws {
        guard let expectedIdentity, expectedIdentity.isFileSystemIdentity else { return }
        guard try fileSystemIdentity(at: url) == expectedIdentity else {
            throw Self.staleFileSystemIdentityError(for: url)
        }
    }

    private nonisolated static func staleFileSystemIdentityError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ESTALE),
            userInfo: [NSURLErrorKey: url]
        )
    }

    private nonisolated static func nodeMetadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        loadsSymbolicLinkFileSystemInfo: Bool,
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        cloneMappingCapabilityCache: CloneMappingCapabilityCache,
        fileSystemInfoProvider: FileSystemInfoProvider?,
        fileAllocatedSizeProvider: FileAllocatedSizeProvider?,
        fileStatusProvider: FileStatusProvider
    ) -> NodeMetadata {
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        // Reuse this load's lstat fields; identity validation before/after
        // enumeration deliberately performs separate fresh reads.
        let status = fileStatusProvider(url)
        let isDataless = isDataless(fileFlags: status?.fileFlags)
        func fileSystemInfo() -> (identity: FileIdentity?, linkCount: UInt64) {
            if let fileSystemInfoProvider { return fileSystemInfoProvider(url, diagnostics) }
            if let status, let identity = status.fileIdentity { return (identity, status.linkCount) }
            return defaultFileSystemInfo(for: url, diagnostics: diagnostics)
        }
        func fallbackAllocatedSize() -> Int64? {
            if let fileAllocatedSizeProvider { return fileAllocatedSizeProvider(url) }
            return status?.allocatedSize ?? defaultFileStatus(for: url)?.allocatedSize
        }
        let logicalSize = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        let allocatedSize = values.totalFileAllocatedSize.map(Int64.init)
            ?? values.fileAllocatedSize.map(Int64.init)
            ?? fallbackAllocatedSize()
            ?? 0
        let dataAllocatedSize = min(
            max(values.fileAllocatedSize.map(Int64.init) ?? allocatedSize, 0),
            max(allocatedSize, 0)
        )
        let isReadable = values.isReadable ?? false
        var fileIdentity = Self.fileIdentity(from: values.fileResourceIdentifier)
        var linkCount = values.linkCount.map(UInt64.init) ?? 1
        if isSymbolicLink && loadsSymbolicLinkFileSystemInfo {
            let fileSystemInfo = fileSystemInfo()
            fileIdentity = fileSystemInfo.identity
            linkCount = fileSystemInfo.linkCount
        } else if isDirectory && loadsSymbolicLinkFileSystemInfo {
            let fileSystemInfo = fileSystemInfo()
            fileIdentity = fileSystemInfo.identity ?? fileIdentity
        } else if shouldReadFileSystemIdentity(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            url: url,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount,
            linkCountCapabilityCache: linkCountCapabilityCache,
            diagnostics: diagnostics
        ) {
            let fileSystemInfo = fileSystemInfo()
            fileIdentity = fileIdentity ?? fileSystemInfo.identity
            linkCount = values.linkCount.map(UInt64.init) ?? fileSystemInfo.linkCount
        }
        let cloneMetadata = !isDirectory && !isSymbolicLink
            ? cloneMappingCapabilityCache.cloneMetadata(for: url)
            : (identity: nil, mayShareDataBlocks: false)
        let volumeCapacity: VolumeCapacitySnapshot?
        if includeVolumeDetails,
           let totalCapacity = values.volumeTotalCapacity,
           let availableCapacity = values.volumeAvailableCapacity {
            volumeCapacity = VolumeCapacitySnapshot(
                totalCapacity: Int64(totalCapacity),
                availableCapacity: Int64(availableCapacity)
            )
        } else {
            volumeCapacity = nil
        }

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isDataless: isDataless,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            dataAllocatedSize: dataAllocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable,
            volumeCapacity: volumeCapacity,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            cloneIdentity: cloneMetadata.identity,
            mayShareDataBlocks: cloneMetadata.mayShareDataBlocks
        )
    }

    private nonisolated static func shouldReadFileSystemIdentity(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        url: URL,
        fileIdentity: FileIdentity?,
        linkCount: Int?,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        diagnostics: ScanDiagnosticsContext?
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
        diagnostics: ScanDiagnosticsContext? = nil
    ) -> (identity: FileIdentity?, linkCount: UInt64) {
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let status = defaultFileStatus(for: url)
        #if DEBUG
        diagnostics?.record(operation: "metadata.lstat", url: url, startedAt: start)
        #endif
        return (status?.fileIdentity, status?.linkCount ?? 1)
    }

    nonisolated func datalessStatus(at url: URL) -> FileStatus? {
        guard let status = fileStatusProvider(url),
              Self.isDataless(fileFlags: status.fileFlags) else {
            return nil
        }
        return status
    }

    nonisolated static func isDataless(fileFlags: UInt32?) -> Bool {
        guard let fileFlags else { return false }
        return fileFlags & UInt32(SF_DATALESS) != 0
    }

    private nonisolated static func defaultFileStatus(for url: URL) -> FileStatus? {
        var fileStat = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        guard result == 0 else { return nil }
        let blocks = max(Int64(fileStat.st_blocks), 0)
        let (allocatedSize, overflow) = blocks.multipliedReportingOverflow(by: 512)
        return FileStatus(
            fileFlags: fileStat.st_flags,
            isDirectory: fileStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            fileIdentity: FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            linkCount: max(UInt64(fileStat.st_nlink), 1),
            allocatedSize: overflow ? Int64.max : allocatedSize
        )
    }

    nonisolated static func defaultCloneProbe(for url: URL) -> CloneMappingCapabilityCache.ProbeResult {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_DEVID)
        attributes.forkattr = attrgroup_t(
            ATTR_CMNEXT_CLONEID |
            ATTR_CMNEXT_EXT_FLAGS |
            ATTR_CMNEXT_CLONE_REFCNT
        )

        var buffer = [UInt8](repeating: 0, count: 64)
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return buffer.withUnsafeMutableBytes { rawBuffer in
                getattrlist(
                    path,
                    &attributes,
                    rawBuffer.baseAddress,
                    rawBuffer.count,
                    cloneProbeOptions
                )
            }
        }
        guard result == 0 else {
            let unsupported = errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL
            return CloneMappingCapabilityCache.ProbeResult(
                identity: nil,
                supportsCloneMapping: unsupported ? false : nil
            )
        }

        return buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  rawBuffer.count >= MemoryLayout<UInt32>.size else {
                return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: nil)
            }
            let reportedLength = Int(baseAddress.loadUnaligned(as: UInt32.self))
            guard reportedLength >= MemoryLayout<UInt32>.size,
                  reportedLength <= rawBuffer.count else {
                return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: nil)
            }

            var cursor = ScanMetadataAttributeCursor(
                current: baseAddress.advanced(by: MemoryLayout<UInt32>.size),
                end: baseAddress.advanced(by: reportedLength)
            )
            guard let returned: attribute_set_t = cursor.read() else {
                return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: nil)
            }
            let requiredForkAttributes = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0,
                  returned.forkattr & requiredForkAttributes == requiredForkAttributes,
                  let deviceID: dev_t = cursor.read(),
                  let cloneID: UInt64 = cursor.read() else {
                return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: false)
            }
            let extendedFlags: UInt64
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                guard let value: UInt64 = cursor.read() else {
                    return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: nil)
                }
                extendedFlags = value
            } else {
                extendedFlags = 0
            }
            guard let cloneReferenceCount: UInt32 = cursor.read() else {
                return CloneMappingCapabilityCache.ProbeResult(identity: nil, supportsCloneMapping: nil)
            }
            let identity = cloneID > 0 && cloneReferenceCount > 1
                ? CloneIdentity(device: UInt64(truncatingIfNeeded: deviceID), cloneID: cloneID)
                : nil
            return CloneMappingCapabilityCache.ProbeResult(
                identity: identity,
                mayShareDataBlocks: extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0,
                supportsCloneMapping: true
            )
        }
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
    let isDataless: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let dataAllocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeCapacity: VolumeCapacitySnapshot?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
    let cloneIdentity: CloneIdentity?
    let mayShareDataBlocks: Bool

    init(
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isDataless: Bool = false,
        logicalSize: Int64,
        allocatedSize: Int64,
        dataAllocatedSize: Int64? = nil,
        lastModified: Date?,
        isReadable: Bool,
        volumeCapacity: VolumeCapacitySnapshot?,
        fileIdentity: FileIdentity?,
        linkCount: UInt64,
        cloneIdentity: CloneIdentity? = nil,
        mayShareDataBlocks: Bool = false
    ) {
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isDataless = isDataless
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.dataAllocatedSize = min(max(dataAllocatedSize ?? allocatedSize, 0), max(allocatedSize, 0))
        self.lastModified = lastModified
        self.isReadable = isReadable
        self.volumeCapacity = volumeCapacity
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.cloneIdentity = cloneIdentity
        self.mayShareDataBlocks = mayShareDataBlocks
    }
}

nonisolated struct CloneIdentity: Hashable, Sendable {
    let device: UInt64
    let cloneID: UInt64
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

    nonisolated var isFileSystemIdentity: Bool {
        if case .fileSystem = self {
            return true
        }
        return false
    }

    nonisolated var fileSystemDeviceID: UInt64? {
        if case .fileSystem(let device, _) = self {
            return device
        }
        return nil
    }
}

private nonisolated struct ScanMetadataAttributeCursor {
    var current: UnsafeRawPointer
    let end: UnsafeRawPointer

    mutating func read<T>() -> T? {
        let size = MemoryLayout<T>.size
        let alignedSize = (size + 3) & ~3
        guard size <= current.distance(to: end),
              alignedSize <= current.distance(to: end) else {
            return nil
        }
        let value = current.loadUnaligned(as: T.self)
        current = current.advanced(by: alignedSize)
        return value
    }
}
