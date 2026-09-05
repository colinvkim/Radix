//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Darwin
import Dispatch
import Foundation

private nonisolated final class DirectoryNamespaceResolver: @unchecked Sendable {
    private struct Mapping {
        let presentedRootPath: String
        let resolvedRootPath: String
    }

    private let lock = NSLock()
    private var mappings: [Mapping] = []

    func preservingParentNamespace(_ contents: [URL], under parentURL: URL) -> [URL] {
        let parentPath = parentURL.path
        guard let enumeratedParentPath = contents.lazy
            .map({ $0.deletingLastPathComponent().path })
            .first(where: { $0 != parentPath }) else {
            return contents
        }

        if let resolvedParentPath = cachedResolvedPath(
            forPresentedPath: parentPath,
            matching: enumeratedParentPath
        ) {
            return replacingParentNamespace(
                in: contents,
                from: resolvedParentPath,
                to: parentURL
            )
        }

        guard let resolvedParentPath = resolvedFileSystemPath(parentURL),
              resolvedParentPath != parentPath,
              enumeratedParentPath == resolvedParentPath else {
            return contents
        }
        cacheMapping(
            presentedRootPath: parentPath,
            resolvedRootPath: resolvedParentPath
        )
        return replacingParentNamespace(
            in: contents,
            from: resolvedParentPath,
            to: parentURL
        )
    }

    private func cachedResolvedPath(
        forPresentedPath presentedPath: String,
        matching candidate: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for mapping in mappings {
            guard let suffix = pathSuffix(presentedPath, under: mapping.presentedRootPath) else {
                continue
            }
            let resolvedPath = mapping.resolvedRootPath + suffix
            if candidate == resolvedPath {
                return resolvedPath
            }
        }
        return nil
    }

    private func cacheMapping(presentedRootPath: String, resolvedRootPath: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !mappings.contains(where: {
            $0.presentedRootPath == presentedRootPath && $0.resolvedRootPath == resolvedRootPath
        }) else {
            return
        }
        mappings.append(Mapping(
            presentedRootPath: presentedRootPath,
            resolvedRootPath: resolvedRootPath
        ))
    }

    private func pathSuffix(_ path: String, under rootPath: String) -> String? {
        if path == rootPath {
            return ""
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private func replacingParentNamespace(
        in contents: [URL],
        from resolvedParentPath: String,
        to presentedParentURL: URL
    ) -> [URL] {
        contents.map { childURL in
            guard childURL.deletingLastPathComponent().path == resolvedParentPath else {
                return childURL
            }
            let parentPath = presentedParentURL.path
            let childPath = parentPath == "/"
                ? parentPath + childURL.lastPathComponent
                : parentPath + "/" + childURL.lastPathComponent
            return URL(
                filePath: childPath,
                directoryHint: childURL.hasDirectoryPath ? .isDirectory : .notDirectory
            )
        }
    }

    private func resolvedFileSystemPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return String(cString: resolvedPath)
        }
    }
}

