//
//  IncrementalScanService.swift
//  Radix
//

import Foundation
import OSLog

/// Adds conservative FSEvents-based rescans around the ordinary scan engine.
/// Any uncertainty delegates to a full scan; partial subtree results are never
/// published before the complete batch splice succeeds.
nonisolated final class IncrementalScanService: ScanEventStreaming, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.colinkim.Radix",
        category: "IncrementalScan"
    )

    private enum IncrementalRescanEligibility {
        case eligible(ScanIncrementalCheckpoint)
        case ineligible(IncrementalRescanFallbackReason)
    }

    private enum ShallowRelistError: Error {
        case invalidDirectory
        case incompleteMetadata
        case duplicateEntry
        case identityChanged
    }

    private struct ShallowReplacement: Sendable {
        let directoryID: String
        let treeStore: FileTreeStore
        let warnings: [ScanWarning]
    }

    private let engine: ScanEngine
    private let eventHistoryProvider: any FileSystemEventHistoryProviding
    private let planner: IncrementalRescanPlanner

    init(
        engine: ScanEngine = ScanEngine(),
        eventHistoryProvider: any FileSystemEventHistoryProviding = DarwinFileSystemEventHistoryProvider(),
        planner: IncrementalRescanPlanner = IncrementalRescanPlanner()
    ) {
        self.engine = engine
        self.eventHistoryProvider = eventHistoryProvider
        self.planner = planner
    }

    nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        fullScan(target: target, options: options, executionMode: .full)
    }

    nonisolated func scanSubtree(
        target: ScanTarget,
        preservingBehaviorOf scanTarget: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        engine.scan(
            target: target,
            options: options,
            preservingBehaviorOf: scanTarget
        )
    }

    private nonisolated func fullScan(
        target: ScanTarget,
        options: ScanOptions,
        executionMode: ScanExecutionMode
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                continuation.yield(.executionMode(executionMode))

                let checkpoint: ScanIncrementalCheckpoint?
                do {
                    checkpoint = try self.eventHistoryProvider.currentCheckpoint(for: target.url)
                } catch {
                    checkpoint = nil
                    Self.logger.info(
                        "Incremental checkpoint unavailable: \(error, privacy: .private)"
                    )
                }

                do {
                    try Task.checkCancellation()
                    for try await event in self.engine.scan(target: target, options: options) {
                        if case .finished(let snapshot) = event {
                            continuation.yield(.finished(self.snapshot(
                                snapshot,
                                checkpoint: checkpoint
                            )))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        from baseline: ScanSnapshot
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let previousCheckpoint: ScanIncrementalCheckpoint
                    switch self.incrementalRescanEligibility(
                        baseline,
                        target: target,
                        options: options
                    ) {
                    case .eligible(let checkpoint):
                        previousCheckpoint = checkpoint
                    case .ineligible(let reason):
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            reason: reason,
                            continuation: continuation
                        )
                        return
                    }

                    let cutoff: ScanIncrementalCheckpoint
                    let history: FileSystemEventHistory
                    do {
                        cutoff = try self.eventHistoryProvider.currentCheckpoint(for: target.url)
                        history = try await self.eventHistoryProvider.history(
                            for: target.url,
                            since: previousCheckpoint,
                            through: cutoff
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            reason: .eventHistoryUnavailable,
                            diagnostic: String(describing: error),
                            continuation: continuation
                        )
                        return
                    }

                    let matcher = ScanExclusionMatcher(
                        patterns: options.exclusionPatterns,
                        rootPath: options.exclusionRootPath ?? target.url.path
                    )
                    switch self.planner.plan(
                        history: history,
                        target: target,
                        treeStore: baseline.treeStore,
                        exclusionMatcher: matcher
                    ) {
                    case .fullScan(let reason):
                        try await self.forwardFullScan(
                            target: target,
                            options: options,
                            reason: reason,
                            continuation: continuation
                        )
                    case .noChanges:
                        continuation.yield(.executionMode(.incrementalNoChanges))
                        let finished = self.refreshedSnapshot(
                            baseline,
                            checkpoint: cutoff,
                            startedAt: Date()
                        )
                        continuation.yield(.finished(finished))
                        continuation.finish()
                    case .update(let relistDirectoryIDs, let rescanSubtreeIDs):
                        continuation.yield(.executionMode(.incremental))
                        try await self.performIncrementalScan(
                            target: target,
                            options: options,
                            baseline: baseline,
                            cutoff: cutoff,
                            relistDirectoryIDs: relistDirectoryIDs,
                            rescanSubtreeIDs: rescanSubtreeIDs,
                            continuation: continuation
                        )
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private nonisolated func performIncrementalScan(
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot,
        cutoff: ScanIncrementalCheckpoint,
        relistDirectoryIDs: [String],
        rescanSubtreeIDs: [String],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        let startedAt = Date()
        var replacements: [String: FileTreeStore] = [:]
        var replacementWarnings: [ScanWarning] = []
        let updateCount = relistDirectoryIDs.count + rescanSubtreeIDs.count
        var completedRelists = 0
        var subtreeOptions = options
        if subtreeOptions.exclusionRootPath == nil {
            subtreeOptions.exclusionRootPath = target.url.path
        }
        let relistOptions = subtreeOptions

        do {
            try await withThrowingTaskGroup(of: ShallowReplacement.self) { group in
                let workerLimit = min(
                    ScanEngine.shallowRelistWorkerLimit(for: relistOptions),
                    relistDirectoryIDs.count
                )
                let classificationWorkerLimit = ScanEngine.shallowRelistClassificationWorkerLimit(
                    for: relistOptions,
                    relistWorkerLimit: workerLimit
                )
                var nextIndex = 0
                func addNextRelist() {
                    guard nextIndex < relistDirectoryIDs.count else { return }
                    let nodeID = relistDirectoryIDs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.shallowReplacement(
                            directoryID: nodeID,
                            target: target,
                            options: relistOptions,
                            baseline: baseline,
                            classificationWorkerLimit: classificationWorkerLimit
                        )
                    }
                }
                for _ in 0..<workerLimit {
                    addNextRelist()
                }
                while let replacement = try await group.next() {
                    replacements[replacement.directoryID] = replacement.treeStore
                    replacementWarnings.append(contentsOf: replacement.warnings)
                    completedRelists += 1
                    var metrics = ScanMetrics()
                    metrics.currentPath = replacement.directoryID
                    metrics.discoveredItems = updateCount
                    metrics.completedItems = completedRelists
                    metrics.directoriesVisited = completedRelists
                    metrics.progressFraction = min(
                        Double(completedRelists) / Double(max(updateCount, 1)) * 0.95,
                        0.95
                    )
                    continuation.yield(.progress(metrics))
                    addNextRelist()
                }
            }
            for warning in replacementWarnings {
                continuation.yield(.warning(warning))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await forwardFullScan(
                target: target,
                options: options,
                reason: .directoryRelistFailed,
                diagnostic: String(describing: error),
                continuation: continuation
            )
            return
        }

        var completedSubtreeFiles = 0
        var completedSubtreeDirectories = 0
        for (subtreeIndex, nodeID) in rescanSubtreeIDs.enumerated() {
            try Task.checkCancellation()
            guard let node = baseline.treeStore.node(id: nodeID) else {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .changedSubtreeUnavailable,
                    continuation: continuation
                )
                return
            }
            var replacementSnapshot: ScanSnapshot?
            var subtreeFilesVisited = 0
            var subtreeDirectoriesVisited = 0
            let adjustedSubtreeOptions = ScanEngine.subtreeScanOptions(
                subtreeOptions,
                at: node.url,
                scanTarget: target
            )
            do {
                for try await event in engine.scan(
                    target: ScanTarget(url: node.url),
                    options: adjustedSubtreeOptions
                ) {
                    switch event {
                    case .executionMode:
                        break
                    case .progress(var metrics):
                        subtreeFilesVisited = max(subtreeFilesVisited, metrics.filesVisited)
                        subtreeDirectoriesVisited = max(
                            subtreeDirectoriesVisited,
                            metrics.directoriesVisited
                        )
                        metrics.filesVisited += completedSubtreeFiles
                        metrics.directoriesVisited += relistDirectoryIDs.count
                            + completedSubtreeDirectories
                        let localFraction = min(max(metrics.progressFraction, 0), 1)
                        metrics.progressFraction = min(
                            (
                                Double(relistDirectoryIDs.count + subtreeIndex)
                                    + localFraction
                            ) / Double(max(updateCount, 1)) * 0.95,
                            0.95
                        )
                        continuation.yield(.progress(metrics))
                    case .warning(let warning):
                        continuation.yield(.warning(warning))
                    case .finished(let snapshot):
                        replacementSnapshot = snapshot
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeRescanFailed,
                    diagnostic: String(describing: error),
                    continuation: continuation
                )
                return
            }
            guard let replacement = replacementSnapshot else {
                try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeResultUnavailable,
                    continuation: continuation
                )
                return
            }
            replacements[nodeID] = replacement.treeStore
            replacementWarnings.append(contentsOf: replacement.scanWarnings)
            completedSubtreeFiles += subtreeFilesVisited
            completedSubtreeDirectories += subtreeDirectoriesVisited
        }

        try Task.checkCancellation()
        let spliced: ScanSnapshot?
        do {
            spliced = try baseline.replacingSubtrees(
                replacements,
                additionalWarnings: replacementWarnings,
                cancellationCheck: { try Task.checkCancellation() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await forwardFullScan(
                target: target,
                options: options,
                reason: .treeUpdateFailed,
                diagnostic: String(describing: error),
                continuation: continuation
            )
            return
        }
        guard let spliced else {
            try await forwardFullScan(
                target: target,
                options: options,
                reason: .treeUpdateFailed,
                continuation: continuation
            )
            return
        }
        let finished = ScanSnapshot(
            target: target,
            treeStore: spliced.treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: spliced.scanWarnings,
            isComplete: true,
            scanOptions: options,
            volumeCapacity: baseline.volumeCapacity,
            source: .live,
            incrementalCheckpoint: cutoff
        )
        continuation.yield(.finished(finished))
        continuation.finish()
    }

    private nonisolated func shallowReplacement(
        directoryID: String,
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot,
        classificationWorkerLimit: Int
    ) async throws -> ShallowReplacement {
        guard let originalRoot = baseline.treeStore.node(id: directoryID),
              originalRoot.isDirectory,
              !originalRoot.isSymbolicLink else {
            throw ShallowRelistError.invalidDirectory
        }
        if ScanEngine.requiresDeepScanForAutoSummary(
            at: originalRoot.url,
            scanTarget: target,
            options: options
        ) {
            let replacement = try await scannedReplacement(
                at: originalRoot.url,
                scanTarget: target,
                options: options
            )
            return ShallowReplacement(
                directoryID: directoryID,
                treeStore: replacement.treeStore,
                warnings: replacement.scanWarnings
            )
        }
        let listing = try await engine.shallowDirectoryListing(
            at: originalRoot.url,
            scanTarget: target,
            options: options,
            classificationWorkerLimit: classificationWorkerLimit
        )
        guard listing.directoryMetadata.fileIdentity != nil,
              listing.directoryMetadata.fileIdentity == originalRoot.fileIdentity else {
            throw ShallowRelistError.identityChanged
        }

        var currentChildIDs = Set<String>()
        currentChildIDs.reserveCapacity(listing.entries.count)
        var preservedSubtreeIDs = Set<String>()
        var childSubtrees: [FileTreeStore.SubtreeSource] = []
        childSubtrees.reserveCapacity(listing.entries.count)
        var replacementWarnings: [ScanWarning] = []

        for entry in listing.entries {
            try Task.checkCancellation()
            guard entry.localizedEnumerationError == nil,
                  let metadata = entry.metadata else {
                throw ShallowRelistError.incompleteMetadata
            }
            let childID = entry.url.path
            guard currentChildIDs.insert(childID).inserted else {
                throw ShallowRelistError.duplicateEntry
            }

            if canPreserveDirectory(
                baselineNode: baseline.treeStore.node(id: childID),
                metadata: metadata
            ) {
                guard let subtree = FileTreeStore.SubtreeSource(
                    store: baseline.treeStore,
                    rootedAt: childID
                ) else {
                    throw ShallowRelistError.incompleteMetadata
                }
                childSubtrees.append(subtree)
                preservedSubtreeIDs.insert(childID)
                continue
            }

            if metadata.isDirectory, !metadata.isSymbolicLink {
                let childSnapshot = try await scannedReplacement(
                    at: entry.url,
                    scanTarget: target,
                    options: options
                )
                guard childSnapshot.treeStore.rootID == childID,
                      let subtree = FileTreeStore.SubtreeSource(
                          store: childSnapshot.treeStore,
                          rootedAt: childID
                      ) else {
                    throw ShallowRelistError.incompleteMetadata
                }
                childSubtrees.append(subtree)
                replacementWarnings.append(contentsOf: childSnapshot.scanWarnings)
            } else {
                let child = engine.makeFileNode(
                    url: entry.url,
                    metadata: metadata
                )
                childSubtrees.append(FileTreeStore.SubtreeSource(node: child))
            }
        }

        childSubtrees.sort {
            FileTreeStore.areInDisplayOrder($0.root, $1.root)
        }
        let children = childSubtrees.map(\.root)
        guard children.count == currentChildIDs.count else {
            throw ShallowRelistError.incompleteMetadata
        }
        let replacementRoot = FileNodeRecord.directory(
            id: directoryID,
            url: originalRoot.url,
            name: originalRoot.name,
            children: children,
            lastModified: listing.directoryMetadata.lastModified,
            fileIdentity: listing.directoryMetadata.fileIdentity,
            linkCount: listing.directoryMetadata.linkCount,
            isPackage: listing.directoryMetadata.isPackage,
            isAccessible: listing.directoryMetadata.isReadable
        )
        replacementWarnings.append(contentsOf: baseline.scanWarnings.filter { warning in
            preservedSubtreeIDs.contains { subtreeID in
                Self.path(warning.path, isContainedIn: subtreeID)
            }
        })
        return ShallowReplacement(
            directoryID: directoryID,
            treeStore: try FileTreeStore.combining(
                root: replacementRoot,
                childSubtrees: childSubtrees,
                cancellationCheck: { try Task.checkCancellation() }
            ),
            warnings: replacementWarnings
        )
    }

    private nonisolated func scannedReplacement(
        at url: URL,
        scanTarget: ScanTarget,
        options: ScanOptions
    ) async throws -> ScanSnapshot {
        var snapshot: ScanSnapshot?
        let adjustedOptions = ScanEngine.subtreeScanOptions(
            options,
            at: url,
            scanTarget: scanTarget
        )
        for try await event in engine.scan(
            target: ScanTarget(url: url),
            options: adjustedOptions
        ) {
            switch event {
            case .finished(let finished):
                snapshot = finished
            case .executionMode, .progress, .warning:
                break
            }
        }
        guard let snapshot else { throw ShallowRelistError.invalidDirectory }
        return snapshot
    }

    private nonisolated func canPreserveDirectory(
        baselineNode: FileNodeRecord?,
        metadata: NodeMetadata
    ) -> Bool {
        guard let baselineNode,
              baselineNode.isDirectory,
              !baselineNode.isSymbolicLink,
              metadata.isDirectory,
              !metadata.isSymbolicLink,
              baselineNode.isPackage == metadata.isPackage,
              baselineNode.isSelfAccessible == metadata.isReadable,
              let fileIdentity = metadata.fileIdentity,
              baselineNode.fileIdentity == fileIdentity else {
            return false
        }
        return true
    }

    private nonisolated static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private nonisolated func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        reason: IncrementalRescanFallbackReason,
        diagnostic: String? = nil,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        if let diagnostic {
            Self.logger.notice(
                "Incremental rescan fallback: \(reason.rawValue, privacy: .public); detail: \(diagnostic, privacy: .private)"
            )
        } else {
            Self.logger.notice(
                "Incremental rescan fallback: \(reason.rawValue, privacy: .public)"
            )
        }
        for try await event in fullScan(
            target: target,
            options: options,
            executionMode: .fullFallback(reason)
        ) {
            continuation.yield(event)
        }
        continuation.finish()
    }

    private nonisolated func incrementalRescanEligibility(
        _ baseline: ScanSnapshot,
        target: ScanTarget,
        options: ScanOptions
    ) -> IncrementalRescanEligibility {
        // Whole-volume accounting must capture capacity and rebuild its synthetic
        // unattributed remainder as one consistent scan-time snapshot.
        guard baseline.isComplete else {
            return .ineligible(.incompleteBaseline)
        }
        guard baseline.source.allowsFileMutation else {
            return .ineligible(.readOnlyBaseline)
        }
        guard target.kind != .volume else {
            return .ineligible(.volumeTarget)
        }
        guard baseline.target.kind == target.kind,
              baseline.target.url.standardizedFileURL.path == target.url.standardizedFileURL.path else {
            return .ineligible(.changedTarget)
        }
        guard baseline.scanOptions == options else {
            return .ineligible(.changedScanOptions)
        }
        guard let checkpoint = baseline.incrementalCheckpoint else {
            return .ineligible(.checkpointUnavailable)
        }
        guard let baselineIdentity = baseline.root.fileIdentity else {
            return .eligible(checkpoint)
        }

        let liveIdentity: FileIdentity
        do {
            guard let identity = try ScanMetadataLoader().metadata(for: target.url).fileIdentity else {
                return .ineligible(.targetIdentityUnavailable)
            }
            liveIdentity = identity
        } catch {
            return .ineligible(.targetIdentityUnavailable)
        }
        guard liveIdentity == baselineIdentity else {
            return .ineligible(.targetIdentityChanged)
        }
        return .eligible(checkpoint)
    }

    private nonisolated func snapshot(
        _ snapshot: ScanSnapshot,
        checkpoint: ScanIncrementalCheckpoint?
    ) -> ScanSnapshot {
        ScanSnapshot(
            id: snapshot.id,
            target: snapshot.target,
            treeStore: snapshot.treeStore,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            scanWarnings: snapshot.scanWarnings,
            isComplete: snapshot.isComplete,
            scanOptions: snapshot.scanOptions,
            volumeCapacity: snapshot.volumeCapacity,
            source: snapshot.source,
            incrementalCheckpoint: checkpoint
        )
    }

    private nonisolated func refreshedSnapshot(
        _ snapshot: ScanSnapshot,
        checkpoint: ScanIncrementalCheckpoint,
        startedAt: Date
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: snapshot.target,
            treeStore: snapshot.treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: snapshot.scanWarnings,
            isComplete: true,
            scanOptions: snapshot.scanOptions,
            volumeCapacity: snapshot.volumeCapacity,
            source: .live,
            incrementalCheckpoint: checkpoint
        )
    }
}
