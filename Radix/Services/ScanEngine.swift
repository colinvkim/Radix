//
//  ScanEngine.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Darwin
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

    private final class AtomicDirectorySummaryState {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        var isAccessible = true
        var warnings: [ScanWarning] = []
        var hardLinkClaims: [HardLinkClaim] = []
        let ownerNodeID: String

        init(ownerNodeID: String) {
            self.ownerNodeID = ownerNodeID
        }
    }

    private final class ScanDiagnostics {
        private struct OperationStats {
            var count = 0
            var totalNanoseconds: UInt64 = 0
            var itemCount = 0
            var maxNanoseconds: UInt64 = 0
        }

        private struct SlowEvent {
            let operation: String
            let path: String
            let nanoseconds: UInt64
            let itemCount: Int?
            let detail: String?
        }

        private let reportLimit: Int
        private let slowThresholdNanoseconds: UInt64
        private var statsByOperation: [String: OperationStats] = [:]
        private var statsByPathBucket: [String: OperationStats] = [:]
        private var slowEvents: [SlowEvent] = []

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            reportLimit = environment["RADIX_SCAN_DIAGNOSTICS_LIMIT"]
                .flatMap(Int.init)
                .map { max(1, $0) } ?? 30
            let slowThresholdMilliseconds = environment["RADIX_SCAN_DIAGNOSTICS_SLOW_MS"]
                .flatMap(Double.init) ?? 50
            slowThresholdNanoseconds = UInt64(max(0, slowThresholdMilliseconds) * 1_000_000)
        }

        static func makeIfEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> ScanDiagnostics? {
            guard environment["RADIX_SCAN_DIAGNOSTICS"] == "1" else { return nil }
            return ScanDiagnostics(environment: environment)
        }

        func start() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds
        }

        func record(
            operation: String,
            url: URL,
            startedAt start: UInt64?,
            itemCount: Int? = nil,
            detail: String? = nil
        ) {
            guard let start else { return }
            record(
                operation: operation,
                path: url.path,
                nanoseconds: DispatchTime.now().uptimeNanoseconds - start,
                itemCount: itemCount,
                detail: detail
            )
        }

        func recordElapsed(
            operation: String,
            url: URL,
            nanoseconds: UInt64,
            itemCount: Int? = nil,
            detail: String? = nil
        ) {
            record(
                operation: operation,
                path: url.path,
                nanoseconds: nanoseconds,
                itemCount: itemCount,
                detail: detail
            )
        }

        func makeReport(targetPath: String, elapsedSeconds: Double) -> String {
            var lines: [String] = [
                "RADIX_SCAN_DIAGNOSTICS target=\(targetPath) elapsed=\(Self.format(seconds: elapsedSeconds))s",
                "RADIX_SCAN_DIAGNOSTICS operations"
            ]

            for (operation, stats) in sortedStats(statsByOperation) {
                lines.append(
                    "  \(operation): total=\(Self.format(nanoseconds: stats.totalNanoseconds))s count=\(stats.count) avg=\(Self.format(nanoseconds: Self.average(stats.totalNanoseconds, stats.count)))s max=\(Self.format(nanoseconds: stats.maxNanoseconds))s items=\(stats.itemCount)"
                )
            }

            lines.append("RADIX_SCAN_DIAGNOSTICS hot_path_buckets")
            for (path, stats) in sortedStats(statsByPathBucket).prefix(reportLimit) {
                lines.append(
                    "  total=\(Self.format(nanoseconds: stats.totalNanoseconds))s count=\(stats.count) max=\(Self.format(nanoseconds: stats.maxNanoseconds))s items=\(stats.itemCount) path=\(path)"
                )
            }

            lines.append("RADIX_SCAN_DIAGNOSTICS slow_events")
            for event in slowEvents.sorted(by: { $0.nanoseconds > $1.nanoseconds }).prefix(reportLimit) {
                let itemText = event.itemCount.map { " items=\($0)" } ?? ""
                let detailText = event.detail.map { " \($0)" } ?? ""
                lines.append(
                    "  \(Self.format(nanoseconds: event.nanoseconds))s \(event.operation)\(itemText)\(detailText) path=\(event.path)"
                )
            }

            return lines.joined(separator: "\n")
        }

        private func record(
            operation: String,
            path: String,
            nanoseconds: UInt64,
            itemCount: Int?,
            detail: String?
        ) {
            updateStats(&statsByOperation[operation, default: OperationStats()], nanoseconds: nanoseconds, itemCount: itemCount)
            updateStats(&statsByPathBucket[Self.pathBucket(for: path), default: OperationStats()], nanoseconds: nanoseconds, itemCount: itemCount)
            recordSlowEvent(
                SlowEvent(
                    operation: operation,
                    path: path,
                    nanoseconds: nanoseconds,
                    itemCount: itemCount,
                    detail: detail
                )
            )
        }

        private func updateStats(_ stats: inout OperationStats, nanoseconds: UInt64, itemCount: Int?) {
            stats.count += 1
            stats.totalNanoseconds += nanoseconds
            stats.itemCount += itemCount ?? 0
            stats.maxNanoseconds = max(stats.maxNanoseconds, nanoseconds)
        }

        private func recordSlowEvent(_ event: SlowEvent) {
            guard event.nanoseconds >= slowThresholdNanoseconds || slowEvents.count < reportLimit else {
                if let smallest = slowEvents.last, event.nanoseconds > smallest.nanoseconds {
                    slowEvents[slowEvents.count - 1] = event
                    slowEvents.sort { $0.nanoseconds > $1.nanoseconds }
                }
                return
            }

            slowEvents.append(event)
            slowEvents.sort { $0.nanoseconds > $1.nanoseconds }
            if slowEvents.count > reportLimit {
                slowEvents.removeLast(slowEvents.count - reportLimit)
            }
        }

        private func sortedStats(_ stats: [String: OperationStats]) -> [(String, OperationStats)] {
            stats.sorted { first, second in
                if first.value.totalNanoseconds == second.value.totalNanoseconds {
                    return first.key < second.key
                }
                return first.value.totalNanoseconds > second.value.totalNanoseconds
            }
        }

        private static func average(_ totalNanoseconds: UInt64, _ count: Int) -> UInt64 {
            guard count > 0 else { return 0 }
            return totalNanoseconds / UInt64(count)
        }

        private static func pathBucket(for path: String) -> String {
            let components = path.split(separator: "/")
            guard !components.isEmpty else { return "/" }
            return "/" + components.prefix(3).joined(separator: "/")
        }

        private static func format(nanoseconds: UInt64) -> String {
            format(seconds: Double(nanoseconds) / 1_000_000_000)
        }

        private static func format(seconds: Double) -> String {
            String(format: "%.3f", seconds)
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
    }

    private struct AtomicDirectorySummary {
        let allocatedSize: Int64
        let logicalSize: Int64
        let descendantFileCount: Int
        let isAccessible: Bool
        let warnings: [ScanWarning]
        let hardLinkClaims: [HardLinkClaim]
    }

    private struct AtomicSummaryWorkItem: Sendable {
        let url: URL
        let treatPackagesAsDirectories: Bool
        let ownerNodeID: String
    }

    private final class AtomicSummaryWorkQueue: @unchecked Sendable {
        private let condition = NSCondition()
        private var pendingItems: [AtomicSummaryWorkItem]
        private var activeItemCount = 0
        private var failure: Error?

        init(rootItem: AtomicSummaryWorkItem) {
            pendingItems = [rootItem]
        }

        func take() throws -> AtomicSummaryWorkItem? {
            condition.lock()
            defer { condition.unlock() }

            while pendingItems.isEmpty, activeItemCount > 0, failure == nil {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                try Task.checkCancellation()
            }

            if let failure {
                throw failure
            }

            guard let item = pendingItems.popLast() else {
                return nil
            }

            activeItemCount += 1
            return item
        }

        func enqueue(_ item: AtomicSummaryWorkItem) {
            condition.lock()
            pendingItems.append(item)
            condition.signal()
            condition.unlock()
        }

        func finishCurrentItem() {
            condition.lock()
            activeItemCount -= 1
            if pendingItems.isEmpty && activeItemCount == 0 {
                condition.broadcast()
            } else {
                condition.signal()
            }
            condition.unlock()
        }

        func fail(_ error: Error) {
            condition.lock()
            if failure == nil {
                failure = error
            }
            pendingItems.removeAll()
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class AtomicSummaryAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var allocatedSize: Int64 = 0
        private var logicalSize: Int64 = 0
        private var descendantFileCount = 0
        private var isAccessible = true
        private var warnings: [ScanWarning] = []
        private var hardLinkClaims: [HardLinkClaim] = []
        private var visitedItemCount = 0

        func recordVisitedItem() -> Int {
            lock.lock()
            visitedItemCount += 1
            let count = visitedItemCount
            lock.unlock()
            return count
        }

        func updateAccessibility(_ readable: Bool) {
            lock.lock()
            isAccessible = isAccessible && readable
            lock.unlock()
        }

        func recordWarning(for url: URL, error: Error) {
            lock.lock()
            isAccessible = false
            warnings.append(ScanEngine.makeWarning(for: url, error: error))
            lock.unlock()
        }

        func accumulateFile(_ metadata: NodeMetadata, url: URL, ownerNodeID: String) {
            lock.lock()
            allocatedSize += metadata.allocatedSize
            logicalSize += metadata.logicalSize
            if !metadata.isSymbolicLink {
                descendantFileCount += 1
            }
            if let claim = ScanEngine.hardLinkClaim(for: metadata, ownerNodeID: ownerNodeID, path: url.path) {
                hardLinkClaims.append(claim)
            }
            lock.unlock()
        }

        func makeSummary() -> AtomicDirectorySummary {
            lock.lock()
            defer { lock.unlock() }
            return AtomicDirectorySummary(
                allocatedSize: allocatedSize,
                logicalSize: logicalSize,
                descendantFileCount: descendantFileCount,
                isAccessible: isAccessible,
                warnings: warnings,
                hardLinkClaims: hardLinkClaims
            )
        }
    }

    private final class AtomicSummaryProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var metrics: ScanMetrics
        private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
        private var lastEmission = Date.distantPast
        private var hasEmitted = false

        init(
            metrics: ScanMetrics,
            continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
        ) {
            self.metrics = metrics
            self.continuation = continuation
        }

        func emit(currentURL: URL) {
            lock.lock()
            let now = Date()
            guard !hasEmitted || now.timeIntervalSince(lastEmission) >= 0.15 else {
                lock.unlock()
                return
            }

            metrics.currentPath = currentURL.path
            lastEmission = now
            hasEmitted = true
            continuation.yield(.progress(metrics))
            lock.unlock()
        }
    }

    private struct AtomicDirectoryProbeProfile {
        var observedFileCount = 0
        var observedDirectoryCount = 0
        var totalSampledLogicalSize: Int64 = 0
        var observedNodeDependencyLayout = false

        func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
            guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
            return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
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

    private typealias CancellationCheck = @Sendable () throws -> Void

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    private struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let parentKey: Int
        let depth: Int
    }

    /// A child discovered during directory enumeration.
    /// Directory enumeration prefetches resource values, so carrying decoded metadata forward
    /// avoids asking each URL for the same values again when the child is scanned.
    private struct DirectoryEntry: Sendable {
        let url: URL
        let metadata: NodeMetadata?
    }

    private struct DirectoryContentsScanResult: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        let enumerationNanoseconds: UInt64
        let classificationNanoseconds: UInt64
    }

    private enum DirectoryTraversalResult: Sendable {
        case success(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            contents: DirectoryContentsScanResult
        )
        case failure(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning,
            elapsedNanoseconds: UInt64,
            diagnosticDetail: String
        )
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
    ) throws -> [URL]

    private let fileManager = FileManager.default
    private let directoryContents: DirectoryContentsProvider
    private let scanResourceKeys: Set<URLResourceKey> = [
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
    private let rootResourceKeys: Set<URLResourceKey> = [
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
    private static let atomicSummaryResourceKeys: [URLResourceKey] = [
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
    private static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)
    private static let atomicProbeResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey
    ]
    private static let atomicProbeResourceKeySet = Set(atomicProbeResourceKeys)
    private let diagnostics: ScanDiagnostics?

    init(directoryContents: @escaping DirectoryContentsProvider = ScanEngine.defaultDirectoryContents) {
        self.directoryContents = directoryContents
        self.diagnostics = ScanDiagnostics.makeIfEnabled()
    }

    private nonisolated static func defaultDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [URL] {
        var enumerationError: Error?
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
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                )
            },
            enumerationError: { enumerationError }
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
        enumerationError: () -> Error? = { nil }
    ) throws -> [URL] {
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
        return contents
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

    private func performScan(
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
            cloudStorageRootPath: options.cloudStorageRootPath
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
            expectedTotalBytes: exclusionMatcher.hasUserExclusions ? 0 : metrics.estimatedTotalBytes
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        if let diagnostics {
            print(diagnostics.makeReport(targetPath: target.url.path, elapsedSeconds: Date().timeIntervalSince(startedAt)))
        }
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

    /// Scans a directory iteratively (no recursion) and returns a fully assembled flat tree.
    private func scanDirectory(
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

        let rootMetadata = try metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()
        var hardLinkClaims: [HardLinkClaim] = []
        var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
        let atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        let directoryTraversalWorkerLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(for: options)
        let directoryClassificationWorkerLimit = ScanConcurrencyPolicy.directoryClassificationWorkerLimit(for: options)
        let effectiveDirectoryClassificationWorkerLimit = directoryTraversalWorkerLimit > 1
            ? 1
            : directoryClassificationWorkerLimit
        let directoryContentsProvider = directoryContents
        let directoryResourceKeys = scanResourceKeys

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
            applyLeafMetrics(leafResult.node, metrics: &metrics)
            if !leafResult.warnings.isEmpty {
                warnings.append(contentsOf: leafResult.warnings)
                for warning in leafResult.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            continuation.yield(.progress(metrics))
            let rawStore = FileTreeStore(root: leafResult.node)
            return Self.deduplicatedHardLinksStore(
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
        var workStack: [ScanWorkItem] = [
            ScanWorkItem(url: target.url, metadata: rootMetadata, parentKey: -1, depth: 0)
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
                        recordDuplicateNode(
                            at: item.url,
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
                    if let itemMetadata = item.metadata {
                        meta = itemMetadata
                    } else {
                        do {
                            meta = try metadata(for: item.url)
                        } catch {
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
                            let traversalStart = DispatchTime.now().uptimeNanoseconds
                            do {
                                let contents = try await ScanEngine.directoryEntries(
                                    of: taskItem.url,
                                    includeHiddenFiles: options.includeHiddenFiles,
                                    behavior: behavior,
                                    exclusionMatcher: exclusionMatcher,
                                    resourceKeys: directoryResourceKeys,
                                    directoryContents: directoryContentsProvider,
                                    classificationWorkerLimit: effectiveDirectoryClassificationWorkerLimit,
                                    cancellationCheck: cancellationCheck
                                )
                                return .success(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents
                                )
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                return .failure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanEngine.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanEngine.diagnosticErrorDescription(error))"
                                )
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory).
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
                        applyLeafMetrics(leafResult.node, metrics: &metrics)
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
                case .success(let item, let itemKey, let meta, let contents):
                    let childEntries = contents.entries
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

                    metrics.currentPath = item.url.path
                    metrics.discoveredItems += childEntries.count
                    metrics.recalculateProgress()
                    maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

                    // Check if this directory should be summarized as atomic (many small files)
                    let minFileCount = options.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
                    let maxAvgSize = options.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
                    let minDepth = options.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
                    let isNodeDependencyLayout = Self.isNodeDependencyLayoutDirectory(at: item.url)
                    let canProbeForAutoSummary =
                        item.depth >= minDepth ||
                        (item.depth >= 1 && isNodeDependencyLayout)
                    var completedAsAtomicDirectory = false
                    if options.autoSummarizeDirectories,
                       canProbeForAutoSummary,
                       let summary = try await shouldSummarizeAsAtomicDirectory(
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
                        applyLeafMetrics(atomicNode, metrics: &metrics)
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

                    // Enqueue children onto the stack. Each child records its parent key.
                    for (offset, childEntry) in childEntries.enumerated() {
                        if offset.isMultiple(of: 256) {
                            try Task.checkCancellation()
                        }
                        workStack.append(
                            ScanWorkItem(
                                url: childEntry.url,
                                metadata: childEntry.metadata,
                                parentKey: itemKey,
                                depth: item.depth + 1
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

                case .failure(let item, let itemKey, let meta, let warning, let elapsedNanoseconds, let diagnosticDetail):
                    diagnostics?.recordElapsed(
                        operation: "directory.enumerate.error",
                        url: item.url,
                        nanoseconds: elapsedNanoseconds,
                        detail: diagnosticDetail
                    )
                    warnings.append(warning)
                    continuation.yield(.warning(warning))
                    metrics.completedItems += 1
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
        let finalizationStart = diagnostics?.start()
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
                metrics.recalculateProgress()
                continuation.yield(.progress(metrics))
            }
        }
        diagnostics?.record(
            operation: "scan.finalize",
            url: target.url,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )

        guard let rootNode = resolvedNodeByKey[0] else {
            throw ScanEngineError.missingRootNode
        }

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        return Self.deduplicatedHardLinksStore(
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

    private func applyLeafMetrics(_ node: FileNodeRecord, metrics: inout ScanMetrics) {
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
    }

    private nonisolated static func hardLinkClaim(
        for metadata: NodeMetadata,
        ownerNodeID: String,
        path: String
    ) -> HardLinkClaim? {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.linkCount > 1,
              let fileIdentity = metadata.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: ownerNodeID,
            path: path,
            allocatedSize: metadata.allocatedSize
        )
    }

    private nonisolated static func deduplicatedHardLinksStore(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) -> FileTreeStore {
        let duplicateAllocatedSizeByOwner = duplicateHardLinkAllocatedSizeByOwner(from: hardLinkClaims)
        guard !duplicateAllocatedSizeByOwner.isEmpty else {
            return FileTreeStore(
                rootID: rootID,
                nodesByID: inputNodesByID,
                childIDsByID: inputChildIDsByID,
                parentIDByID: parentIDByID,
                aggregateStats: aggregateStats
            )
        }

        var nodesByID = inputNodesByID
        var childIDsByID = inputChildIDsByID

        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            guard let node = nodesByID[nodeID] else { continue }
            let minimumAllocatedSize = minimumAllocatedSizeByNodeID[nodeID] ?? 0
            let allocatedSize = max(minimumAllocatedSize, node.allocatedSize - duplicateAllocatedSize)
            nodesByID[nodeID] = node.replacingAllocatedSize(allocatedSize)
        }

        let orderedNodeIDs = orderedNodeIDs(rootID: rootID, childIDsByID: childIDsByID, nodesByID: nodesByID)
        for nodeID in orderedNodeIDs.reversed() where childIDsByID[nodeID] != nil {
            guard let node = nodesByID[nodeID], node.isDirectory else { continue }
            let children = (childIDsByID[nodeID] ?? []).compactMap { nodesByID[$0] }
            let sortedChildren = FileTreeStore.sortedChildren(children)
            nodesByID[nodeID] = FileNodeRecord.directory(
                id: node.id,
                url: node.url,
                name: node.name,
                children: sortedChildren,
                lastModified: node.lastModified,
                isPackage: node.isPackage,
                isAccessible: node.isSelfAccessible,
                childrenAreSorted: true
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
        }

        let root = nodesByID[rootID] ?? inputNodesByID[rootID]
        let deduplicatedStats = ScanAggregateStats(
            totalAllocatedSize: root?.allocatedSize ?? aggregateStats.totalAllocatedSize,
            totalLogicalSize: root?.logicalSize ?? aggregateStats.totalLogicalSize,
            fileCount: aggregateStats.fileCount,
            directoryCount: aggregateStats.directoryCount,
            accessibleItemCount: aggregateStats.accessibleItemCount,
            inaccessibleItemCount: aggregateStats.inaccessibleItemCount
        )

        return FileTreeStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            aggregateStats: deduplicatedStats
        )
    }

    private nonisolated static func duplicateHardLinkAllocatedSizeByOwner(
        from claims: [HardLinkClaim]
    ) -> [String: Int64] {
        let claimsByIdentity = Dictionary(grouping: claims.filter { $0.allocatedSize > 0 }, by: \.identity)
        var duplicateAllocatedSizeByOwner: [String: Int64] = [:]

        for identityClaims in claimsByIdentity.values where identityClaims.count > 1 {
            let sortedClaims = identityClaims.sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.ownerNodeID < rhs.ownerNodeID
                }
                return lhs.path < rhs.path
            }

            for duplicateClaim in sortedClaims.dropFirst() {
                duplicateAllocatedSizeByOwner[duplicateClaim.ownerNodeID, default: 0] += duplicateClaim.allocatedSize
            }
        }

        return duplicateAllocatedSizeByOwner
    }

    private nonisolated static func orderedNodeIDs(
        rootID: String,
        childIDsByID: [String: [String]],
        nodesByID: [String: FileNodeRecord]
    ) -> [String] {
        guard nodesByID[rootID] != nil else { return [] }
        var result: [String] = []
        var stack = [rootID]
        var visited: Set<String> = []

        while let nodeID = stack.popLast() {
            guard nodesByID[nodeID] != nil, visited.insert(nodeID).inserted else { continue }
            result.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
        }

        return result
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

    private func insertNode(
        _ node: FileNodeRecord,
        into nodesByID: inout [String: FileNodeRecord],
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) -> Bool {
        guard nodesByID[node.id] == nil else {
            let warning = Self.makeDuplicateNodeWarning(for: node.url)
            warnings.append(warning)
            continuation.yield(.warning(warning))
            return false
        }

        nodesByID[node.id] = node
        return true
    }

    private func recordDuplicateNode(
        at url: URL,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        let warning = Self.makeDuplicateNodeWarning(for: url)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)
    }

    private nonisolated static func makeDuplicateNodeWarning(for url: URL) -> ScanWarning {
        ScanWarning(
            path: url.path,
            message: "A duplicate filesystem path was collapsed in the scan results.",
            category: .fileSystem
        )
    }

    private nonisolated static func diagnosticErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    private func recordUnavailableItem(
        _ item: ScanWorkItem,
        itemKey: Int,
        error: Error,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        completedByKey: inout [Int: CompletedDirScan]
    ) {
        let warning = makeWarning(for: item.url, error: error)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.recalculateProgress()
        maybeEmitProgress(metrics: metrics, continuation: continuation, emissionState: &emissionState)

        completedByKey[itemKey] = CompletedDirScan(
            node: makeUnavailableNode(for: item.url),
            metadata: NodeMetadata(
                isDirectory: item.url.hasDirectoryPath,
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

    private func makeUnavailableNode(for url: URL) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: url.hasDirectoryPath,
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

    private func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? rootResourceKeys : scanResourceKeys
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
                detail: "error=\(Self.diagnosticErrorDescription(error))"
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

    private nonisolated static func nodeMetadata(
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
            return (nil, 0)
        }

        return (
            FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            UInt64(fileStat.st_nlink)
        )
    }

    private nonisolated static func fileIdentity(
        from resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> FileIdentity? {
        guard let identifierData = resourceIdentifier as? Data else { return nil }
        return FileIdentity(resourceIdentifier: identifierData)
    }

    private nonisolated static func directoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
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
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        let contents = try directoryContents(url, prefetchKeys, options, cancellationCheck)
        let enumerationNanoseconds = DispatchTime.now().uptimeNanoseconds - enumerationStart
        try cancellationCheck()

        let classificationStart = DispatchTime.now().uptimeNanoseconds
        let entries = try await Self.classifiedDirectoryEntries(
            contents,
            under: url,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: resourceKeys,
            workerLimit: classificationWorkerLimit,
            cancellationCheck: cancellationCheck
        )
        let classificationNanoseconds = DispatchTime.now().uptimeNanoseconds - classificationStart

        try cancellationCheck()
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: contents.count,
            enumerationNanoseconds: enumerationNanoseconds,
            classificationNanoseconds: classificationNanoseconds
        )
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
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

            let childMetadata = try? nodeMetadata(
                for: childURL,
                resourceValues: childURL.resourceValues(forKeys: resourceKeys)
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

    private func makeFileNode(
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

    private func makeLeafNode(
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
                Self.hardLinkClaim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                nil
            )
        }

        guard let summary = try await summarizeAtomicDirectory(
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
                Self.hardLinkClaim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
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

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    private func shouldSummarizeAsAtomicDirectory(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        guard !childEntries.isEmpty else { return nil }

        let immediateCandidate: Bool
        if childEntries.count >= minFileCount {
            immediateCandidate = try immediateChildrenSuggestAtomicDirectory(
                childEntries,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck
            )
        } else {
            immediateCandidate = false
        }

        let deepCandidate: Bool
        if immediateCandidate {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return nil
            }
            let profile = try descendantAtomicProbeProfile(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
        }

        guard deepCandidate else {
            return nil
        }

        // Sample suggests atomic treatment - do a fast full summary
        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            return try await summarizeAtomicDirectory(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: url.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        guard let summary = try await summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else { return nil }
        return summary
    }

    private func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        guard childEntries.contains(where: { childEntry in
            childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
        }) else {
            return false
        }

        // Sparse parents are cheaper to traverse normally; dense descendants can still summarize themselves.
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return childEntries.count >= minimumImmediateEntries
    }

    private func immediateChildrenSuggestAtomicDirectory(
        _ childEntries: [DirectoryEntry],
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        try cancellationCheck()
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
            try cancellationCheck()
            let childEntry = childEntries[index]
            guard let childMetadata = childEntry.metadata else {
                return false
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
                sampleFileCount += 1
            }
        }

        guard sampleFileCount > 0 else { return false }
        return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
    }

    private func descendantAtomicProbeProfile(
        at url: URL,
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()
        let probeStart = diagnostics?.start()
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        defer {
            diagnostics?.record(
                operation: "atomic.probe",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.atomicProbeResourceKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return profile
        }

        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else { return profile }

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let values = try childURL.resourceValues(forKeys: Self.atomicProbeResourceKeySet)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                if exclusionMatcher.excludes(childURL, isDirectory: isDirectory) {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if Self.isNodeDependencyLayoutDirectory(at: childURL) {
                    profile.observedNodeDependencyLayout = true
                }

                guard !isDirectory else {
                    profile.observedDirectoryCount += 1
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize += Int64(values.fileSize ?? 0)
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return profile
                }
            } catch {
                return profile
            }
        }

        return profile
    }

    private nonisolated static func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@") else { return false }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    private func summarizeAtomicDirectory(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        let summaryStart = diagnostics?.start()
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)
        defer {
            diagnostics?.record(
                operation: "atomic.summary.reused_entries",
                url: url,
                startedAt: summaryStart,
                itemCount: childEntries.count,
                detail: "files=\(state.descendantFileCount)"
            )
        }

        for (index, childEntry) in childEntries.enumerated() {
            try cancellationCheck()
            if index == 0 || index.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childEntry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            guard !exclusionMatcher.excludes(
                childEntry.url,
                isDirectory: childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            try await accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        return makeAtomicSummary(from: state)
    }

    private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else { return }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try await summarizeAtomicDirectory(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: state.ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        accumulateAtomicFile(metadata, url: url, into: state)
    }

    private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += summary.allocatedSize
        state.logicalSize += summary.logicalSize
        state.descendantFileCount += summary.descendantFileCount
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
        state.hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    private func summarizeAtomicDirectory(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        if workerLimit > 1 {
            let summaryStart = diagnostics?.start()
            let summary = try await Self.summarizeAtomicDirectoryInParallel(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                progressReporter: AtomicSummaryProgressReporter(
                    metrics: metrics,
                    continuation: continuation
                )
            )
            diagnostics?.record(
                operation: "atomic.summary.parallel",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount,
                detail: "workers=\(workerLimit)"
            )
            return summary
        }

        let summaryStart = diagnostics?.start()
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        var visitedItems = 0
        defer {
            diagnostics?.record(
                operation: "atomic.summary.enumerate",
                url: url,
                startedAt: summaryStart,
                itemCount: visitedItems,
                detail: "files=\(state.descendantFileCount)"
            )
        }

        do {
            try cancellationCheck()
            let rootValues = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            updateAtomicAccessibility(rootValues.isReadable ?? false, in: state)
        } catch {
            recordAtomicWarning(for: url, error: error, in: state)
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.atomicSummaryResourceKeys,
            options: enumeratorOptions,
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(Self.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let childMetadata = try atomicSummaryMetadata(for: childURL)
                if exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) {
                    if childMetadata.isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                try await accumulateEnumeratedAtomicSummary(
                    for: childURL,
                    metadata: childMetadata,
                    into: state,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState,
                    skipDescendants: {
                        enumerator.skipDescendants()
                    }
                )
            } catch {
                recordAtomicWarning(for: childURL, error: error, in: state)
            }
        }

        return makeAtomicSummary(from: state)
    }

    private nonisolated static func summarizeAtomicDirectoryInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        progressReporter: AtomicSummaryProgressReporter
    ) async throws -> AtomicDirectorySummary? {
        try Task.checkCancellation()

        let accumulator = AtomicSummaryAccumulator()
        do {
            let rootValues = try url.resourceValues(forKeys: atomicSummaryResourceKeySet)
            accumulator.updateAccessibility(rootValues.isReadable ?? false)
        } catch {
            accumulator.recordWarning(for: url, error: error)
        }

        let queue = AtomicSummaryWorkQueue(
            rootItem: AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: ownerNodeID
            )
        )
        let workerCount = max(1, workerLimit)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        guard let item = try queue.take() else { return }

                        do {
                            try Self.processAtomicSummaryWorkItem(
                                item,
                                includeHiddenFiles: includeHiddenFiles,
                                exclusionMatcher: exclusionMatcher,
                                accumulator: accumulator,
                                queue: queue,
                                progressReporter: progressReporter
                            )
                            queue.finishCurrentItem()
                        } catch {
                            queue.fail(error)
                            queue.finishCurrentItem()
                            throw error
                        }
                    }
                }
            }

            do {
                try await group.waitForAll()
            } catch {
                queue.fail(error)
                group.cancelAll()
                throw error
            }
        }

        return accumulator.makeSummary()
    }

    private nonisolated static func processAtomicSummaryWorkItem(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        accumulator: AtomicSummaryAccumulator,
        queue: AtomicSummaryWorkQueue,
        progressReporter: AtomicSummaryProgressReporter
    ) throws {
        try Task.checkCancellation()

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let childURLs: [URL]
        do {
            childURLs = try enumeratedDirectoryContents(
                url: item.url,
                keys: atomicSummaryResourceKeys,
                options: options,
                cancellationCheck: { try Task.checkCancellation() },
                makeEnumerator: { url, keys, options in
                    FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: options,
                        errorHandler: { childURL, error in
                            accumulator.recordWarning(for: childURL, error: error)
                            return true
                        }
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accumulator.recordWarning(for: item.url, error: error)
            return
        }

        for childURL in childURLs {
            try Task.checkCancellation()
            let visitedItemCount = accumulator.recordVisitedItem()
            if visitedItemCount == 1 || visitedItemCount.isMultiple(of: 64) {
                progressReporter.emit(currentURL: childURL)
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            guard !exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(forKeys: atomicSummaryResourceKeySet)
                childMetadata = nodeMetadata(for: childURL, resourceValues: values)
            } catch {
                accumulator.recordWarning(for: childURL, error: error)
                continue
            }

            guard !exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) else {
                continue
            }

            accumulator.updateAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                accumulator.accumulateFile(childMetadata, url: childURL, ownerNodeID: item.ownerNodeID)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            queue.enqueue(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }

    private func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
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
                detail: "error=\(Self.diagnosticErrorDescription(error))"
            )
            throw error
        }
        return Self.nodeMetadata(for: url, resourceValues: values, diagnostics: diagnostics)
    }

    private func accumulateEnumeratedAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        skipDescendants: () -> Void
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else {
            if metadata.isDirectory {
                skipDescendants()
            }
            return
        }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        guard metadata.isDirectory else {
            accumulateAtomicFile(metadata, url: url, into: state)
            return
        }

        guard metadata.isPackage, !treatPackagesAsDirectories else { return }

        if let packageSummary = try await summarizeAtomicDirectory(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: workerLimit,
            ownerNodeID: state.ownerNodeID,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) {
            merge(packageSummary, into: state)
            skipDescendants()
        }
    }

    private func updateAtomicAccessibility(_ isReadable: Bool, in state: AtomicDirectorySummaryState) {
        state.isAccessible = state.isAccessible && isReadable
    }

    private func recordAtomicWarning(
        for url: URL,
        error: Error,
        in state: AtomicDirectorySummaryState
    ) {
        state.isAccessible = false
        state.warnings.append(Self.makeWarning(for: url, error: error))
    }

    private func accumulateAtomicFile(_ metadata: NodeMetadata, url: URL, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += metadata.allocatedSize
        state.logicalSize += metadata.logicalSize

        if !metadata.isSymbolicLink {
            state.descendantFileCount += 1
        }

        if let claim = Self.hardLinkClaim(for: metadata, ownerNodeID: state.ownerNodeID, path: url.path) {
            state.hardLinkClaims.append(claim)
        }
    }

    private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings,
            hardLinkClaims: state.hardLinkClaims
        )
    }

    private func makeSnapshot(
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

    private func reconcileVolumeRoot(_ treeStore: FileTreeStore, for target: ScanTarget, expectedTotalBytes: Int64) -> FileTreeStore {
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

    private func maybeEmitProgress(
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

    private func emitProgressHeartbeat(
        currentURL: URL,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        metrics.currentPath = currentURL.path
        let now = Date()
        guard now.timeIntervalSince(emissionState.lastProgressEmission) >= 0.15 else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }

    private func shouldTraverseDirectory(metadata: NodeMetadata, options: ScanOptions) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        return !metadata.isPackage || options.treatPackagesAsDirectories
    }

    private func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        if target.kind == .volume, let volumeUsedCapacity = metadata.volumeUsedCapacity {
            return max(volumeUsedCapacity, metadata.allocatedSize)
        }
        return max(metadata.allocatedSize, 0)
    }

    private nonisolated static func makeWarning(for url: URL, error: Error) -> ScanWarning {
        let nsError = error as NSError
        let category: ScanWarningCategory

        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileReadNoPermissionError {
            category = .permissionDenied
        } else if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == EACCES || nsError.code == EPERM) {
            category = .permissionDenied
        } else {
            category = .fileSystem
        }

        return ScanWarning(
            path: url.path,
            message: nsError.localizedDescription,
            category: category
        )
    }

    private func makeWarning(for url: URL, error: Error) -> ScanWarning {
        Self.makeWarning(for: url, error: error)
    }
}

extension FileManager.DirectoryEnumerator: nonisolated ScanEngine.DirectoryObjectEnumerating {}

nonisolated private struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}

nonisolated private enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64)

    nonisolated init(device: UInt64, inode: UInt64) {
        self = .fileSystem(device: device, inode: inode)
    }

    nonisolated init(resourceIdentifier: Data) {
        self = .resourceIdentifier(resourceIdentifier)
    }
}

private extension FileNodeRecord {
    nonisolated func replacingAllocatedSize(_ allocatedSize: Int64) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }
}

private struct NodeMetadata: Sendable {
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

private struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