actor ScanEngine {
    protocol DirectoryObjectEnumerating: AnyObject {
        func nextObject() -> Any?
    }

    private enum ScanEngineError: LocalizedError {
        case cloudOnlyRoot
        case missingRootNode

        var errorDescription: String? {
            switch self {
            case .cloudOnlyRoot:
                return String(localized: "The selected item is stored only in cloud storage and has no on-disk data to scan.", comment: "Error shown when the user tries to scan a cloud-only placeholder.")
            case .missingRootNode:
                return String(localized: "The scan could not assemble a root node.", comment: "Error shown when a completed scan has no root node.")
            }
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
    }

    nonisolated struct ScanMountedFileSystem: Sendable {
        let mountPath: String
        let deviceName: String
        let fileSystemType: String
        let deviceID: UInt64?

        init(
            mountPath: String,
            deviceName: String,
            fileSystemType: String,
            deviceID: UInt64? = nil
        ) {
            self.mountPath = mountPath
            self.deviceName = deviceName
            self.fileSystemType = fileSystemType
            self.deviceID = deviceID
        }
    }

    /// Decides whether directory traversal may cross a device boundary. Nested
    /// mounts from foreign containers (DMGs, network shares, autofs, other disks)
    /// become leaf nodes so their bytes are not folded into the scanned tree,
    /// while firmlinked volumes of the scan root's own APFS container remain
    /// traversable (a startup-scan must reach the Data volume's user data).
    nonisolated struct ScanVolumeBoundaryPolicy: Sendable {
        private let rootDeviceID: UInt64?
        private let containerDeviceIDs: Set<UInt64>

        static let unrestricted = ScanVolumeBoundaryPolicy(
            rootDeviceID: nil,
            containerDeviceIDs: []
        )

        static func resolve(
            rootPath: String,
            rootDeviceID: UInt64?,
            mountedFileSystems: [ScanMountedFileSystem]
        ) -> ScanVolumeBoundaryPolicy {
            let normalizedRootPath = normalizedMountPath(rootPath)
            let rootMount = mountedFileSystems
                .filter {
                    isPath(
                        normalizedRootPath,
                        within: normalizedMountPath($0.mountPath)
                    )
                }
                .max { $0.mountPath.count < $1.mountPath.count }
            guard let rootMount,
                  let rootContainerID = containerIdentifier(of: rootMount) else {
                return ScanVolumeBoundaryPolicy(
                    rootDeviceID: rootDeviceID,
                    containerDeviceIDs: []
                )
            }

            let containerDeviceIDs = Set(mountedFileSystems
                .filter {
                    $0.fileSystemType == "apfs"
                        && containerIdentifier(of: $0) == rootContainerID
                }
                .compactMap(\.deviceID))

            return ScanVolumeBoundaryPolicy(
                rootDeviceID: rootDeviceID,
                containerDeviceIDs: containerDeviceIDs
            )
        }

        func shouldStopDescent(childDeviceID: UInt64?) -> Bool {
            guard let rootDeviceID else { return false }
            guard let childDeviceID else { return true }
            guard childDeviceID != rootDeviceID else { return false }
            return !containerDeviceIDs.contains(childDeviceID)
        }

        var requiresChildDeviceIdentity: Bool {
            rootDeviceID != nil
        }

        func descentBoundaryError(for url: URL, childDeviceID: UInt64?) -> Error? {
            guard shouldStopDescent(childDeviceID: childDeviceID) else { return nil }
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EXDEV),
                userInfo: [NSURLErrorKey: url]
            )
        }

        private static func normalizedMountPath(_ path: String) -> String {
            var path = path
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }

        private static func isPath(_ path: String, within mountPath: String) -> Bool {
            if mountPath == "/" {
                return path.hasPrefix("/")
            }
            return path == mountPath || path.hasPrefix(mountPath + "/")
        }

        /// APFS synthesizer names encode the container in the disk number:
        /// "disk3s5" and "disk3s1s1" both belong to container "disk3".
        private static func containerIdentifier(of mount: ScanMountedFileSystem) -> String? {
            let deviceName = (mount.deviceName as NSString).lastPathComponent
            guard let match = deviceName.firstMatch(of: /^disk(\d+)(s\d+)+$/) else {
                return deviceName.isEmpty ? nil : deviceName
            }
            return "disk\(match.1)"
        }
    }

    private struct AggregateStatsAccumulator {
        private(set) var fileCount = 0
        private(set) var directoryCount = 0
        private(set) var accessibleItemCount = 0
        private(set) var inaccessibleItemCount = 0

        mutating func include(_ node: FileNodeRecord, hasChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !hasChildren {
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

        func makeStats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    /// `weight` is this subtree's share of the scan's total progress (the root is 1);
    /// a directory's weight is split among its children when it is enumerated.
    private struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let parentKey: Int
        let depth: Int
        let weight: Double
        let parentDirectoryLease: ScanDirectoryDescriptorPool.Lease?
        let nativeName: BulkDirectoryEnumerator.NativeName?
        let skipsDescendantAutoSummaryProbe: Bool

        init(
            url: URL,
            metadata: NodeMetadata?,
            localizedEnumerationError: Error?,
            isDirectoryHint: Bool?,
            parentKey: Int,
            depth: Int,
            weight: Double,
            parentDirectoryLease: ScanDirectoryDescriptorPool.Lease? = nil,
            nativeName: BulkDirectoryEnumerator.NativeName? = nil,
            skipsDescendantAutoSummaryProbe: Bool = false
        ) {
            self.url = url
            self.metadata = metadata
            self.localizedEnumerationError = localizedEnumerationError
            self.isDirectoryHint = isDirectoryHint
            self.parentKey = parentKey
            self.depth = depth
            self.weight = weight
            self.parentDirectoryLease = parentDirectoryLease
            self.nativeName = nativeName
            self.skipsDescendantAutoSummaryProbe = skipsDescendantAutoSummaryProbe
        }
    }

    struct DirectoryEnumerationFailure: Sendable {
        let url: URL
        let error: Error
        let isDirectoryHint: Bool?

        init(url: URL, error: Error, isDirectoryHint: Bool? = nil) {
            self.url = url
            self.error = error
            self.isDirectoryHint = isDirectoryHint
        }
    }

    struct DirectoryEnumerationResult: Sendable {
        let urls: [URL]
        let localizedFailures: [DirectoryEnumerationFailure]

        init(urls: [URL], localizedFailures: [DirectoryEnumerationFailure] = []) {
            self.urls = urls
            self.localizedFailures = localizedFailures
        }
    }

    struct ShallowDirectoryListing: Sendable {
        let directoryMetadata: NodeMetadata
        let entries: [DirectoryEntry]
    }

    private struct DirectoryContentsScanResult: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        let directoryLease: ScanDirectoryDescriptorPool.Lease?
        #if DEBUG
        let enumerationNanoseconds: UInt64
        let classificationNanoseconds: UInt64
        let reusedProbeListing: Bool
        #endif
    }

    private struct ClassifiedDirectoryEntriesChunk: Sendable {
        let index: Int
        let entries: [DirectoryEntry]
    }

    private struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: DirectoryContentsScanResult
        let childDirectoryCount: Int
        let totalWeightUnits: Double
        let isNodeDependencyLayout: Bool
        let isAtomicSummaryCandidate: Bool
    }

    private struct DirectoryTraversalFailure: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let warning: ScanWarning
        #if DEBUG
        let elapsedNanoseconds: UInt64
        let diagnosticDetail: String
        #endif

        #if DEBUG
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning,
            elapsedNanoseconds: UInt64,
            diagnosticDetail: String
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
            self.elapsedNanoseconds = elapsedNanoseconds
            self.diagnosticDetail = diagnosticDetail
        }
        #else
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
        }
        #endif
    }

    private enum DirectoryTraversalResult: Sendable {
        case success(DirectoryTraversalSuccess)
        case failure(DirectoryTraversalFailure)
    }

    private struct LeafNodeResult: Sendable {
        let node: FileNodeRecord
        let warnings: [ScanWarning]
        let sharedAllocationAccumulator: SharedAllocationOwnerAccumulator
        let minimumAllocatedSize: Int64?
        let summaryVisitedItemCount: Int
    }

    private struct OrdinaryLeafPreparationRequest: Sendable {
        let entries: [DirectoryEntry]
        let range: Range<Int>
        let parentKey: Int
        let parentWeight: Double
        let totalWeightUnits: Double
    }

    private struct PreparedOrdinaryLeafItem: Sendable {
        let weight: Double
        let node: FileNodeRecord
        let sharedAllocationClaim: SharedAllocationClaim?
    }

    private struct PreparedOrdinaryLeafBatch: Sendable {
        let parentKey: Int
        let items: [PreparedOrdinaryLeafItem]
    }

    private struct PackageSummaryResult: Sendable {
        let itemKey: Int
        let weight: Double
        let leaf: LeafNodeResult
    }

    /// An enumerated directory that passed the cheap atomic-summary gates and is
    /// waiting for (or has finished) its pooled probe/summary off the scheduling loop.
    private struct AtomicDirectoryScanCandidate: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: DirectoryContentsScanResult
        let childDirectoryCount: Int
        let totalWeightUnits: Double
        let isNodeDependencyLayout: Bool
    }

    private struct AtomicDirectoryScanResult: Sendable {
        let candidate: AtomicDirectoryScanCandidate
        let decision: AtomicDirectorySummaryDecision
    }

    private enum ScanTaskResult: Sendable {
        case directory(DirectoryTraversalResult)
        case package(PackageSummaryResult)
        case atomicDirectory(AtomicDirectoryScanResult)
        case ordinaryLeaves(PreparedOrdinaryLeafBatch)
    }

    /// A completed directory scan awaiting parent assembly.
    private enum CompletedDirScan {
        case leaf(FileNodeRecord)
        case traversableDirectory(metadata: NodeMetadata, url: URL)
    }

    typealias DirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult

    typealias URLDirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> [URL]

    typealias VolumeFileSystemTypeProvider = @Sendable (URL) -> String?
    typealias DirectoryDescriptorPoolFactory = @Sendable () -> ScanDirectoryDescriptorPool
    #if DEBUG
    typealias AutoSummaryProfileReporter = @Sendable (ScanAutoSummaryProfileEvent) -> Void
    #endif

    private let directoryContents: DirectoryContentsProvider
    private let usesBulkDirectoryEnumeration: Bool
    private let usesDeferredBulkEntryFiltering: Bool
    private let directoryNamespaceResolver: DirectoryNamespaceResolver
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver?
    private let atomicSummaryProgressEmissionInterval: TimeInterval
    #if DEBUG
    private let autoSummaryProfileReporter: AutoSummaryProfileReporter?
    #endif
    private let volumeFileSystemTypeProvider: VolumeFileSystemTypeProvider
    private let directoryDescriptorPoolFactory: DirectoryDescriptorPoolFactory
    private let usesWorkerSideLeafPreparation: Bool
    private let workerSideLeafPreparationBatchLimit: Int

    init(
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15,
        directoryDescriptorPoolFactory: @escaping DirectoryDescriptorPoolFactory = {
            ScanDirectoryDescriptorPool()
        },
        usesDeferredBulkEntryFiltering: Bool = true,
        usesWorkerSideLeafPreparation: Bool = true,
        workerSideLeafPreparationBatchLimit: Int? = nil
    ) {
        self.init(
            enumeratedDirectoryContents: ScanEngine.defaultDirectoryContents,
            volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
            usesBulkDirectoryEnumeration: true,
            atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
            atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval,
            directoryDescriptorPoolFactory: directoryDescriptorPoolFactory,
            usesDeferredBulkEntryFiltering: usesDeferredBulkEntryFiltering,
            usesWorkerSideLeafPreparation: usesWorkerSideLeafPreparation,
            workerSideLeafPreparationBatchLimit: workerSideLeafPreparationBatchLimit
        )
    }

    #if DEBUG
    init(
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15,
        directoryDescriptorPoolFactory: @escaping DirectoryDescriptorPoolFactory = {
            ScanDirectoryDescriptorPool()
        },
        usesDeferredBulkEntryFiltering: Bool = true,
        usesWorkerSideLeafPreparation: Bool = true,
        workerSideLeafPreparationBatchLimit: Int? = nil,
        autoSummaryProfileReporter: @escaping AutoSummaryProfileReporter
    ) {
        self.directoryContents = ScanEngine.defaultDirectoryContents
        self.usesBulkDirectoryEnumeration = true
        self.usesDeferredBulkEntryFiltering = usesDeferredBulkEntryFiltering
        self.directoryNamespaceResolver = DirectoryNamespaceResolver()
        self.linkCountCapabilityCache = LinkCountCapabilityCache()
        self.atomicSummaryWorkerObserver = atomicSummaryWorkerObserver
        self.atomicSummaryProgressEmissionInterval = max(atomicSummaryProgressEmissionInterval, 0)
        self.autoSummaryProfileReporter = autoSummaryProfileReporter
        self.volumeFileSystemTypeProvider = volumeFileSystemTypeProvider
        self.directoryDescriptorPoolFactory = directoryDescriptorPoolFactory
        self.usesWorkerSideLeafPreparation = usesWorkerSideLeafPreparation
        self.workerSideLeafPreparationBatchLimit = min(
            max(
                workerSideLeafPreparationBatchLimit
                    ?? ScanConcurrencyPolicy.ordinaryLeafPreparationBatchLimit,
                1
            ),
            ScanConcurrencyPolicy.ordinaryLeafPreparationBatchLimit
        )
    }
    #endif

    init(
        enumeratedDirectoryContents: @escaping DirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15
    ) {
        self.init(
            enumeratedDirectoryContents: enumeratedDirectoryContents,
            volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
            usesBulkDirectoryEnumeration: false,
            atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
            atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval,
            directoryDescriptorPoolFactory: { ScanDirectoryDescriptorPool() },
            usesDeferredBulkEntryFiltering: false,
            usesWorkerSideLeafPreparation: true,
            workerSideLeafPreparationBatchLimit: nil
        )
    }

    private init(
        enumeratedDirectoryContents: @escaping DirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider,
        usesBulkDirectoryEnumeration: Bool,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver?,
        atomicSummaryProgressEmissionInterval: TimeInterval,
        directoryDescriptorPoolFactory: @escaping DirectoryDescriptorPoolFactory,
        usesDeferredBulkEntryFiltering: Bool,
        usesWorkerSideLeafPreparation: Bool,
        workerSideLeafPreparationBatchLimit: Int?
    ) {
        self.directoryContents = enumeratedDirectoryContents
        self.usesBulkDirectoryEnumeration = usesBulkDirectoryEnumeration
        self.usesDeferredBulkEntryFiltering = usesDeferredBulkEntryFiltering
        self.directoryNamespaceResolver = DirectoryNamespaceResolver()
        self.linkCountCapabilityCache = LinkCountCapabilityCache()
        self.atomicSummaryWorkerObserver = atomicSummaryWorkerObserver
        self.atomicSummaryProgressEmissionInterval = max(atomicSummaryProgressEmissionInterval, 0)
        #if DEBUG
        self.autoSummaryProfileReporter = nil
        #endif
        self.volumeFileSystemTypeProvider = volumeFileSystemTypeProvider
        self.directoryDescriptorPoolFactory = directoryDescriptorPoolFactory
        self.usesWorkerSideLeafPreparation = usesWorkerSideLeafPreparation
        self.workerSideLeafPreparationBatchLimit = min(
            max(
                workerSideLeafPreparationBatchLimit
                    ?? ScanConcurrencyPolicy.ordinaryLeafPreparationBatchLimit,
                1
            ),
            ScanConcurrencyPolicy.ordinaryLeafPreparationBatchLimit
        )
    }

    init(
        directoryContents: @escaping URLDirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver? = nil,
        atomicSummaryProgressEmissionInterval: TimeInterval = 0.15
    ) {
        self.init(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            let urls = try directoryContents(url, keys, options, cancellationCheck)
            return DirectoryEnumerationResult(urls: urls)
        }, volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
           atomicSummaryWorkerObserver: atomicSummaryWorkerObserver,
           atomicSummaryProgressEmissionInterval: atomicSummaryProgressEmissionInterval)
    }

    nonisolated static func defaultDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult {
        var rootEnumerationError: Error?
        var localizedFailures: [DirectoryEnumerationFailure] = []
        let rootPath = url.standardizedFileURL.path
        return try enumeratedDirectoryContents(
            url: url,
            keys: keys,
            options: options,
            cancellationCheck: cancellationCheck,
            makeEnumerator: { url, keys, options in
                FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: { failedURL, error in
                        if failedURL.standardizedFileURL.path == rootPath {
                            rootEnumerationError = error
                            return false
                        }
                        localizedFailures.append(
                            DirectoryEnumerationFailure(
                                url: failedURL,
                                error: error,
                                isDirectoryHint: true
                            )
                        )
                        return true
                    }
                )
            },
            enumerationError: { rootEnumerationError },
            localizedEnumerationFailures: { localizedFailures }
        )
    }

    nonisolated static func defaultVolumeFileSystemType(for url: URL) -> String? {
        var fileSystemStats = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystemStats)
        }
        guard result == 0 else { return nil }

        return withUnsafeBytes(of: fileSystemStats.f_fstypename) { rawBuffer -> String? in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    nonisolated static func defaultMountedFileSystems() -> [ScanMountedFileSystem] {
        var mountBuffer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo_r_np(&mountBuffer, MNT_NOWAIT)
        guard mountCount > 0, let mountBuffer else { return [] }
        defer { free(mountBuffer) }

        return (0..<Int(mountCount)).compactMap { offset in
            let entry = mountBuffer[offset]
            func cString<T>(from field: T) -> String {
                withUnsafeBytes(of: field) { rawBuffer -> String in
                    let buffer = rawBuffer.bindMemory(to: CChar.self)
                    guard let baseAddress = buffer.baseAddress else { return "" }
                    return String(cString: baseAddress)
                }
            }
            let mountPath = cString(from: entry.f_mntonname)
            guard !mountPath.isEmpty else { return nil }
            let fileSystemType = cString(from: entry.f_fstypename)
            let deviceID: UInt64?
            if fileSystemType == "apfs" {
                var mountStatus = stat()
                let statusResult = mountPath.withCString { path in
                    lstat(path, &mountStatus)
                }
                deviceID = statusResult == 0
                    ? UInt64(truncatingIfNeeded: mountStatus.st_dev)
                    : nil
            } else {
                deviceID = nil
            }
            return ScanMountedFileSystem(
                mountPath: mountPath,
                deviceName: cString(from: entry.f_mntfromname),
                fileSystemType: fileSystemType,
                deviceID: deviceID
            )
        }
    }

    nonisolated static func enumeratedDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void,
        makeEnumerator: (
            URL,
            [URLResourceKey]?,
            FileManager.DirectoryEnumerationOptions
        ) -> (any DirectoryObjectEnumerating)?,
        enumerationError: () -> Error? = { nil },
        localizedEnumerationFailures: () -> [DirectoryEnumerationFailure] = { [] }
    ) throws -> DirectoryEnumerationResult {
        try cancellationCheck()
        guard let enumerator = makeEnumerator(url, keys, options) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSURLErrorKey: url]
            )
        }

        var contents: [URL] = []
        while let nextObject = enumerator.nextObject() {
            try cancellationCheck()
            if let enumerationError = enumerationError() {
                throw enumerationError
            }
            guard let childURL = nextObject as? URL else { continue }
            contents.append(childURL)
        }

        if let enumerationError = enumerationError() {
            throw enumerationError
        }
        try cancellationCheck()
        return DirectoryEnumerationResult(
            urls: contents,
            localizedFailures: localizedEnumerationFailures()
        )
    }

    /// Thresholds for automatically summarizing directories with many small files.
    /// Directories exceeding BOTH thresholds are treated as atomic (not expanded).
    private enum AtomicDirectoryThresholds {
        /// Minimum file count to consider a directory for atomic treatment
        static let minFileCount = 5_000
        /// Maximum average file size (in bytes) to consider for atomic treatment
        /// Below this suggests files are tiny/cached/irrelevant (npm, caches, etc.)
        static let maxAverageFileSize: Int64 = 4_096  // 4 KB average
        /// Minimum depth at which atomic treatment applies
        /// (depth 0 = scan root, depth 1 = immediate children, etc.)
        static let minDepthForSummarization = 2
    }

    private enum ScanConcurrencyPolicy {
        static let directoryClassificationParallelThreshold = 128
        /// Caps additional prepared-node storage per leaf-preparation task.
        static let ordinaryLeafPreparationBatchLimit = 2_048

        /// Bounds metadata retained between a rejected auto-summary probe and normal traversal.
        static let autoSummaryProbeReuseEntryLimit = 65_536
        // Shared budget for concurrent child metadata reads across traversal and classification workers.
        static let directoryMetadataWorkerBudgetMaximum = 16

        static func atomicSummaryWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.atomicSummaryWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_ATOMIC_SUMMARY_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 4, processorDivisor: 1, maximum: 8)
        }

        static func directoryTraversalWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.directoryTraversalWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8)
        }

        static func directoryClassificationWorkerLimit(for options: ScanOptions) -> Int {
            if let optionLimit = options.directoryClassificationWorkerLimit {
                return max(1, optionLimit)
            }

            if let environmentLimit = ProcessInfo.processInfo.environment["RADIX_SCAN_DIRECTORY_CLASSIFICATION_WORKERS"]
                .flatMap(Int.init) {
                return max(1, environmentLimit)
            }

            return hardwareAwareWorkerLimit(minimum: 2, processorDivisor: 2, maximum: 8)
        }

        static func effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: Int,
            classificationWorkerLimit: Int
        ) -> Int {
            guard traversalWorkerLimit > 1 else {
                return classificationWorkerLimit
            }

            let sharedMetadataBudget = sharedMetadataWorkerBudget()
            let perDirectoryLimit = max(1, sharedMetadataBudget / max(1, traversalWorkerLimit))
            return min(classificationWorkerLimit, perDirectoryLimit)
        }

        private static func sharedMetadataWorkerBudget() -> Int {
            let processInfo = ProcessInfo.processInfo
            let activeProcessorCount = max(1, processInfo.activeProcessorCount)
            var limit = min(
                max(4, activeProcessorCount * 2),
                directoryMetadataWorkerBudgetMaximum
            )

            if processInfo.isLowPowerModeEnabled {
                limit = max(1, limit / 2)
            }

            switch processInfo.thermalState {
            case .serious, .critical:
                limit = max(1, limit / 2)
            case .fair:
                limit = max(1, limit - 2)
            case .nominal:
                break
            @unknown default:
                break
            }

            return limit
        }

        private static func hardwareAwareWorkerLimit(
            minimum: Int,
            processorDivisor: Int,
            maximum: Int
        ) -> Int {
            let processInfo = ProcessInfo.processInfo
            let activeProcessorCount = max(1, processInfo.activeProcessorCount)
            var limit = min(max(minimum, activeProcessorCount / max(1, processorDivisor)), maximum)

            if processInfo.isLowPowerModeEnabled {
                limit = max(1, limit / 2)
            }

            switch processInfo.thermalState {
            case .serious, .critical:
                limit = max(1, limit / 2)
            case .fair:
                limit = max(1, limit - 1)
            case .nominal:
                break
            @unknown default:
                break
            }

            return limit
        }
    }

    nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options, preservingBehaviorOf: target)
    }

    nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions,
        preservingBehaviorOf scanTarget: ScanTarget
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let snapshot = try await self.performScan(
                        target: target,
                        scanTarget: scanTarget,
                        options: options,
                        continuation: continuation
                    )
                    continuation.yield(.finished(snapshot))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    nonisolated func shallowDirectoryListing(
        at directoryURL: URL,
        scanTarget: ScanTarget,
        options: ScanOptions,
        classificationWorkerLimit: Int? = nil
    ) async throws -> ShallowDirectoryListing {
        let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }
        let metadataLoader = ScanMetadataLoader(
            linkCountCapabilityCache: linkCountCapabilityCache
        )
        let directoryMetadata = try metadataLoader.metadata(for: directoryURL)
        guard shouldTraverseDirectory(metadata: directoryMetadata, options: options) else {
            throw ScanEngineError.missingRootNode
        }
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: scanTarget.kind == .volume
                && scanTarget.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? scanTarget.url.path
        )
        let contents = try await Self.directoryEntries(
            of: directoryURL,
            includeHiddenFiles: options.includeHiddenFiles,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: ScanMetadataLoader.scanResourceKeys,
            metadataLoader: metadataLoader,
            directoryContents: directoryContents,
            usesBulkDirectoryEnumeration: usesBulkDirectoryEnumeration,
            usesDeferredBulkEntryFiltering: usesDeferredBulkEntryFiltering,
            directoryNamespaceResolver: directoryNamespaceResolver,
            directoryDescriptorPool: usesBulkDirectoryEnumeration
                ? directoryDescriptorPoolFactory()
                : nil,
            parentDirectoryLease: nil,
            nativeName: nil,
            expectedIdentity: directoryMetadata.fileIdentity,
            classificationWorkerLimit: classificationWorkerLimit
                ?? ScanConcurrencyPolicy.directoryClassificationWorkerLimit(for: options),
            cancellationCheck: cancellationCheck
        )
        contents.directoryLease?.close()
        return ShallowDirectoryListing(
            directoryMetadata: directoryMetadata,
            entries: contents.entries
        )
    }

    nonisolated static func shallowRelistWorkerLimit(for options: ScanOptions) -> Int {
        ScanConcurrencyPolicy.directoryTraversalWorkerLimit(for: options)
    }

    nonisolated static func shallowRelistClassificationWorkerLimit(
        for options: ScanOptions,
        relistWorkerLimit: Int
    ) -> Int {
        ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: relistWorkerLimit,
            classificationWorkerLimit: ScanConcurrencyPolicy.directoryClassificationWorkerLimit(
                for: options
            )
        )
    }

    nonisolated static func requiresDeepScanForAutoSummary(
        at directoryURL: URL,
        scanTarget: ScanTarget,
        options: ScanOptions
    ) -> Bool {
        guard options.autoSummarizeDirectories,
              let depth = relativeDepth(of: directoryURL, under: scanTarget.url) else {
            return false
        }
        let minimumDepth = options.autoSummarizeMinDepthForSummarization
            ?? AtomicDirectoryThresholds.minDepthForSummarization
        return canProbeForAutoSummary(
            depth: depth,
            minimumDepth: minimumDepth,
            isNodeDependencyLayout: AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(
                at: directoryURL
            )
        )
    }

    nonisolated static func subtreeScanOptions(
        _ options: ScanOptions,
        at subtreeURL: URL,
        scanTarget: ScanTarget
    ) -> ScanOptions {
        guard options.autoSummarizeDirectories,
              let depth = relativeDepth(of: subtreeURL, under: scanTarget.url) else {
            return options
        }
        var adjusted = options
        let minimumDepth = options.autoSummarizeMinDepthForSummarization
            ?? AtomicDirectoryThresholds.minDepthForSummarization
        adjusted.autoSummarizeMinDepthForSummarization = max(minimumDepth - depth, 0)
        if depth >= 1,
           AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: subtreeURL) {
            adjusted.autoSummarizeMinDepthForSummarization = 0
        }
        return adjusted
    }

    private nonisolated static func relativeDepth(
        of directoryURL: URL,
        under rootURL: URL
    ) -> Int? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents
        guard directoryComponents.count >= rootComponents.count,
              directoryComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            return nil
        }
        return directoryComponents.count - rootComponents.count
    }

    private nonisolated static func canProbeForAutoSummary(
        depth: Int,
        minimumDepth: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        depth >= minimumDepth
            || (depth >= 1 && isNodeDependencyLayout)
    }

    // The scan path (`performScan` and the helpers it calls) is `nonisolated` on
    // purpose. `ScanEngine`'s stored properties are all `let`, so the scan holds no
    // actor-mutable state and isolation bought us nothing but serialization on the
    // actor's executor — which let a previous, still-cancelling scan block a freshly
    // started one from running. Keeping these `nonisolated` is what allows overlapping
    // scans to make progress independently. Do not re-isolate without reintroducing
    // that bug (see testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling).
    private nonisolated func performScan(
        target: ScanTarget,
        scanTarget: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> ScanSnapshot {
        let startedAt = Date()
        #if DEBUG
        let diagnostics = ScanDiagnostics.makeIfEnabled()
        let processCPUTimeAtStart = diagnostics?.processCPUTime()
        #else
        let diagnostics: ScanDiagnosticsContext? = nil
        #endif
        var metrics = ScanMetrics()
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: scanTarget.kind == .volume
                && scanTarget.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path
        )

        let treeStore = try await scanDirectory(
            target: target,
            includeVolumeDetails: true,
            options: options,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            emissionState: &emissionState,
            diagnostics: diagnostics
        )
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        continuation.yield(.progress(metrics))

        #if DEBUG
        let snapshotFinalizationStart = diagnostics?.start()
        #endif

        if let overlappingBytes = VolumeCapacityAccounting.overlappingAllocatedBytes(
            in: treeStore,
            capacity: metrics.volumeCapacity
        ) {
            let warning = ScanWarning(
                path: target.url.path,
                message: "File allocations overlap by \(overlappingBytes) bytes; APFS clones or files changed during the scan may share physical storage.",
                category: .fileSystem
            )
            warnings.append(warning)
            continuation.yield(.warning(warning))
        }

        let snapshot = makeSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true,
            scanOptions: options,
            volumeCapacity: metrics.volumeCapacity,
            reconcilesVolumeCapacity: metrics.estimatedTotalBytes > 0,
            hasActiveExclusions: !exclusionMatcher.isEmpty
        )
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize.snapshot",
            url: target.url,
            startedAt: snapshotFinalizationStart,
            itemCount: treeStore.nodeCount
        )
        #endif

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        #if DEBUG
        if let diagnostics {
            print(diagnostics.makeReport(
                targetPath: target.url.path,
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                processCPUTimeAtStart: processCPUTimeAtStart
            ))
        }
        #endif
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

    /// Scans a directory iteratively (no recursion) and returns a fully assembled flat tree.
    private nonisolated func scanDirectory(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        diagnostics: ScanDiagnosticsContext?
    ) async throws -> FileTreeStore {
        try Task.checkCancellation()
        let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }
        let scanMetadataLoader = ScanMetadataLoader(
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache
        )
        let rootMetadata = try scanMetadataLoader.metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        guard !rootMetadata.isDataless else {
            throw ScanEngineError.cloudOnlyRoot
        }
        let volumeBoundaryPolicy = ScanVolumeBoundaryPolicy.resolve(
            rootPath: target.url.standardizedFileURL.path,
            rootDeviceID: rootMetadata.fileIdentity?.fileSystemDeviceID,
            mountedFileSystems: Self.defaultMountedFileSystems()
        )
        metrics.discoveredItems = 1
        metrics.volumeCapacity = target.kind == .volume ? rootMetadata.volumeCapacity : nil
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()
        var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
        var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
        let atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        let atomicSummaryPool = AtomicDirectorySummaryPool(
            workerLimit: atomicSummaryWorkerLimit,
            workerObserver: atomicSummaryWorkerObserver,
            progressEmissionInterval: atomicSummaryProgressEmissionInterval
        )
        atomicSummaryPool.start()
        #if DEBUG
        let scanAtomicDirectorySummarizer = AtomicDirectorySummarizer(
            metadataLoader: scanMetadataLoader,
            diagnostics: diagnostics,
            summaryPool: atomicSummaryPool,
            volumeBoundaryPolicy: volumeBoundaryPolicy,
            profileReporter: autoSummaryProfileReporter
        )
        #else
        let scanAtomicDirectorySummarizer = AtomicDirectorySummarizer(
            metadataLoader: scanMetadataLoader,
            diagnostics: diagnostics,
            summaryPool: atomicSummaryPool,
            volumeBoundaryPolicy: volumeBoundaryPolicy
        )
        #endif
        let directoryTraversalWorkerLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(for: options)
        let directoryClassificationWorkerLimit = ScanConcurrencyPolicy.directoryClassificationWorkerLimit(for: options)
        let effectiveDirectoryClassificationWorkerLimit = ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: directoryTraversalWorkerLimit,
            classificationWorkerLimit: directoryClassificationWorkerLimit
        )
        let directoryContentsProvider = directoryContents
        let usesBulkDirectoryEnumeration = usesBulkDirectoryEnumeration
        let usesDeferredBulkEntryFiltering = usesDeferredBulkEntryFiltering
        let directoryNamespaceResolver = directoryNamespaceResolver
        let directoryDescriptorPool = usesBulkDirectoryEnumeration
            ? directoryDescriptorPoolFactory()
            : nil
        let directoryResourceKeys = ScanMetadataLoader.scanResourceKeys

        do {
        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, options: options) else {
            let summarizesRootPackage = rootMetadata.isPackage
                && rootMetadata.isDirectory
                && !options.treatPackagesAsDirectories
            if summarizesRootPackage {
                metrics.pendingPackageSummaryCount += 1
                metrics.recalculateProgress()
                atomicSummaryPool.updateProgress(
                    metrics,
                    continuation: continuation
                )
            }
            let leafResult = try await makeLeafNode(
                url: target.url,
                metadata: rootMetadata,
                options: options,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                progressWeight: 1,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation
            )
            if summarizesRootPackage {
                metrics.pendingPackageSummaryCount = max(
                    metrics.pendingPackageSummaryCount - 1,
                    0
                )
            }
            sharedAllocationAccumulator.merge(leafResult.sharedAllocationAccumulator)
            if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
            }
            applyLeafMetrics(
                leafResult.node,
                weight: 1,
                summaryVisitedItemCount: leafResult.summaryVisitedItemCount,
                metrics: &metrics
            )
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            metrics.recalculateProgress()
            atomicSummaryPool.updateProgress(
                metrics,
                continuation: continuation,
                force: true
            )
            let rawStore = FileTreeStore(root: leafResult.node)
            let store = SharedAllocationDeduplicator.deduplicatedStore(
                rootID: leafResult.node.id,
                nodesByID: [leafResult.node.id: leafResult.node],
                childIDsByID: [:],
                parentIDByID: [:],
                aggregateStats: rawStore.aggregateStats,
                sharedAllocationAccumulator: sharedAllocationAccumulator,
                minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
            )
            await atomicSummaryPool.finish()
            return store
        }

        // Phase 1: Walk the tree iteratively, collecting completed nodes by key.
        // We use a stack for DFS. Each item knows its parent key and depth for assembly.
        metrics.discoveredDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(
                url: target.url,
                metadata: rootMetadata,
                localizedEnumerationError: nil,
                isDirectoryHint: nil,
                parentKey: -1,
                depth: 0,
                weight: 1
            )
        ]
        // Maps a key to its completed result (leaf or assembled directory).
        var completedByKey: [CompletedDirScan?] = []
        // Maps parent key → child keys, built during phase 1.
        var childrenKeysByKey: [[Int]?] = []
        // Retain the scan key assigned to each accepted path. Besides rejecting
        // duplicate discoveries, this becomes the compact store's node index
        // without hashing every path again during finalization.
        var scanKeyByNodeID: [String: Int] = [:]
        var nextKey = 0

        #if DEBUG
        let traversalStart = diagnostics?.start()
        diagnostics?.recordPeak("work_stack.items", value: workStack.count)
        #endif
        try await withThrowingTaskGroup(of: ScanTaskResult.self) { group in
            var activeDirectoryTasks = 0
            var activePackageTasks = 0
            var activeOrdinaryLeafTasks = 0
            let packageSummaryRequestLimit = max(1, atomicSummaryWorkerLimit * 2)
            let ordinaryLeafPreparationWorkerLimit = max(1, directoryTraversalWorkerLimit)
            // Packages and atomic-summary candidates waiting for a summary-request slot.
            // They must not be summarized inline in the scheduling loop: awaiting a pool
            // job there stops the group from being drained, freezing progress bookkeeping
            // until the stack unwinds.
            var pendingPackageScans: [(item: ScanWorkItem, itemKey: Int, metadata: NodeMetadata)] = []
            var pendingAtomicScans: [AtomicDirectoryScanCandidate] = []
            var pendingOrdinaryLeafRequests: [OrdinaryLeafPreparationRequest] = []
            var reusableProbeListings: [String: AtomicDirectoryProbeListing] = [:]
            var reusableProbeListingCost = 0
            let autoSummarizeMinFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
            let autoSummarizeMaxAverageFileSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
            let autoSummarizeMinDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization

            while true {
                while activeDirectoryTasks < directoryTraversalWorkerLimit,
                      let item = workStack.popLast() {
                    try Task.checkCancellation()

                    let itemPath = item.url.path
                    if let previousKey = scanKeyByNodeID.updateValue(nextKey, forKey: itemPath) {
                        scanKeyByNodeID[itemPath] = previousKey
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        recordDuplicateNode(
                            at: item.url,
                            weight: item.weight,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool
                        )
                        continue
                    }

                    let preloadedListing = reusableProbeListings.removeValue(forKey: item.url.path)
                    if let preloadedListing {
                        reusableProbeListingCost -= max(1, preloadedListing.entries.count)
                    }

                    let itemKey = nextKey
                    nextKey += 1
                    completedByKey.append(nil)
                    childrenKeysByKey.append(nil)

                    // Register this child with its parent (skip root which has parentKey -1).
                    if item.parentKey >= 0 {
                        if childrenKeysByKey[item.parentKey] == nil {
                            childrenKeysByKey[item.parentKey] = []
                        }
                        childrenKeysByKey[item.parentKey]!.append(itemKey)
                    }

                    let meta: NodeMetadata
                    if let localizedEnumerationError = item.localizedEnumerationError {
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        recordUnavailableItem(
                            item,
                            itemKey: itemKey,
                            error: localizedEnumerationError,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool,
                            completedByKey: &completedByKey
                        )
                        continue
                    } else if let itemMetadata = item.metadata {
                        meta = itemMetadata
                    } else {
                        do {
                            meta = try scanMetadataLoader.metadata(for: item.url)
                        } catch {
                            releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                            recordUnavailableItem(
                                item,
                                itemKey: itemKey,
                                error: error,
                                metrics: &metrics,
                                warnings: &warnings,
                                continuation: continuation,
                                emissionState: &emissionState,
                                summaryPool: atomicSummaryPool,
                                completedByKey: &completedByKey
                            )
                            continue
                        }
                    }
                    metrics.currentPath = item.url.path

                    let traversesDirectory = shouldTraverseDirectory(
                        metadata: meta,
                        options: options
                    )
                    let summarizesPackage = meta.isPackage
                        && meta.isDirectory
                        && !options.treatPackagesAsDirectories
                    let boundaryError = traversesDirectory || summarizesPackage
                        ? volumeBoundaryPolicy.descentBoundaryError(
                            for: item.url,
                            childDeviceID: meta.fileIdentity?.fileSystemDeviceID
                        )
                        : nil

                    if traversesDirectory, boundaryError == nil {
                        metrics.directoriesVisited += 1
                        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

                        let taskItem = item
                        let taskItemKey = itemKey
                        let taskMetadata = meta
                        activeDirectoryTasks += 1
                        group.addTask {
                            #if DEBUG
                            let traversalStart = DispatchTime.now().uptimeNanoseconds
                            #endif
                            do {
                                let contents = try await ScanEngine.directoryEntries(
                                    of: taskItem.url,
                                    includeHiddenFiles: options.includeHiddenFiles,
                                    behavior: behavior,
                                    exclusionMatcher: exclusionMatcher,
                                    resourceKeys: directoryResourceKeys,
                                    metadataLoader: scanMetadataLoader,
                                    directoryContents: directoryContentsProvider,
                                    usesBulkDirectoryEnumeration: usesBulkDirectoryEnumeration,
                                    usesDeferredBulkEntryFiltering: usesDeferredBulkEntryFiltering,
                                    directoryNamespaceResolver: directoryNamespaceResolver,
                                    directoryDescriptorPool: directoryDescriptorPool,
                                    parentDirectoryLease: taskItem.parentDirectoryLease,
                                    nativeName: taskItem.nativeName,
                                    expectedIdentity: Self.verifiesDirectoryIdentity(
                                        at: taskItem.url,
                                        behavior: behavior
                                    ) ? taskMetadata.fileIdentity : nil,
                                    classificationWorkerLimit: effectiveDirectoryClassificationWorkerLimit,
                                    preloadedListing: preloadedListing,
                                    cancellationCheck: cancellationCheck
                                )
                                #if DEBUG
                                if contents.reusedProbeListing {
                                    scanAtomicDirectorySummarizer.profileReporter?(
                                        .reusedDirectoryListing(entryCount: contents.entries.count)
                                    )
                                }
                                #endif
                                var childDirectoryCount = 0
                                var totalWeightUnits = 0.0
                                for (offset, childEntry) in contents.entries.enumerated() {
                                    if offset.isMultiple(of: 256) {
                                        try cancellationCheck()
                                    }
                                    if Self.isLikelyTraversableDirectory(entry: childEntry) {
                                        childDirectoryCount += 1
                                        totalWeightUnits += Self.directoryChildWeightUnits
                                    } else {
                                        totalWeightUnits += 1
                                    }
                                }
                                let isNodeDependencyLayout = AtomicDirectorySummarizer
                                    .isNodeDependencyLayoutDirectory(at: taskItem.url)
                                let canProbeForAutoSummary = Self.canProbeForAutoSummary(
                                    depth: taskItem.depth,
                                    minimumDepth: autoSummarizeMinDepth,
                                    isNodeDependencyLayout: isNodeDependencyLayout
                                )
                                let isAtomicSummaryCandidate: Bool
                                if options.autoSummarizeDirectories, canProbeForAutoSummary {
                                    isAtomicSummaryCandidate = try scanAtomicDirectorySummarizer.isAtomicSummaryCandidate(
                                        url: taskItem.url,
                                        childEntries: contents.entries,
                                        isNodeDependencyLayout: isNodeDependencyLayout,
                                        minFileCount: autoSummarizeMinFileCount,
                                        maxAverageFileSize: autoSummarizeMaxAverageFileSize,
                                        allowsDescendantProbe: !taskItem.skipsDescendantAutoSummaryProbe,
                                        cancellationCheck: cancellationCheck
                                    )
                                } else {
                                    isAtomicSummaryCandidate = false
                                }
                                return .directory(.success(DirectoryTraversalSuccess(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents,
                                    childDirectoryCount: childDirectoryCount,
                                    totalWeightUnits: totalWeightUnits,
                                    isNodeDependencyLayout: isNodeDependencyLayout,
                                    isAtomicSummaryCandidate: isAtomicSummaryCandidate
                                )))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                #if DEBUG
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
                                )))
                                #else
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error)
                                )))
                                #endif
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory). Discovery may
                        // have classified it as a pending directory; release that claim.
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        if let boundaryError {
                            let warning = ScanWarningFactory.makeWarning(
                                for: item.url,
                                error: boundaryError
                            )
                            warnings.append(warning)
                            continuation.yield(.warning(warning))
                        } else if summarizesPackage {
                            metrics.pendingPackageSummaryCount += 1
                            metrics.recalculateProgress()
                            atomicSummaryPool.updateProgress(
                                metrics,
                                continuation: continuation
                            )
                            pendingPackageScans.append((item: item, itemKey: itemKey, metadata: meta))
                            continue
                        }
                        let leafResult = try await makeLeafNode(
                            url: item.url,
                            metadata: meta,
                            options: options,
                            behavior: behavior,
                            exclusionMatcher: exclusionMatcher,
                            atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                            summarizesPackageContents: boundaryError == nil,
                            progressWeight: item.weight,
                            cancellationCheck: cancellationCheck,
                            metrics: &metrics,
                            continuation: continuation
                        )
                        sharedAllocationAccumulator.merge(leafResult.sharedAllocationAccumulator)
                        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
                        }
                        applyLeafMetrics(
                            leafResult.node,
                            weight: item.weight,
                            summaryVisitedItemCount: leafResult.summaryVisitedItemCount,
                            metrics: &metrics
                        )
                        if !leafResult.warnings.isEmpty {
                            warnings.append(contentsOf: leafResult.warnings)
                            for warning in leafResult.warnings {
                                continuation.yield(.warning(warning))
                            }
                        }
                        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

                        completedByKey[itemKey] = .leaf(leafResult.node)
                    }
                }

                while activePackageTasks < packageSummaryRequestLimit,
                      let pendingPackage = pendingPackageScans.popLast() {
                    let taskItem = pendingPackage.item
                    let taskItemKey = pendingPackage.itemKey
                    let taskMetadata = pendingPackage.metadata
                    let taskMetrics = metrics
                    activePackageTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        let leaf = try await self.makeLeafNode(
                            url: taskItem.url,
                            metadata: taskMetadata,
                            options: options,
                            behavior: behavior,
                            exclusionMatcher: exclusionMatcher,
                            atomicDirectorySummarizer: scanAtomicDirectorySummarizer,
                            progressWeight: taskItem.weight,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation
                        )
                        return .package(PackageSummaryResult(
                            itemKey: taskItemKey,
                            weight: taskItem.weight,
                            leaf: leaf
                        ))
                    }
                }

                while activePackageTasks < packageSummaryRequestLimit,
                      let candidate = pendingAtomicScans.popLast() {
                    let taskMetrics = metrics
                    let taskEmissionState = emissionState
                    activePackageTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        var localEmissionState = taskEmissionState
                        let decision = try await scanAtomicDirectorySummarizer.summaryDecisionIfNeeded(
                            url: candidate.item.url,
                            childEntries: candidate.contents.entries,
                            metadata: candidate.metadata,
                            expectedRootIdentity: Self.verifiesDirectoryIdentity(
                                at: candidate.item.url,
                                behavior: behavior
                            ) ? candidate.metadata.fileIdentity : nil,
                            includeHiddenFiles: options.includeHiddenFiles,
                            treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                            isNodeDependencyLayout: candidate.isNodeDependencyLayout,
                            minFileCount: autoSummarizeMinFileCount,
                            maxAverageFileSize: autoSummarizeMaxAverageFileSize,
                            progressWeight: candidate.item.weight,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation,
                            emissionState: &localEmissionState
                        )
                        return .atomicDirectory(AtomicDirectoryScanResult(
                            candidate: candidate,
                            decision: decision
                        ))
                    }
                }

                while activeOrdinaryLeafTasks < ordinaryLeafPreparationWorkerLimit,
                      let request = pendingOrdinaryLeafRequests.popLast() {
                    activeOrdinaryLeafTasks += 1
                    group.addTask {
                        .ordinaryLeaves(try self.prepareOrdinaryLeaves(
                            request,
                            cancellationCheck: cancellationCheck
                        ))
                    }
                }

                guard activeDirectoryTasks + activePackageTasks + activeOrdinaryLeafTasks > 0 else {
                    break
                }
                guard let traversalResult = try await group.next() else { break }
                // Set when a drained result yields an enumerated directory whose children
                // should be expanded normally; handled once after the switch.
                var directoryToExpand: AtomicDirectoryScanCandidate?
                var probeFullyExhaustedForExpansion = false

                switch traversalResult {
                case .directory(.success(let success)):
                    activeDirectoryTasks -= 1
                    let item = success.item
                    let itemKey = success.itemKey
                    let meta = success.metadata
                    let contents = success.contents
                    let childEntries = contents.entries
                    #if DEBUG
                    diagnostics?.recordElapsed(
                        operation: "directory.enumerate",
                        url: item.url,
                        nanoseconds: contents.enumerationNanoseconds,
                        itemCount: contents.enumeratedItemCount
                    )
                    diagnostics?.recordElapsed(
                        operation: "directory.classify_children",
                        url: item.url,
                        nanoseconds: contents.classificationNanoseconds,
                        itemCount: contents.enumeratedItemCount,
                        detail: "kept=\(childEntries.count)"
                    )
                    #endif

                    metrics.currentPath = item.url.path
                    metrics.discoveredItems += childEntries.count
                    metrics.enumeratedDirectoryCount += 1
                    releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                    let childDirectoryCount = success.childDirectoryCount
                    let totalWeightUnits = success.totalWeightUnits
                    metrics.discoveredDirectoryCount += childDirectoryCount
                    metrics.pendingDirectoryCount += childDirectoryCount
                    // Check if this directory should be summarized as atomic (many small files)
                    let candidate = AtomicDirectoryScanCandidate(
                        item: item,
                        itemKey: itemKey,
                        metadata: meta,
                        contents: contents,
                        childDirectoryCount: childDirectoryCount,
                        totalWeightUnits: totalWeightUnits,
                        isNodeDependencyLayout: success.isNodeDependencyLayout
                    )
                    if success.isAtomicSummaryCandidate {
                        metrics.pendingAutoSummaryRepresentedItemCount = ScanIntegerMath.addingClamped(
                            metrics.pendingAutoSummaryRepresentedItemCount,
                            childEntries.count
                        )
                        metrics.pendingAutoSummaryRepresentedDirectoryCount = ScanIntegerMath.addingClamped(
                            metrics.pendingAutoSummaryRepresentedDirectoryCount,
                            childDirectoryCount
                        )
                        // The probe/summary awaits a pooled job; run it as a group task
                        // so the scheduling loop keeps draining results while it works.
                        pendingAtomicScans.append(candidate)
                    } else {
                        directoryToExpand = candidate
                    }
                    // Refresh the summary pool's canonical base unconditionally. It emits
                    // worker progress independently and must not retain the frontier state
                    // from before this enumeration.
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(metrics, continuation: continuation)

                case .directory(.failure(let failure)):
                    activeDirectoryTasks -= 1
                    #if DEBUG
                    diagnostics?.recordElapsed(
                        operation: "directory.enumerate.error",
                        url: failure.item.url,
                        nanoseconds: failure.elapsedNanoseconds,
                        detail: failure.diagnosticDetail
                    )
                    #endif
                    let item = failure.item
                    let itemKey = failure.itemKey
                    let meta = failure.metadata
                    let warning = failure.warning
                    warnings.append(warning)
                    continuation.yield(.warning(warning))
                    metrics.completedItems += 1
                    metrics.completedTraversalWeight += item.weight
                    metrics.enumeratedDirectoryCount += 1
                    releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(metrics, continuation: continuation)

                    let inaccessibleNode = FileNodeRecord(
                        id: item.url.path,
                        url: item.url,
                        name: ScanTarget.displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: meta.isSymbolicLink,
                        allocatedSize: 0,
                        logicalSize: 0,
                        descendantFileCount: 0,
                        lastModified: meta.lastModified,
                        fileIdentity: meta.fileIdentity,
                        linkCount: meta.linkCount,
                        isPackage: meta.isPackage,
                        isAccessible: false,
                        isSelfAccessible: false,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                    completedByKey[itemKey] = .leaf(inaccessibleNode)
                case .package(let packageResult):
                    activePackageTasks -= 1
                    let leafResult = packageResult.leaf
                    metrics.pendingPackageSummaryCount = max(
                        metrics.pendingPackageSummaryCount - 1,
                        0
                    )
                    sharedAllocationAccumulator.merge(leafResult.sharedAllocationAccumulator)
                    if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                        minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
                    }
                    applyLeafMetrics(
                        leafResult.node,
                        weight: packageResult.weight,
                        summaryVisitedItemCount: leafResult.summaryVisitedItemCount,
                        metrics: &metrics
                    )
                    if !leafResult.warnings.isEmpty {
                        warnings.append(contentsOf: leafResult.warnings)
                        for warning in leafResult.warnings {
                            continuation.yield(.warning(warning))
                        }
                    }
                    // Committed summary weight must reach the pool's base metrics even
                    // when `maybeEmitProgress`'s item-count gate would skip the update.
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(metrics, continuation: continuation)
                    completedByKey[packageResult.itemKey] = .leaf(leafResult.node)

                case .atomicDirectory(let atomicResult):
                    activePackageTasks -= 1
                    let candidate = atomicResult.candidate
                    guard let summary = atomicResult.decision.summary else {
                        metrics.pendingAutoSummaryRepresentedItemCount = max(
                            metrics.pendingAutoSummaryRepresentedItemCount
                                - candidate.contents.entries.count,
                            0
                        )
                        metrics.pendingAutoSummaryRepresentedDirectoryCount = max(
                            metrics.pendingAutoSummaryRepresentedDirectoryCount
                                - candidate.childDirectoryCount,
                            0
                        )
                        for (path, listing) in atomicResult.decision.reusableDirectoryListings {
                            guard reusableProbeListings[path] == nil else { continue }
                            let listingCost = max(1, listing.entries.count)
                            guard reusableProbeListingCost + listingCost
                                <= ScanConcurrencyPolicy.autoSummaryProbeReuseEntryLimit else {
                                continue
                            }
                            reusableProbeListings[path] = listing
                            reusableProbeListingCost += listingCost
                        }
                        // Probe declined: expand the directory normally.
                        directoryToExpand = candidate
                        probeFullyExhaustedForExpansion = atomicResult.decision
                            .descendantProbeFullyExhausted
                        metrics.recalculateProgress()
                        atomicSummaryPool.updateProgress(metrics, continuation: continuation)
                        break
                    }
                    let item = candidate.item
                    let meta = candidate.metadata
                    // Treat as atomic: create a leaf node with summary stats.
                    let atomicNode = FileNodeRecord(
                        id: item.url.path,
                        url: item.url,
                        name: ScanTarget.displayName(for: item.url),
                        isDirectory: true,
                        isSymbolicLink: false,
                        allocatedSize: max(meta.allocatedSize, summary.allocatedSize),
                        logicalSize: max(meta.logicalSize, summary.logicalSize),
                        descendantFileCount: summary.descendantFileCount,
                        lastModified: meta.lastModified,
                        fileIdentity: meta.fileIdentity,
                        linkCount: meta.linkCount,
                        isPackage: false,
                        isAccessible: summary.isAccessible,
                        isSelfAccessible: meta.isReadable,
                        isSynthetic: false,
                        isAutoSummarized: true
                    )
                    sharedAllocationAccumulator.merge(summary.sharedAllocationAccumulator)
                    minimumAllocatedSizeByNodeID[atomicNode.id] = meta.allocatedSize
                    // The summarized children will never be enqueued: count them as
                    // completed and release their frontier claims.
                    metrics.pendingAutoSummaryRepresentedItemCount = max(
                        metrics.pendingAutoSummaryRepresentedItemCount
                            - candidate.contents.entries.count,
                        0
                    )
                    metrics.pendingAutoSummaryRepresentedDirectoryCount = max(
                        metrics.pendingAutoSummaryRepresentedDirectoryCount
                            - candidate.childDirectoryCount,
                        0
                    )
                    metrics.completedItems += candidate.contents.entries.count
                    metrics.discoveredDirectoryCount = max(
                        metrics.discoveredDirectoryCount - candidate.childDirectoryCount,
                        0
                    )
                    metrics.pendingDirectoryCount = max(
                        metrics.pendingDirectoryCount - candidate.childDirectoryCount,
                        0
                    )
                    applyLeafMetrics(
                        atomicNode,
                        weight: item.weight,
                        summaryVisitedItemCount: summary.visitedItemCount,
                        summaryRepresentedItemCount: candidate.contents.entries.count,
                        metrics: &metrics
                    )
                    if !summary.warnings.isEmpty {
                        warnings.append(contentsOf: summary.warnings)
                        for warning in summary.warnings {
                            continuation.yield(.warning(warning))
                        }
                    }
                    // Committed summary weight must reach the pool's base metrics even
                    // when `maybeEmitProgress`'s item-count gate would skip the update.
                    metrics.recalculateProgress()
                    atomicSummaryPool.updateProgress(metrics, continuation: continuation)

                    completedByKey[candidate.itemKey] = .leaf(atomicNode)
                case .ordinaryLeaves(let batch):
                    activeOrdinaryLeafTasks -= 1
                    for item in batch.items {
                        recordPreparedOrdinaryLeaf(
                            item,
                            parentKey: batch.parentKey,
                            nextKey: &nextKey,
                            scanKeyByNodeID: &scanKeyByNodeID,
                            sharedAllocationAccumulator: &sharedAllocationAccumulator,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool,
                            completedByKey: &completedByKey,
                            childrenKeysByKey: &childrenKeysByKey
                        )
                    }
                }

                guard let expansion = directoryToExpand else { continue }
                let candidate = expansion
                let item = candidate.item
                let itemKey = candidate.itemKey
                let contents = candidate.contents
                let childEntries = contents.entries
                let totalWeightUnits = candidate.totalWeightUnits

                if childEntries.isEmpty {
                    // Nothing below this directory: its whole weight is done.
                    metrics.completedTraversalWeight += item.weight
                }

                // Enqueue children onto the stack. Each child records its parent key.
                var lastQueuedLeafChunkStart: Int?
                for (offset, childEntry) in childEntries.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }

                    // Bulk discovery has already fully classified ordinary files
                    // and symlinks. Prepare them in bounded worker batches instead of
                    // allocating work-stack items or serializing wide suffixes here.
                    if let childMetadata = childEntry.metadata,
                       !childMetadata.isDirectory || childMetadata.isSymbolicLink {
                        if usesWorkerSideLeafPreparation {
                            let batchLimit = workerSideLeafPreparationBatchLimit
                            let chunkStart = (offset / batchLimit) * batchLimit
                            if lastQueuedLeafChunkStart != chunkStart {
                                pendingOrdinaryLeafRequests.append(
                                    OrdinaryLeafPreparationRequest(
                                        entries: childEntries,
                                        range: chunkStart..<min(chunkStart + batchLimit, childEntries.count),
                                        parentKey: itemKey,
                                        parentWeight: item.weight,
                                        totalWeightUnits: totalWeightUnits
                                    )
                                )
                                lastQueuedLeafChunkStart = chunkStart
                            }
                            continue
                        }

                        let childNode = makeFileNode(
                            url: childEntry.url,
                            metadata: childMetadata
                        )
                        let preparedItem = PreparedOrdinaryLeafItem(
                            weight: item.weight / totalWeightUnits,
                            node: childNode,
                            sharedAllocationClaim: SharedAllocationDeduplicator.claim(
                                for: childMetadata,
                                ownerNodeID: childNode.id,
                                path: childNode.id
                            )
                        )
                        recordPreparedOrdinaryLeaf(
                            preparedItem,
                            parentKey: itemKey,
                            nextKey: &nextKey,
                            scanKeyByNodeID: &scanKeyByNodeID,
                            sharedAllocationAccumulator: &sharedAllocationAccumulator,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState,
                            summaryPool: atomicSummaryPool,
                            completedByKey: &completedByKey,
                            childrenKeysByKey: &childrenKeysByKey
                        )
                        continue
                    }

                    let childWeight = item.weight
                        * Self.traversalWeightUnits(for: childEntry)
                        / totalWeightUnits
                    workStack.append(
                        ScanWorkItem(
                            url: childEntry.url,
                            metadata: childEntry.metadata,
                            localizedEnumerationError: childEntry.localizedEnumerationError,
                            isDirectoryHint: childEntry.isDirectoryHint,
                            parentKey: itemKey,
                            depth: item.depth + 1,
                            weight: childWeight,
                            parentDirectoryLease: contents.directoryLease,
                            nativeName: childEntry.nativeName,
                            skipsDescendantAutoSummaryProbe: item.skipsDescendantAutoSummaryProbe
                                || probeFullyExhaustedForExpansion
                        )
                    )
                }
                #if DEBUG
                if let diagnostics {
                    // Only enqueueing can increase pending ownership. Active tasks
                    // and results waiting in the task group are outside these counts.
                    var queuedSlots = 0
                    var retainedEntries = 0
                    var retainedParents: Set<Int> = []
                    for request in pendingOrdinaryLeafRequests {
                        queuedSlots += request.range.count
                        // Every request for one parent shares the same listing array.
                        if retainedParents.insert(request.parentKey).inserted {
                            retainedEntries += request.entries.count
                        }
                    }
                    diagnostics.recordPeak("leaf_queue.requests", value: pendingOrdinaryLeafRequests.count)
                    diagnostics.recordPeak("leaf_queue.slots", value: queuedSlots)
                    diagnostics.recordPeak("leaf_queue.retained_entries", value: retainedEntries)
                    diagnostics.recordPeak("leaf_queue.listings", value: retainedParents.count)
                    diagnostics.recordPeak("directory_listing.entries", value: childEntries.count)
                    diagnostics.recordPeak("work_stack.items", value: workStack.count)
                }
                #endif
                // Register this directory so phase 2 can assemble it.
                completedByKey[itemKey] = .traversableDirectory(
                    metadata: candidate.metadata,
                    url: item.url
                )
            }
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.traverse",
            url: target.url,
            startedAt: traversalStart,
            itemCount: nextKey
        )
        #endif

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        atomicSummaryPool.updateProgress(
            metrics,
            continuation: continuation,
            force: true
        )

        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif
        let finalizationTotal = max(completedByKey.count, 1)
        // Cap stream traffic to roughly 200 assembly updates on very large scans.
        let finalizationProgressInterval = max(512, finalizationTotal / 200)
        var finalizedItems = 0
        #if DEBUG
        let correctionResolutionStart = diagnostics?.start()
        #endif
        let duplicateAllocatedSizeByOwner = try sharedAllocationAccumulator.duplicateAllocatedSizeByOwner {
            try Task.checkCancellation()
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize.resolve_corrections",
            url: target.url,
            startedAt: correctionResolutionStart,
            itemCount: duplicateAllocatedSizeByOwner.count
        )
        #endif
        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(nextKey)
        var parentRawIndices: [UInt32] = []
        parentRawIndices.reserveCapacity(nextKey)
        var childSpans: [FileTreeChildSpan] = []
        childSpans.reserveCapacity(nextKey)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(max(nextKey - 1, 0))
        var aggregateStats = AggregateStatsAccumulator()
        #if DEBUG
        let assemblyStart = diagnostics?.start()
        #endif
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let completed = completedByKey[key] else {
                assertionFailure("Missing completed scan result for key \(key).")
                throw ScanEngineError.missingRootNode
            }
            completedByKey[key] = nil
            finalizedItems += 1
            let nodeOffset = nodes.count
            assert(nodeOffset == nextKey - key - 1)

            switch completed {
            case .traversableDirectory(let metadata, let url):
                // Traversable directories must still be materialized when empty.
                var sortedChildKeys = childrenKeysByKey[key] ?? []
                childrenKeysByKey[key] = nil
                // Duplicate paths are rejected before keys are assigned in phase 1,
                // so children are already unique here.
                sortedChildKeys.sort { lhsKey, rhsKey in
                    let lhs = nodes[nextKey - lhsKey - 1]
                    let rhs = nodes[nextKey - rhsKey - 1]
                    if lhs.allocatedSize == rhs.allocatedSize {
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.allocatedSize > rhs.allocatedSize
                }
                try Task.checkCancellation()
                let directoryID = url.path
                var allocatedSize: Int64 = 0
                var logicalSize: Int64 = 0
                var descendantFileCount = 0
                var childrenAreAccessible = true
                let childSpanStart = childIndices.count
                for (offset, childKey) in sortedChildKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    let childOffset = nextKey - childKey - 1
                    let child = nodes[childOffset]
                    allocatedSize = ScanIntegerMath.addingClamped(allocatedSize, child.allocatedSize)
                    logicalSize = ScanIntegerMath.addingClamped(logicalSize, child.logicalSize)
                    childrenAreAccessible = childrenAreAccessible && child.isAccessible
                    if child.isDirectory {
                        descendantFileCount = ScanIntegerMath.addingClamped(
                            descendantFileCount,
                            child.descendantFileCount
                        )
                    } else if !child.isSymbolicLink && !child.isSynthetic {
                        descendantFileCount = ScanIntegerMath.addingClamped(descendantFileCount, 1)
                    }
                    let childIndex = FileTreeNodeIndex(rawValue: UInt32(childOffset))
                    childIndices.append(childIndex)
                    parentRawIndices[childOffset] = UInt32(nodeOffset)
                }

                let assembled = FileNodeRecord(
                    id: directoryID,
                    url: url,
                    name: ScanTarget.displayName(for: url),
                    isDirectory: true,
                    isSymbolicLink: false,
                    allocatedSize: allocatedSize,
                    logicalSize: logicalSize,
                    descendantFileCount: descendantFileCount,
                    lastModified: metadata.lastModified,
                    fileIdentity: metadata.fileIdentity,
                    linkCount: metadata.linkCount,
                    isPackage: metadata.isPackage,
                    isAccessible: metadata.isReadable && childrenAreAccessible,
                    isSelfAccessible: metadata.isReadable,
                    isSynthetic: false,
                    isAutoSummarized: false
                )
                nodes.append(assembled)
                parentRawIndices.append(UInt32.max)
                childSpans.append(FileTreeChildSpan(
                    start: UInt32(childSpanStart),
                    count: UInt32(childIndices.count - childSpanStart)
                ))
                aggregateStats.include(assembled, hasChildren: childIndices.count > childSpanStart)

                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            case .leaf(let onlyChild):
                // Leaf node or inaccessible directory: use the child directly.
                let correctedChild = SharedAllocationDeduplicator.deduplicatedNode(
                    onlyChild,
                    duplicateAllocatedSize: duplicateAllocatedSizeByOwner[onlyChild.id] ?? 0,
                    minimumAllocatedSize: minimumAllocatedSizeByNodeID[onlyChild.id] ?? 0
                )
                nodes.append(correctedChild)
                parentRawIndices.append(UInt32.max)
                childSpans.append(FileTreeChildSpan())
                aggregateStats.include(correctedChild, hasChildren: false)
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try Task.checkCancellation()
                metrics.finalizationFraction = Double(finalizedItems) / Double(finalizationTotal)
                metrics.recalculateProgress()
                atomicSummaryPool.updateProgress(
                    metrics,
                    continuation: continuation,
                    force: true
                )
            }
        }
        guard let rootNode = nodes.last else {
            throw ScanEngineError.missingRootNode
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize.assemble",
            url: target.url,
            startedAt: assemblyStart,
            itemCount: finalizedItems
        )
        let indexStart = diagnostics?.start()
        #endif

        let indexByNodeID = scanKeyByNodeID.mapValues { scanKey in
            FileTreeNodeIndex(rawValue: UInt32(nextKey - scanKey - 1))
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize.index",
            url: target.url,
            startedAt: indexStart,
            itemCount: nodes.count
        )
        #endif

        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count - 1))
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: &metrics, continuation: continuation, emissionState: &emissionState, summaryPool: atomicSummaryPool)

        #if DEBUG
        let storeConstructionStart = diagnostics?.start()
        #endif
        let store = try FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            aggregateStats: aggregateStats.makeStats(root: rootNode),
            cancellationCheck: Task.checkCancellation
        )
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize.store",
            url: target.url,
            startedAt: storeConstructionStart,
            itemCount: nodes.count
        )
        diagnostics?.record(
            operation: "scan.finalize.total",
            url: target.url,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )
        #endif
        await atomicSummaryPool.finish()
        directoryDescriptorPool?.invalidate()
        return store
        } catch {
            directoryDescriptorPool?.cancel()
            await atomicSummaryPool.cancelAndFinish(with: error)
            throw error
        }
    }

    // MARK: - Helpers

    private nonisolated func prepareOrdinaryLeaves(
        _ request: OrdinaryLeafPreparationRequest,
        cancellationCheck: CancellationCheck
    ) throws -> PreparedOrdinaryLeafBatch {
        var items: [PreparedOrdinaryLeafItem] = []
        items.reserveCapacity(request.range.count)
        for index in request.range {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let entry = request.entries[index]
            guard let metadata = entry.metadata,
                  !metadata.isDirectory || metadata.isSymbolicLink else {
                continue
            }
            let node = makeFileNode(url: entry.url, metadata: metadata)
            items.append(PreparedOrdinaryLeafItem(
                weight: request.parentWeight / request.totalWeightUnits,
                node: node,
                sharedAllocationClaim: SharedAllocationDeduplicator.claim(
                    for: metadata,
                    ownerNodeID: node.id,
                    path: node.id
                )
            ))
        }
        try cancellationCheck()
        return PreparedOrdinaryLeafBatch(parentKey: request.parentKey, items: items)
    }

    private nonisolated func recordPreparedOrdinaryLeaf(
        _ item: PreparedOrdinaryLeafItem,
        parentKey: Int,
        nextKey: inout Int,
        scanKeyByNodeID: inout [String: Int],
        sharedAllocationAccumulator: inout SharedAllocationOwnerAccumulator,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool,
        completedByKey: inout [CompletedDirScan?],
        childrenKeysByKey: inout [[Int]?]
    ) {
        let childNode = item.node
        let childPath = childNode.id
        if let previousKey = scanKeyByNodeID.updateValue(nextKey, forKey: childPath) {
            scanKeyByNodeID[childPath] = previousKey
            recordDuplicateNode(
                at: childNode.url,
                weight: item.weight,
                metrics: &metrics,
                warnings: &warnings,
                continuation: continuation,
                emissionState: &emissionState,
                summaryPool: summaryPool
            )
            return
        }

        let childKey = nextKey
        nextKey += 1
        completedByKey.append(nil)
        childrenKeysByKey.append(nil)
        if childrenKeysByKey[parentKey] == nil {
            childrenKeysByKey[parentKey] = []
        }
        childrenKeysByKey[parentKey]!.append(childKey)

        if let sharedAllocationClaim = item.sharedAllocationClaim {
            sharedAllocationAccumulator.record(sharedAllocationClaim)
        }
        metrics.currentPath = childPath
        applyLeafMetrics(childNode, weight: item.weight, metrics: &metrics)
        maybeEmitProgress(
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            summaryPool: summaryPool
        )
        completedByKey[childKey] = .leaf(childNode)
    }

    private nonisolated func applyLeafMetrics(
        _ node: FileNodeRecord,
        weight: Double,
        summaryVisitedItemCount: Int = 0,
        summaryRepresentedItemCount: Int = 0,
        metrics: inout ScanMetrics
    ) {
        if node.isDirectory {
            if !node.isAutoSummarized {
                metrics.directoriesVisited += 1
            }
            metrics.filesVisited += node.descendantFileCount
        } else if !node.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered += node.allocatedSize
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        if node.isDirectory, node.isAutoSummarized || node.isPackage {
            let visitedItemCount = max(summaryVisitedItemCount, 0)
            let representedItemCount = min(
                max(summaryRepresentedItemCount, 0),
                visitedItemCount
            )
            metrics.completedSummaryAdditionalVisitedItemCount = ScanIntegerMath.addingClamped(
                metrics.completedSummaryAdditionalVisitedItemCount,
                visitedItemCount - representedItemCount
            )
            if node.isPackage {
                metrics.completedPackageSummaryCount += 1
                metrics.completedPackageSummaryVisitedItemCount = ScanIntegerMath.addingClamped(
                    metrics.completedPackageSummaryVisitedItemCount,
                    visitedItemCount
                )
            }
        }
    }

    /// Relative progress weight of a traversable directory child versus a single file.
    /// A subdirectory hides an unscanned subtree of unknown size, so it gets a larger
    /// share of its parent's weight than a file does.
    private static let directoryChildWeightUnits = 8.0

    /// Classifies an item the same way at discovery time and at pop time so the
    /// frontier accounting in `ScanMetrics` stays balanced.
    private nonisolated static func isLikelyTraversableDirectory(
        metadata: NodeMetadata?,
        url: URL,
        isDirectoryHint: Bool? = nil
    ) -> Bool {
        guard let metadata else {
            return isDirectoryHint ?? url.hasDirectoryPath
        }
        return metadata.isDirectory && !metadata.isSymbolicLink
    }

    private nonisolated static func traversalWeightUnits(for entry: DirectoryEntry) -> Double {
        isLikelyTraversableDirectory(entry: entry) ? directoryChildWeightUnits : 1
    }

    private nonisolated static func isLikelyTraversableDirectory(entry: DirectoryEntry) -> Bool {
        isLikelyTraversableDirectory(
            metadata: entry.metadata,
            url: entry.url,
            isDirectoryHint: entry.isDirectoryHint
        )
    }

    /// Removes an item's frontier claim once its fate is known (enumerated, leaf,
    /// duplicate, or unavailable). Uses the same classifier as discovery so the
    /// pending count stays balanced.
    private nonisolated func releasePendingDirectoryIfNeeded(for item: ScanWorkItem, metrics: inout ScanMetrics) {
        guard Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        ) else { return }
        metrics.pendingDirectoryCount = max(metrics.pendingDirectoryCount - 1, 0)
    }

    private nonisolated func recordDuplicateNode(
        at url: URL,
        weight: Double,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil
    ) {
        let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: url)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        maybeEmitProgress(
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            summaryPool: summaryPool
        )
    }

    private nonisolated func recordUnavailableItem(
        _ item: ScanWorkItem,
        itemKey: Int,
        error: Error,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil,
        completedByKey: inout [CompletedDirScan?]
    ) {
        let isDirectory = Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        )
        let warning = ScanWarningFactory.makeWarning(for: item.url, error: error)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += item.weight
        maybeEmitProgress(
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            summaryPool: summaryPool
        )

        completedByKey[itemKey] = .leaf(
            makeUnavailableNode(for: item.url, isDirectory: isDirectory)
        )
    }

    private nonisolated func makeUnavailableNode(for url: URL, isDirectory: Bool) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private nonisolated static func directoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        directoryContents: DirectoryContentsProvider,
        usesBulkDirectoryEnumeration: Bool,
        usesDeferredBulkEntryFiltering: Bool,
        directoryNamespaceResolver: DirectoryNamespaceResolver,
        directoryDescriptorPool: ScanDirectoryDescriptorPool?,
        parentDirectoryLease: ScanDirectoryDescriptorPool.Lease?,
        nativeName: BulkDirectoryEnumerator.NativeName?,
        expectedIdentity: FileIdentity?,
        classificationWorkerLimit: Int,
        preloadedListing: AtomicDirectoryProbeListing? = nil,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> DirectoryContentsScanResult {
        try cancellationCheck()

        if usesBulkDirectoryEnumeration {
            #if DEBUG
            var enumerationNanoseconds: UInt64 = 0
            var classificationNanoseconds: UInt64 = 0
            #endif
            let directoryLease: ScanDirectoryDescriptorPool.Lease?
            if let directoryDescriptorPool,
               let parentDirectoryLease,
               let nativeName {
                switch try directoryDescriptorPool.openChild(
                    named: nativeName,
                    at: url,
                    relativeTo: parentDirectoryLease,
                    expectedIdentity: expectedIdentity,
                    cancellationCheck: cancellationCheck
                ) {
                case .lease(let lease):
                    directoryLease = lease
                case .fallback:
                    directoryLease = nil
                }
            } else if let directoryDescriptorPool {
                switch try directoryDescriptorPool.openRoot(
                    at: url,
                    expectedIdentity: expectedIdentity,
                    cancellationCheck: cancellationCheck
                ) {
                case .lease(let lease): directoryLease = lease
                case .fallback: directoryLease = nil
                }
            } else {
                directoryLease = nil
            }
            if let preloadedListing, directoryLease != nil {
                #if DEBUG
                let classificationStart = DispatchTime.now().uptimeNanoseconds
                #endif
                let entries = try ScanDirectoryEntryFilter.filteredEntries(
                    preloadedListing.entries,
                    under: url,
                    behavior: behavior,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck
                )
                #if DEBUG
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: preloadedListing.enumeratedItemCount,
                    directoryLease: directoryLease,
                    enumerationNanoseconds: 0,
                    classificationNanoseconds: DispatchTime.now().uptimeNanoseconds - classificationStart,
                    reusedProbeListing: true
                )
                #else
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: preloadedListing.enumeratedItemCount,
                    directoryLease: directoryLease
                )
                #endif
            }
            let cursor: BulkDirectoryEnumerator.Cursor
            let entryInclusion: BulkDirectoryEnumerator.EntryInclusion?
            let canExcludeNativeEntry = !exclusionMatcher.isEmpty
                || shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            let requiresPostEnumerationFiltering = canExcludeNativeEntry
                && !usesDeferredBulkEntryFiltering
            if usesDeferredBulkEntryFiltering && canExcludeNativeEntry {
                let parentPath = url.path
                entryInclusion = { childName, isDirectory in
                    ScanDirectoryEntryFilter.includes(
                        childName: childName,
                        parentPath: parentPath,
                        behavior: behavior
                    ) && !exclusionMatcher.excludesKnownNormalizedChild(
                        named: childName,
                        under: parentPath,
                        isDirectory: isDirectory
                    )
                }
            } else {
                entryInclusion = nil
            }
            if let directoryLease {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: url,
                    borrowing: directoryLease,
                    includeHiddenFiles: includeHiddenFiles,
                    metadataLoader: metadataLoader,
                    entryInclusion: entryInclusion,
                    cancellationCheck: cancellationCheck
                )
            } else {
                cursor = try BulkDirectoryEnumerator.makeCursor(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    metadataLoader: metadataLoader,
                    entryInclusion: entryInclusion,
                    cancellationCheck: cancellationCheck
                )
            }
            var entries: [DirectoryEntry] = []
            var enumeratedItemCount = 0
            do {
                while true {
                    #if DEBUG
                    let batchStart = DispatchTime.now().uptimeNanoseconds
                    #endif
                    guard let batch = try cursor.nextBatch(cancellationCheck: cancellationCheck) else {
                        #if DEBUG
                        enumerationNanoseconds += DispatchTime.now().uptimeNanoseconds - batchStart
                        #endif
                        break
                    }
                    #if DEBUG
                    enumerationNanoseconds += DispatchTime.now().uptimeNanoseconds - batchStart
                    let classificationStart = DispatchTime.now().uptimeNanoseconds
                    #endif
                    let acceptedEntries = if requiresPostEnumerationFiltering {
                        try ScanDirectoryEntryFilter.filteredEntries(
                            batch.entries,
                            under: url,
                            behavior: behavior,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck
                        )
                    } else {
                        batch.entries
                    }
                    if entries.isEmpty {
                        entries = acceptedEntries
                    } else {
                        entries.append(contentsOf: acceptedEntries)
                    }
                    enumeratedItemCount += batch.enumeratedItemCount
                    #if DEBUG
                    classificationNanoseconds += DispatchTime.now().uptimeNanoseconds - classificationStart
                    #endif
                }
                #if DEBUG
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: enumeratedItemCount,
                    directoryLease: directoryLease,
                    enumerationNanoseconds: enumerationNanoseconds,
                    classificationNanoseconds: classificationNanoseconds,
                    reusedProbeListing: false
                )
                #else
                return DirectoryContentsScanResult(
                    entries: entries,
                    enumeratedItemCount: enumeratedItemCount,
                    directoryLease: directoryLease
                )
                #endif
            } catch BulkDirectoryEnumerator.StreamError.unavailable {
                directoryLease?.close()
                // Discard the uncommitted native batches and use the Foundation path.
            } catch {
                directoryLease?.close()
                throw error
            }
        }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        try metadataLoader.validateFileSystemIdentity(
            expectedIdentity,
            at: url
        )

        let prefetchKeys = shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            ? nil
            : Array(resourceKeys)
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let enumerationResult = try directoryContents(url, prefetchKeys, options, cancellationCheck)
        // FileManager has no descriptor-relative directory API. Bookend its
        // path-based enumeration so any replacement that persists across the
        // call is discarded instead of entering the scan.
        try metadataLoader.validateFileSystemIdentity(
            expectedIdentity,
            at: url
        )
        #if DEBUG
        let enumerationNanoseconds = DispatchTime.now().uptimeNanoseconds - enumerationStart
        #endif
        try cancellationCheck()

        #if DEBUG
        let classificationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let namespacePreservedURLs = directoryNamespaceResolver.preservingParentNamespace(
            enumerationResult.urls,
            under: url
        )
        let namespacePreservedFailures = enumerationResult.localizedFailures.map { failure in
            let preservedURL = directoryNamespaceResolver.preservingParentNamespace(
                [failure.url],
                under: url
            ).first ?? failure.url
            return DirectoryEnumerationFailure(
                url: preservedURL,
                error: failure.error,
                isDirectoryHint: failure.isDirectoryHint
            )
        }
        var entries = try await Self.classifiedDirectoryEntries(
            namespacePreservedURLs,
            under: url,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: resourceKeys,
            metadataLoader: metadataLoader,
            workerLimit: classificationWorkerLimit,
            cancellationCheck: cancellationCheck
        )
        entries.append(contentsOf:
            ScanDirectoryEntryFilter.entriesForLocalizedFailures(
                namespacePreservedFailures,
                under: url,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            )
        )
        #if DEBUG
        let classificationNanoseconds = DispatchTime.now().uptimeNanoseconds - classificationStart
        #endif

        try cancellationCheck()
        #if DEBUG
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count,
            directoryLease: nil,
            enumerationNanoseconds: enumerationNanoseconds,
            classificationNanoseconds: classificationNanoseconds,
            reusedProbeListing: false
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count,
            directoryLease: nil
        )
        #endif
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        workerLimit: Int,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> [DirectoryEntry] {
        guard workerLimit > 1,
              contents.count >= ScanConcurrencyPolicy.directoryClassificationParallelThreshold else {
            return try classifiedDirectoryEntries(
                contents,
                range: contents.indices,
                under: parentURL,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                resourceKeys: resourceKeys,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck
            )
        }

        let workerCount = min(max(1, workerLimit), contents.count)
        let chunkSize = max(
            ScanConcurrencyPolicy.directoryClassificationParallelThreshold,
            (contents.count + workerCount - 1) / workerCount
        )
        let chunkCount = (contents.count + chunkSize - 1) / chunkSize
        var chunks = Array<[DirectoryEntry]?>(repeating: nil, count: chunkCount)

        try await withThrowingTaskGroup(of: ClassifiedDirectoryEntriesChunk.self) { group in
            var chunkIndex = 0
            var chunkStart = 0
            while chunkStart < contents.count {
                let chunkEnd = min(chunkStart + chunkSize, contents.count)
                let range = chunkStart..<chunkEnd
                let index = chunkIndex
                group.addTask {
                    let entries = try classifiedDirectoryEntries(
                        contents,
                        range: range,
                        under: parentURL,
                        behavior: behavior,
                        exclusionMatcher: exclusionMatcher,
                        resourceKeys: resourceKeys,
                        metadataLoader: metadataLoader,
                        cancellationCheck: cancellationCheck
                    )
                    return ClassifiedDirectoryEntriesChunk(index: index, entries: entries)
                }
                chunkIndex += 1
                chunkStart = chunkEnd
            }

            for try await chunk in group {
                chunks[chunk.index] = chunk.entries
            }
        }

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(contents.count)
        for chunk in chunks {
            guard let chunk else { continue }
            entries.append(contentsOf: chunk)
        }
        return entries
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        range: Range<Int>,
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck
    ) throws -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(range.count)

        for index in range {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            let childURL = contents[index]
            guard ScanDirectoryEntryFilter.includes(
                childURL,
                under: parentURL,
                behavior: behavior
            ) else {
                continue
            }

            let childMetadata = try? metadataLoader.metadata(
                for: childURL,
                prefetchedResourceValues: childURL.resourceValues(forKeys: resourceKeys)
            )
            guard childMetadata?.isDataless != true else {
                continue
            }
            guard !exclusionMatcher.excludes(
                childURL,
                isDirectory: childMetadata?.isDirectory ?? childURL.hasDirectoryPath
            ) else {
                continue
            }

            entries.append(DirectoryEntry(url: childURL, metadata: childMetadata))
        }

        try cancellationCheck()
        return entries
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && (parentURL.path == "/" || parentURL.path == "/System")
    }

    /// Startup-volume firmlinks deliberately resolve from the sealed System
    /// volume into the Data volume. Their enumerated and opened identities are
    /// therefore expected to differ; all other directory opens retain strict
    /// replacement detection.
    nonisolated static func verifiesDirectoryIdentity(
        at url: URL,
        behavior: ScanBehavior
    ) -> Bool {
        !behavior.excludesStartupVolumeInternals
            || !TrashSafetyPolicy.isStartupVolumeFirmlinkRoot(url)
    }

    nonisolated func makeFileNode(
        url: URL,
        metadata: NodeMetadata
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: metadata.allocatedSize,
            dataAllocatedSize: metadata.dataAllocatedSize,
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            fileIdentity: metadata.fileIdentity,
            linkCount: metadata.linkCount,
            cloneIdentity: metadata.cloneIdentity,
            mayShareDataBlocks: metadata.mayShareDataBlocks,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSelfAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private nonisolated func makeLeafNode(
        url: URL,
        metadata: NodeMetadata,
        options: ScanOptions,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        atomicDirectorySummarizer: AtomicDirectorySummarizer,
        summarizesPackageContents: Bool = true,
        progressWeight: Double,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> LeafNodeResult {
        try cancellationCheck()
        guard summarizesPackageContents,
              metadata.isPackage,
              metadata.isDirectory,
              !options.treatPackagesAsDirectories else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            let sharedAllocationClaim = SharedAllocationDeduplicator.claim(
                for: metadata,
                ownerNodeID: node.id,
                path: url.path
            )
            var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
            if let sharedAllocationClaim {
                sharedAllocationAccumulator.record(sharedAllocationClaim)
            }
            return LeafNodeResult(
                node: node,
                warnings: [],
                sharedAllocationAccumulator: sharedAllocationAccumulator,
                minimumAllocatedSize: nil,
                summaryVisitedItemCount: 0
            )
        }

        guard let summary = try await atomicDirectorySummarizer.summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            progressWeight: progressWeight,
            progressKind: .package,
            representedItemCount: 0,
            ownerNodeID: url.path,
            expectedRootIdentity: Self.verifiesDirectoryIdentity(
                at: url,
                behavior: behavior
            ) ? metadata.fileIdentity : nil,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation
        ) else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            let sharedAllocationClaim = SharedAllocationDeduplicator.claim(
                for: metadata,
                ownerNodeID: node.id,
                path: url.path
            )
            var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()
            if let sharedAllocationClaim {
                sharedAllocationAccumulator.record(sharedAllocationClaim)
            }
            return LeafNodeResult(
                node: node,
                warnings: [],
                sharedAllocationAccumulator: sharedAllocationAccumulator,
                minimumAllocatedSize: nil,
                summaryVisitedItemCount: 0
            )
        }

        return LeafNodeResult(
            node: FileNodeRecord(
                id: url.path,
                url: url,
                name: ScanTarget.displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: metadata.lastModified,
                fileIdentity: metadata.fileIdentity,
                linkCount: metadata.linkCount,
                isPackage: true,
                isAccessible: metadata.isReadable && summary.isAccessible,
                isSelfAccessible: metadata.isReadable,
                isSynthetic: false,
                isAutoSummarized: false
            ),
            warnings: summary.warnings,
            sharedAllocationAccumulator: summary.sharedAllocationAccumulator,
            minimumAllocatedSize: metadata.allocatedSize,
            summaryVisitedItemCount: summary.visitedItemCount
        )
    }

    private nonisolated func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        scanOptions: ScanOptions?,
        volumeCapacity: VolumeCapacitySnapshot? = nil,
        reconcilesVolumeCapacity: Bool = false,
        hasActiveExclusions: Bool = false
    ) -> ScanSnapshot {
        let reconciledStore = VolumeCapacityAccounting.reconciledStore(
            treeStore,
            target: target,
            capacity: reconcilesVolumeCapacity ? volumeCapacity : nil,
            hasActiveExclusions: hasActiveExclusions
        )

        return ScanSnapshot(
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            isComplete: isComplete,
            scanOptions: scanOptions,
            volumeCapacity: volumeCapacity
        )
    }

    private nonisolated func maybeEmitProgress(
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        summaryPool: AtomicDirectorySummaryPool? = nil
    ) {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let isFixedEmissionPoint = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000)
        guard isFixedEmissionPoint || visitedItems.isMultiple(of: 64) else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = isFixedEmissionPoint || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        metrics.recalculateProgress()
        if let summaryPool {
            summaryPool.updateProgress(metrics, continuation: continuation)
        } else {
            continuation.yield(.progress(metrics))
        }
    }

    private nonisolated func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        guard !metadata.isDataless else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
    }

    /// APFS capacity is container-wide and includes storage that cannot be attributed
    /// safely to any one mounted volume (including the startup volume). Reconciling it
    /// against per-file allocations creates a misleading synthetic remainder, so keep
    /// capacity accounting separate from the scanned tree on every APFS volume.
    private nonisolated func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        guard target.kind == .volume,
              let volumeCapacity = metadata.volumeCapacity,
              shouldReconcileVolumeCapacity(for: target.url) else {
            return 0
        }
        return max(volumeCapacity.usedCapacity, metadata.allocatedSize)
    }

    private nonisolated func shouldReconcileVolumeCapacity(for url: URL) -> Bool {
        guard let fileSystemType = volumeFileSystemTypeProvider(url) else {
            return false
        }
        return Self.shouldReconcileVolumeCapacity(fileSystemType: fileSystemType)
    }

    nonisolated static func shouldReconcileVolumeCapacity(fileSystemType: String) -> Bool {
        let normalizedType = fileSystemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedType.isEmpty else { return false }
        return normalizedType != "apfs"
    }

}

extension FileManager.DirectoryEnumerator: nonisolated ScanEngine.DirectoryObjectEnumerating {}

nonisolated struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
