//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Dispatch
import Foundation

actor ScanEngine {
    protocol DirectoryObjectEnumerating: AnyObject {
        func nextObject() -> Any?
    }

    private enum ScanEngineError: LocalizedError {
        case missingRootNode

        var errorDescription: String? {
            switch self {
            case .missingRootNode:
                return "The scan could not assemble a root node."
            }
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
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

    private struct DirectoryContentsScanResult: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        #if DEBUG
        let enumerationNanoseconds: UInt64
        let classificationNanoseconds: UInt64
        #endif
    }

    private struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: DirectoryContentsScanResult
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

    /// A completed directory scan awaiting parent assembly.
    private struct CompletedDirScan {
        let node: FileNodeRecord?     // Leaves carry a node; traversable dirs are resolved in phase 2.
        let metadata: NodeMetadata
        let url: URL
        let isTraversable: Bool     // True if this was a directory we intended to traverse.
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

    private let directoryContents: DirectoryContentsProvider
    private let metadataLoader: ScanMetadataLoader
    private let atomicDirectorySummarizer: AtomicDirectorySummarizer
    private let diagnostics: ScanDiagnosticsContext?

    init(enumeratedDirectoryContents: @escaping DirectoryContentsProvider = ScanEngine.defaultDirectoryContents) {
        #if DEBUG
        let diagnostics = ScanDiagnostics.makeIfEnabled()
        #else
        let diagnostics: ScanDiagnosticsContext? = nil
        #endif
        let metadataLoader = ScanMetadataLoader(diagnostics: diagnostics)
        self.directoryContents = enumeratedDirectoryContents
        self.metadataLoader = metadataLoader
        self.atomicDirectorySummarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            diagnostics: diagnostics
        )
        self.diagnostics = diagnostics
    }

    init(directoryContents: @escaping URLDirectoryContentsProvider) {
        self.init(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            let urls = try directoryContents(url, keys, options, cancellationCheck)
            return DirectoryEnumerationResult(urls: urls)
        })
    }

    private nonisolated static func defaultDirectoryContents(
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
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let snapshot = try await self.performScan(
                        target: target,
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

    // The scan path (`performScan` and the helpers it calls) is `nonisolated` on
    // purpose. `ScanEngine`'s stored properties are all `let`, so the scan holds no
    // actor-mutable state and isolation bought us nothing but serialization on the
    // actor's executor — which let a previous, still-cancelling scan block a freshly
    // started one from running. Keeping these `nonisolated` is what allows overlapping
    // scans to make progress independently. Do not re-isolate without reintroducing
    // that bug (see testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling).
    private nonisolated func performScan(
        target: ScanTarget,
        options: ScanOptions,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> ScanSnapshot {
        let startedAt = Date()
        var metrics = ScanMetrics()
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
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
            emissionState: &emissionState
        )
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        continuation.yield(.progress(metrics))

        let snapshot = makeSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true,
            expectedTotalBytes: exclusionMatcher.isEmpty ? metrics.estimatedTotalBytes : 0
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        #if DEBUG
        if let diagnostics {
            print(diagnostics.makeReport(targetPath: target.url.path, elapsedSeconds: Date().timeIntervalSince(startedAt)))
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
        emissionState: inout ScanEmissionState
    ) async throws -> FileTreeStore {
        try Task.checkCancellation()
        let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }

        let rootMetadata = try metadataLoader.metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()
        var hardLinkClaims: [HardLinkClaim] = []
        var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
        let atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        let directoryTraversalWorkerLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(for: options)
        let directoryClassificationWorkerLimit = ScanConcurrencyPolicy.directoryClassificationWorkerLimit(for: options)
        let effectiveDirectoryClassificationWorkerLimit = ScanConcurrencyPolicy.effectiveDirectoryClassificationWorkerLimit(
            traversalWorkerLimit: directoryTraversalWorkerLimit,
            classificationWorkerLimit: directoryClassificationWorkerLimit
        )
        let scanMetadataLoader = metadataLoader
        let directoryContentsProvider = directoryContents
        let directoryResourceKeys = ScanMetadataLoader.scanResourceKeys

        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, options: options) else {
            let leafResult = try await makeLeafNode(
                url: target.url,
                metadata: rootMetadata,
                options: options,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
            if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
            }
            applyLeafMetrics(leafResult.node, weight: 1, metrics: &metrics)
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            continuation.yield(.progress(metrics))
            let rawStore = FileTreeStore(root: leafResult.node)
            return HardLinkDeduplicator.deduplicatedStore(
                rootID: leafResult.node.id,
                nodesByID: [leafResult.node.id: leafResult.node],
                childIDsByID: [:],
                parentIDByID: [:],
                aggregateStats: rawStore.aggregateStats,
                hardLinkClaims: hardLinkClaims,
                minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
            )
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
        var completedByKey: [Int: CompletedDirScan] = [:]
        // Maps parent key → child keys, built during phase 1.
        var childrenKeysByKey: [Int: [Int]] = [:]
        var seenScannedNodeIDs = Set<String>()
        var nextKey = 0

        try await withThrowingTaskGroup(of: DirectoryTraversalResult.self) { group in
            var activeDirectoryTasks = 0

            while true {
                while activeDirectoryTasks < directoryTraversalWorkerLimit,
                      let item = workStack.popLast() {
                    try Task.checkCancellation()

                    guard seenScannedNodeIDs.insert(item.url.path).inserted else {
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        recordDuplicateNode(
                            at: item.url,
                            weight: item.weight,
                            metrics: &metrics,
                            warnings: &warnings,
                            continuation: continuation,
                            emissionState: &emissionState
                        )
                        continue
                    }

                    let itemKey = nextKey
                    nextKey += 1

                    // Register this child with its parent (skip root which has parentKey -1).
                    if item.parentKey >= 0 {
                        childrenKeysByKey[item.parentKey, default: []].append(itemKey)
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
                            completedByKey: &completedByKey
                        )
                        continue
                    } else if let itemMetadata = item.metadata {
                        meta = itemMetadata
                    } else {
                        do {
                            meta = try metadataLoader.metadata(for: item.url)
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
                                completedByKey: &completedByKey
                            )
                            continue
                        }
                    }
                    metrics.currentPath = item.url.path

                    if shouldTraverseDirectory(metadata: meta, options: options) {
                        metrics.directoriesVisited += 1
                        metrics.recalculateProgress()
                        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

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
                                    classificationWorkerLimit: effectiveDirectoryClassificationWorkerLimit,
                                    cancellationCheck: cancellationCheck
                                )
                                return .success(DirectoryTraversalSuccess(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents
                                ))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                #if DEBUG
                                return .failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
                                ))
                                #else
                                return .failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error)
                                ))
                                #endif
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory). Discovery may
                        // have classified it as a pending directory; release that claim.
                        releasePendingDirectoryIfNeeded(for: item, metrics: &metrics)
                        let leafResult = try await makeLeafNode(
                            url: item.url,
                            metadata: meta,
                            options: options,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck,
                            metrics: &metrics,
                            continuation: continuation,
                            emissionState: &emissionState
                        )
                        hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
                        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
                            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
                        }
                        applyLeafMetrics(leafResult.node, weight: item.weight, metrics: &metrics)
                        if !leafResult.warnings.isEmpty {
                            warnings.append(contentsOf: leafResult.warnings)
                            for warning in leafResult.warnings {
                                continuation.yield(.warning(warning))
                            }
                        }
                        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                        completedByKey[itemKey] = CompletedDirScan(
                            node: leafResult.node,
                            metadata: meta,
                            url: item.url,
                            isTraversable: false
                        )
                    }
                }

                guard activeDirectoryTasks > 0 else { break }
                guard let traversalResult = try await group.next() else { break }
                activeDirectoryTasks -= 1

                switch traversalResult {
                case .success(let success):
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
                    var childDirectoryCount = 0
                    for childEntry in childEntries
                    where Self.isLikelyTraversableDirectory(entry: childEntry) {
                        childDirectoryCount += 1
                    }
                    metrics.discoveredDirectoryCount += childDirectoryCount
                    metrics.pendingDirectoryCount += childDirectoryCount
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    // Check if this directory should be summarized as atomic (many small files)
                    let minFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
                    let maxAvgSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
                    let minDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
                    let isNodeDependencyLayout = AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: item.url)
                    let canProbeForAutoSummary =
                        item.depth >= minDepth ||
                        (item.depth >= 1 && isNodeDependencyLayout)
                    var completedAsAtomicDirectory = false
                    if options.autoSummarizeDirectories,
                       canProbeForAutoSummary,
                       let summary = try await atomicDirectorySummarizer.summaryIfNeeded(
                           url: item.url,
                           childEntries: childEntries,
                           metadata: meta,
                           includeHiddenFiles: options.includeHiddenFiles,
                           treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                           isNodeDependencyLayout: isNodeDependencyLayout,
                           minFileCount: minFileCount,
                           maxAverageFileSize: maxAvgSize,
                           workerLimit: atomicSummaryWorkerLimit,
                           exclusionMatcher: exclusionMatcher,
                           cancellationCheck: cancellationCheck,
                           metrics: &metrics,
                           continuation: continuation,
                           emissionState: &emissionState
                       ) {
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
                            isPackage: false,
                            isAccessible: summary.isAccessible,
                            isSelfAccessible: meta.isReadable,
                            isSynthetic: false,
                            isAutoSummarized: true
                        )
                        hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
                        minimumAllocatedSizeByNodeID[atomicNode.id] = meta.allocatedSize
                        // The summarized children will never be enqueued: count them as
                        // completed and release their frontier claims.
                        metrics.completedItems += childEntries.count
                        metrics.discoveredDirectoryCount = max(
                            metrics.discoveredDirectoryCount - childDirectoryCount,
                            0
                        )
                        metrics.pendingDirectoryCount = max(metrics.pendingDirectoryCount - childDirectoryCount, 0)
                        applyLeafMetrics(atomicNode, weight: item.weight, metrics: &metrics)
                        if !summary.warnings.isEmpty {
                            warnings.append(contentsOf: summary.warnings)
                            for warning in summary.warnings {
                                continuation.yield(.warning(warning))
                            }
                        }
                        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                        completedByKey[itemKey] = CompletedDirScan(
                            node: atomicNode,
                            metadata: meta,
                            url: item.url,
                            isTraversable: false
                        )
                        completedAsAtomicDirectory = true
                    }

                    guard !completedAsAtomicDirectory else { break }

                    if childEntries.isEmpty {
                        // Nothing below this directory: its whole weight is done.
                        metrics.completedTraversalWeight += item.weight
                        metrics.recalculateProgress()
                    }

                    // Split this directory's progress weight among its children.
                    var totalWeightUnits = 0.0
                    for childEntry in childEntries {
                        totalWeightUnits += Self.traversalWeightUnits(for: childEntry)
                    }

                    // Enqueue children onto the stack. Each child records its parent key.
                    for (offset, childEntry) in childEntries.enumerated() {
                        if offset.isMultiple(of: 256) {
                            try Task.checkCancellation()
                        }
                        workStack.append(
                            ScanWorkItem(
                                url: childEntry.url,
                                metadata: childEntry.metadata,
                                localizedEnumerationError: childEntry.localizedEnumerationError,
                                isDirectoryHint: childEntry.isDirectoryHint,
                                parentKey: itemKey,
                                depth: item.depth + 1,
                                weight: item.weight * Self.traversalWeightUnits(for: childEntry) / totalWeightUnits
                            )
                        )
                    }
                    // Register this directory so phase 2 can assemble it.
                    completedByKey[itemKey] = CompletedDirScan(
                        node: nil,
                        metadata: meta,
                        url: item.url,
                        isTraversable: true
                    )

                case .failure(let failure):
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
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

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
                        isPackage: meta.isPackage,
                        isAccessible: false,
                        isSelfAccessible: false,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                    completedByKey[itemKey] = CompletedDirScan(
                        node: inaccessibleNode,
                        metadata: meta,
                        url: item.url,
                        isTraversable: false
                    )
                }
            }
        }

        // Phase 2: Assemble the tree bottom-up from completed results.
        // Process keys in reverse order (children always have higher keys than parents).
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        let finalizationTotal = max(completedByKey.count, 1)
        let finalizationProgressInterval = 512
        var finalizedItems = 0
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var nodesByID: [String: FileNodeRecord] = [:]
        var aggregateStats = AggregateStatsAccumulator()
        resolvedNodeByKey.reserveCapacity(completedByKey.count)
        childIDsByID.reserveCapacity(completedByKey.count)
        parentIDByID.reserveCapacity(completedByKey.count)
        nodesByID.reserveCapacity(completedByKey.count)
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let completed = completedByKey.removeValue(forKey: key) else { continue }
            finalizedItems += 1

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey.removeValue(forKey: key) ?? []
                var childNodes: [FileNodeRecord] = []
                childNodes.reserveCapacity(childKeys.count)
                for (offset, childKey) in childKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    if let childNode = resolvedNodeByKey.removeValue(forKey: childKey) {
                        childNodes.append(childNode)
                    }
                }
                let sortedChildren = FileTreeStore.sortedChildren(Self.uniqueNodesForAssembly(childNodes))
                try Task.checkCancellation()
                let assembled = FileNodeRecord.directory(
                    id: completed.url.path,
                    url: completed.url,
                    name: ScanTarget.displayName(for: completed.url),
                    children: sortedChildren,
                    lastModified: completed.metadata.lastModified,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable,
                    childrenAreSorted: true
                )
                if insertNode(
                    assembled,
                    into: &nodesByID,
                    warnings: &warnings,
                    continuation: continuation
                ) {
                    resolvedNodeByKey[key] = assembled
                    aggregateStats.include(assembled, hasChildren: !sortedChildren.isEmpty)
                }

                var sortedChildIDs: [String] = []
                sortedChildIDs.reserveCapacity(sortedChildren.count)
                for (offset, child) in sortedChildren.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    sortedChildIDs.append(child.id)
                    parentIDByID[child.id] = assembled.id
                }
                childIDsByID[assembled.id] = sortedChildIDs

                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            } else if let onlyChild = completed.node {
                // Leaf node or inaccessible directory: use the child directly.
                if insertNode(
                    onlyChild,
                    into: &nodesByID,
                    warnings: &warnings,
                    continuation: continuation
                ) {
                    resolvedNodeByKey[key] = onlyChild
                    aggregateStats.include(onlyChild, hasChildren: false)
                }
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try Task.checkCancellation()
                metrics.finalizationFraction = Double(finalizedItems) / Double(finalizationTotal)
                metrics.recalculateProgress()
                continuation.yield(.progress(metrics))
            }
        }
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize",
            url: target.url,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )
        #endif

        guard let rootNode = resolvedNodeByKey[0] else {
            throw ScanEngineError.missingRootNode
        }

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        return HardLinkDeduplicator.deduplicatedStore(
            rootID: rootNode.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: aggregateStats.makeStats(root: rootNode),
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
    }

    // MARK: - Helpers

    private nonisolated func applyLeafMetrics(_ node: FileNodeRecord, weight: Double, metrics: inout ScanMetrics) {
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
        metrics.recalculateProgress()
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

    nonisolated static func uniqueNodesForAssembly(_ nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        var seenIDs = Set<String>()
        var uniqueNodes: [FileNodeRecord] = []
        uniqueNodes.reserveCapacity(nodes.count)

        for node in nodes where seenIDs.insert(node.id).inserted {
            uniqueNodes.append(node)
        }

        return uniqueNodes
    }

    private nonisolated func insertNode(
        _ node: FileNodeRecord,
        into nodesByID: inout [String: FileNodeRecord],
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) -> Bool {
        guard nodesByID[node.id] == nil else {
            let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: node.url)
            warnings.append(warning)
            continuation.yield(.warning(warning))
            return false
        }

        nodesByID[node.id] = node
        return true
    }

    private nonisolated func recordDuplicateNode(
        at url: URL,
        weight: Double,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: url)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
    }

    private nonisolated func recordUnavailableItem(
        _ item: ScanWorkItem,
        itemKey: Int,
        error: Error,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        completedByKey: inout [Int: CompletedDirScan]
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
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        completedByKey[itemKey] = CompletedDirScan(
            node: makeUnavailableNode(for: item.url, isDirectory: isDirectory),
            metadata: NodeMetadata(
                isDirectory: isDirectory,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: 0,
                allocatedSize: 0,
                lastModified: nil,
                isReadable: false,
                volumeUsedCapacity: nil,
                fileIdentity: nil,
                linkCount: 0
            ),
            url: item.url,
            isTraversable: false
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
        classificationWorkerLimit: Int,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> DirectoryContentsScanResult {
        try cancellationCheck()
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let prefetchKeys = shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            ? nil
            : Array(resourceKeys)
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let enumerationResult = try directoryContents(url, prefetchKeys, options, cancellationCheck)
        #if DEBUG
        let enumerationNanoseconds = DispatchTime.now().uptimeNanoseconds - enumerationStart
        #endif
        try cancellationCheck()

        #if DEBUG
        let classificationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        var entries = try await Self.classifiedDirectoryEntries(
            enumerationResult.urls,
            under: url,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: resourceKeys,
            metadataLoader: metadataLoader,
            workerLimit: classificationWorkerLimit,
            cancellationCheck: cancellationCheck
        )
        entries.append(contentsOf:
            contentsOfLocalizedEnumerationFailures(
                enumerationResult.localizedFailures,
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
            enumerationNanoseconds: enumerationNanoseconds,
            classificationNanoseconds: classificationNanoseconds
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count
        )
        #endif
    }

    private nonisolated static func contentsOfLocalizedEnumerationFailures(
        _ failures: [DirectoryEnumerationFailure],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher
    ) -> [DirectoryEntry] {
        failures.compactMap { failure in
            let isDirectoryHint = failure.isDirectoryHint ?? failure.url.hasDirectoryPath
            guard includedChildURL(failure.url, under: parentURL, behavior: behavior),
                  !exclusionMatcher.excludes(failure.url, isDirectory: isDirectoryHint) else {
                return nil
            }
            return DirectoryEntry(
                url: failure.url,
                metadata: nil,
                localizedEnumerationError: failure.error,
                isDirectoryHint: isDirectoryHint
            )
        }
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
                offset: 0,
                under: parentURL,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                resourceKeys: resourceKeys,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck
            ).map(\.entry)
        }

        let workerCount = min(max(1, workerLimit), contents.count)
        let chunkSize = max(
            ScanConcurrencyPolicy.directoryClassificationParallelThreshold,
            (contents.count + workerCount - 1) / workerCount
        )
        var classifiedEntries: [(offset: Int, entry: DirectoryEntry)] = []
        classifiedEntries.reserveCapacity(contents.count)

        try await withThrowingTaskGroup(of: [(offset: Int, entry: DirectoryEntry)].self) { group in
            var chunkStart = 0
            while chunkStart < contents.count {
                let chunkEnd = min(chunkStart + chunkSize, contents.count)
                let chunk = Array(contents[chunkStart..<chunkEnd])
                let offset = chunkStart
                group.addTask {
                    try classifiedDirectoryEntries(
                        chunk,
                        offset: offset,
                        under: parentURL,
                        behavior: behavior,
                        exclusionMatcher: exclusionMatcher,
                        resourceKeys: resourceKeys,
                        metadataLoader: metadataLoader,
                        cancellationCheck: cancellationCheck
                    )
                }
                chunkStart = chunkEnd
            }

            for try await chunkEntries in group {
                classifiedEntries.append(contentsOf: chunkEntries)
            }
        }

        classifiedEntries.sort { $0.offset < $1.offset }
        return classifiedEntries.map(\.entry)
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        offset: Int,
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck
    ) throws -> [(offset: Int, entry: DirectoryEntry)] {
        var entries: [(offset: Int, entry: DirectoryEntry)] = []
        entries.reserveCapacity(contents.count)

        for (localOffset, childURL) in contents.enumerated() {
            if localOffset.isMultiple(of: 64) {
                try cancellationCheck()
            }
            guard includedChildURL(childURL, under: parentURL, behavior: behavior) else {
                continue
            }

            let childMetadata = try? metadataLoader.metadata(
                for: childURL,
                prefetchedResourceValues: childURL.resourceValues(forKeys: resourceKeys)
            )
            guard !exclusionMatcher.excludes(
                childURL,
                isDirectory: childMetadata?.isDirectory ?? childURL.hasDirectoryPath
            ) else {
                continue
            }

            entries.append((offset + localOffset, DirectoryEntry(url: childURL, metadata: childMetadata)))
        }

        try cancellationCheck()
        return entries
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && ["/", "/System"].contains(parentURL.path)
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        let parentPath = parentURL.path
        let childName = childURL.lastPathComponent

        if parentPath == "/" && [".nofollow", ".resolve"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/" &&
            [".file", ".vol", "dev", "Volumes"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/System" &&
            childName == "Volumes" {
            return false
        }

        return true
    }

    private nonisolated func makeFileNode(
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
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
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
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> (
        node: FileNodeRecord,
        warnings: [ScanWarning],
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSize: Int64?
    ) {
        try cancellationCheck()
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            return (
                node,
                [],
                HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                nil
            )
        }

        guard let summary = try await atomicDirectorySummarizer.summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options),
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            return (
                node,
                [],
                HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                nil
            )
        }

        return (
            FileNodeRecord(
                id: url.path,
                url: url,
                name: ScanTarget.displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: metadata.lastModified,
                isPackage: true,
                isAccessible: metadata.isReadable && summary.isAccessible,
                isSelfAccessible: metadata.isReadable,
                isSynthetic: false,
                isAutoSummarized: false
            ),
            summary.warnings,
            summary.hardLinkClaims,
            metadata.allocatedSize
        )
    }

    private nonisolated func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        expectedTotalBytes: Int64 = 0
    ) -> ScanSnapshot {
        let reconciledStore = reconcileVolumeRoot(treeStore, for: target, expectedTotalBytes: expectedTotalBytes)

        return ScanSnapshot(
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: reconciledStore.aggregateStats,
            isComplete: isComplete
        )
    }

    private nonisolated func reconcileVolumeRoot(_ treeStore: FileTreeStore, for target: ScanTarget, expectedTotalBytes: Int64) -> FileTreeStore {
        let root = treeStore.root
        guard target.kind == .volume, expectedTotalBytes > root.allocatedSize else {
            return treeStore
        }

        let missingBytes = expectedTotalBytes - root.allocatedSize
        guard missingBytes >= 64 * 1_024 * 1_024 else {
            return treeStore
        }

        let unattributedNode = FileNodeRecord(
            id: "\(root.id)#system-unattributed",
            url: target.url,
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: missingBytes,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )

        let rootChildren = treeStore.children(of: root.id) + [unattributedNode]
        let sortedRootChildren = FileTreeStore.sortedChildren(rootChildren)
        let reconciledRoot = FileNodeRecord.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: sortedRootChildren,
            lastModified: root.lastModified,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            childrenAreSorted: true
        )

        var nodesByID = treeStore.nodesByID
        nodesByID[reconciledRoot.id] = reconciledRoot
        nodesByID[unattributedNode.id] = unattributedNode

        var childIDsByID = treeStore.childIDsByID
        childIDsByID[root.id] = sortedRootChildren.map(\.id)

        var parentIDByID = treeStore.parentIDByID
        parentIDByID[unattributedNode.id] = root.id

        let baseStats = treeStore.aggregateStats
        let reconciledStats = ScanAggregateStats(
            totalAllocatedSize: reconciledRoot.allocatedSize,
            totalLogicalSize: reconciledRoot.logicalSize,
            fileCount: baseStats.fileCount,
            directoryCount: baseStats.directoryCount,
            accessibleItemCount: baseStats.accessibleItemCount + 1,
            inaccessibleItemCount: baseStats.inaccessibleItemCount
        )

        return FileTreeStore(
            rootID: treeStore.rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: reconciledStats
        )
    }

    private nonisolated func maybeEmitProgress(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000) || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }

    private nonisolated func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
    }

    /// A trustworthy total is only known for volume scans (the volume's used capacity).
    /// For directory scans the root's own allocated size says nothing about its contents,
    /// so no byte-based estimate is produced and progress relies on traversal weights.
    private nonisolated func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        guard target.kind == .volume, let volumeUsedCapacity = metadata.volumeUsedCapacity else {
            return 0
        }
        return max(volumeUsedCapacity, metadata.allocatedSize)
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
