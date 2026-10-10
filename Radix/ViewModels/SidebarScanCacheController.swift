//
//  SidebarScanCacheController.swift
//  Radix
//

import Foundation

nonisolated struct ScanCacheKey: Hashable, Sendable {
    let targetID: String
    let options: ScanOptions

    init(target: ScanTarget, options: ScanOptions) {
        targetID = target.id
        self.options = options
    }
}

private nonisolated struct ScanCacheSnapshotVersion: Equatable {
    let id: UUID
    let contentID: UUID
    let checkpoint: ScanIncrementalCheckpoint?

    init(_ snapshot: ScanSnapshot) {
        id = snapshot.id
        contentID = snapshot.treeStore.contentID
        checkpoint = snapshot.incrementalCheckpoint
    }
}

nonisolated struct FileTransferReconciliationRequest: Sendable {
    let snapshot: ScanSnapshot
    let options: ScanOptions
    let forcedDirectoryPaths: [String]
    let generation: UInt64
    fileprivate let cacheKey: ScanCacheKey
    fileprivate let wasCached: Bool
}

// The cache remains synchronous on the main actor; only discarded ownership
// crosses to the release queue. Admission pauses until that queue drains.
@MainActor
final class CompletedScanCache {
    private let maxTotalNodeCount: Int
    private let releases: BackgroundReleaseQueue
    private var snapshotsByKey: [ScanCacheKey: ScanSnapshot] = [:]
    private var keysByRecency: [ScanCacheKey] = []
    private var totalNodeCount = 0

    init(
        maxTotalNodeCount: Int,
        releaseQueue: DispatchQueue = DispatchQueue(label: "com.colinkim.Radix.snapshot-release", qos: .utility)
    ) {
        self.maxTotalNodeCount = max(maxTotalNodeCount, 1)
        self.releases = BackgroundReleaseQueue(queue: releaseQueue)
    }

    var retainedEntries: [(key: ScanCacheKey, snapshot: ScanSnapshot)] {
        keysByRecency.reversed().compactMap { key in
            snapshotsByKey[key].map { (key, $0) }
        }
    }

    func snapshot(for key: ScanCacheKey) -> ScanSnapshot? {
        guard let snapshot = snapshotsByKey[key] else { return nil }
        markRecentlyUsed(key)
        return snapshot
    }

    func mostRecentSnapshot(
        matchingOrContaining target: ScanTarget,
        options: ScanOptions
    ) -> ScanSnapshot? {
        for key in keysByRecency.reversed() where key.options == options {
            guard let snapshot = snapshotsByKey[key],
                  key.targetID == target.id || snapshot.treeStore.node(id: target.id) != nil else {
                continue
            }

            markRecentlyUsed(key)
            return snapshot
        }

        return nil
    }

    func store(_ snapshot: ScanSnapshot, for key: ScanCacheKey, replacing keys: Set<ScanCacheKey> = []) {
        guard snapshot.isComplete else { return }
        let backingID = snapshot.treeStore.backingStorageID
        // Keep one entry per backing tree. A cached parent can produce every
        // contained scope without accumulating additional scope bitsets.
        if keys.isEmpty, let containingKey = keysByRecency.last(where: { candidate in
            guard candidate.options == key.options, let cached = snapshotsByKey[candidate] else { return false }
            return cached.treeStore.backingStorageID == backingID
                && cached.treeStore.node(id: snapshot.target.id) != nil
                && (candidate != key || cached.id == snapshot.id)
        }) {
            if containingKey != key { removeSnapshot(for: key) }
            markRecentlyUsed(containingKey)
            return
        }

        // No new ownership while cleanup is pending: even repeated clear/store
        // calls can enqueue only the cache contents present at the first eviction.
        // Invalidate stale entries when an incoming scan cannot be cached.
        guard !releases.isReleasing else {
            removeAll()
            return
        }

        let supersededKeys = keysByRecency.filter { candidate in
            candidate == key || keys.contains(candidate)
                || snapshotsByKey[candidate]?.treeStore.backingStorageID == backingID
        }
        for candidate in supersededKeys { removeSnapshot(for: candidate) }
        snapshotsByKey[key] = snapshot
        totalNodeCount += snapshot.treeStore.backingNodeCapacity
        markRecentlyUsed(key)
        // One oversized backing tree remains available for folder navigation.
        // The budget takes precedence over retaining older independent scans.
        while totalNodeCount > maxTotalNodeCount, snapshotsByKey.count > 1,
              let oldestKey = keysByRecency.first {
            removeSnapshot(for: oldestKey)
        }
    }

    func removeAll() {
        for snapshot in snapshotsByKey.values { releases.discard(snapshot) }
        snapshotsByKey.removeAll()
        keysByRecency.removeAll()
        totalNodeCount = 0
    }

    func waitForPendingReleases() async {
        await releases.waitForPendingReleases()
    }

    private func markRecentlyUsed(_ key: ScanCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private func removeSnapshot(for key: ScanCacheKey) {
        guard let nodeCount = snapshotsByKey[key]?.treeStore.backingNodeCapacity else { return }
        totalNodeCount -= nodeCount
        releases.discard(snapshotsByKey.removeValue(forKey: key)!)
        keysByRecency.removeAll { $0 == key }
    }
}

@MainActor
final class SidebarScanCacheController {
    typealias TargetActivityCheck = @MainActor @Sendable (ScanTarget) -> Bool
    typealias SnapshotRestoration = @MainActor @Sendable (ScanSnapshot, ScanTarget) -> Void
    typealias ScanStart = @MainActor @Sendable (ScanTarget) -> Void

    private let snapshotTransformService: any ScanSnapshotTransforming
    private let completedScanCache: CompletedScanCache
    private var activeScanCacheKey: ScanCacheKey?
    private var displayedScanCacheKey: ScanCacheKey?
    private var sidebarScopeTask: Task<Void, Never>?
    private var sidebarScopeID: UUID?
    private var transferGeneration: UInt64 = 0
    private var validationGenerationByKey: [ScanCacheKey: UInt64] = [:]
    private var transferSourcePathsByKey: [ScanCacheKey: Set<String>] = [:]
    // Expansion can replace a scoped child's backing. Its original parent
    // remains the canonical baseline until a new scan starts for that child.
    private var containingKeyByScope: [ScanCacheKey: ScanCacheKey] = [:]

    init(
        maxTotalNodeCount: Int,
        snapshotTransformService: any ScanSnapshotTransforming = ScanSnapshotTransformService(),
        releaseQueue: DispatchQueue = DispatchQueue(label: "com.colinkim.Radix.snapshot-release", qos: .utility)
    ) {
        self.snapshotTransformService = snapshotTransformService
        self.completedScanCache = CompletedScanCache(
            maxTotalNodeCount: maxTotalNodeCount,
            releaseQueue: releaseQueue
        )
    }

    func resetTransientState() {
        cancelPendingSidebarTargetRestore()
        activeScanCacheKey = nil
        displayedScanCacheKey = nil
    }

    func cancelPendingSidebarTargetRestore() {
        sidebarScopeID = nil
        sidebarScopeTask?.cancel()
        sidebarScopeTask = nil
    }

    func clearActiveScanTracking() {
        activeScanCacheKey = nil
    }

    func clearDisplayedSnapshot() {
        displayedScanCacheKey = nil
    }

    func clearCache() {
        completedScanCache.removeAll()
        validationGenerationByKey.removeAll()
        transferSourcePathsByKey.removeAll()
        containingKeyByScope.removeAll()
    }

    func markExternalFileTransfer(sourceDirectoryPaths: [String], currentSnapshot: ScanSnapshot?) {
        let paths = Set(sourceDirectoryPaths.map { URL(filePath: $0).standardizedFileURL.path })
        var keys = Set(completedScanCache.retainedEntries.compactMap { entry in
            entry.snapshot.source.allowsFileMutation ? entry.key : nil
        })
        if let currentSnapshot, currentSnapshot.source.allowsFileMutation,
           let key = cacheKey(for: currentSnapshot) {
            keys.insert(key)
        }
        retainTransferTracking(for: keys)
        transferGeneration += 1
        for key in keys {
            transferSourcePathsByKey[key, default: []].formUnion(paths)
            validationGenerationByKey[key] = transferGeneration
        }
    }

    /// A receiver may finish writing after the drag session ends. Revalidate
    /// retained transfer-related scans on the next explicit app activation.
    @discardableResult
    func markForValidationOnActivation(currentSnapshot: ScanSnapshot?) -> Bool {
        var keys = Set(completedScanCache.retainedEntries.map(\.key))
        if let currentSnapshot, currentSnapshot.source.allowsFileMutation,
           let key = cacheKey(for: currentSnapshot) {
            keys.insert(key)
        }
        retainTransferTracking(for: keys)
        guard !transferSourcePathsByKey.isEmpty else { return false }
        transferGeneration += 1
        for key in transferSourcePathsByKey.keys {
            validationGenerationByKey[key] = transferGeneration
        }
        return true
    }

    func fileTransferReconciliationRequest(for snapshot: ScanSnapshot) -> FileTransferReconciliationRequest? {
        guard snapshot.isComplete, snapshot.source.allowsFileMutation,
              let displayedKey = cacheKey(for: snapshot) else { return nil }
        let entries = completedScanCache.retainedEntries
        let containingEntry = entries.first { entry in
            entry.key == containingKeyByScope[displayedKey]
                && entry.snapshot.source.allowsFileMutation
                && entry.snapshot.treeStore.node(id: snapshot.target.id) != nil
        } ?? entries.first { entry in
            entry.snapshot.source.allowsFileMutation
                && entry.key.options == displayedKey.options
                && entry.snapshot.treeStore.node(id: snapshot.target.id) != nil
                && entry.snapshot.treeStore.backingStorageID == snapshot.treeStore.backingStorageID
        }
        let key = containingEntry?.key ?? displayedKey
        let baseline = containingEntry?.snapshot ?? snapshot
        guard let generation = [validationGenerationByKey[key], validationGenerationByKey[displayedKey]]
            .compactMap({ $0 }).max() else { return nil }
        validationGenerationByKey[key] = generation
        if let paths = transferSourcePathsByKey[displayedKey] {
            transferSourcePathsByKey[key, default: []].formUnion(paths)
        }
        // A scoped child retains the parent's nil exclusion root and summary
        // settings. Scan the retained parent with its original target/options.
        let rootPath = baseline.target.url.standardizedFileURL.path
        let forcedPaths = Set((transferSourcePathsByKey[key] ?? []).compactMap { path -> String? in
            if Self.path(path, isContainedIn: rootPath) { return path }
            if Self.path(rootPath, isContainedIn: path) { return rootPath }
            return nil
        })
        return FileTransferReconciliationRequest(
            snapshot: baseline,
            options: key.options,
            forcedDirectoryPaths: forcedPaths.sorted(),
            generation: generation,
            cacheKey: key,
            wasCached: containingEntry != nil
        )
    }

    @discardableResult
    func completeFileTransferReconciliation(
        _ request: FileTransferReconciliationRequest,
        refreshedSnapshot: ScanSnapshot
    ) async -> Bool {
        await completedScanCache.waitForPendingReleases()
        guard !Task.isCancelled,
              refreshedSnapshot.isComplete, refreshedSnapshot.source.allowsFileMutation,
              refreshedSnapshot.target == request.snapshot.target,
              validationGenerationByKey[request.cacheKey] == request.generation else { return false }
        let entries = completedScanCache.retainedEntries
        if let cached = entries.first(where: { $0.key == request.cacheKey })?.snapshot {
            guard ScanCacheSnapshotVersion(cached) == ScanCacheSnapshotVersion(request.snapshot) else { return false }
        } else if request.wasCached {
            return false
        }
        let relatedKeys = Set(entries.compactMap { entry in
            entry.snapshot.treeStore.backingStorageID == request.snapshot.treeStore.backingStorageID
                && entry.key.options == request.options ? entry.key : nil
        }).union(containingKeyByScope.compactMap { scope, parent in
            parent == request.cacheKey ? scope : nil
        }).union([request.cacheKey])
        let paths = relatedKeys.reduce(into: Set<String>()) { paths, key in
            paths.formUnion(transferSourcePathsByKey[key] ?? [])
        }
        completedScanCache.store(refreshedSnapshot, for: request.cacheKey, replacing: relatedKeys)
        transferSourcePathsByKey[request.cacheKey] = paths
        for key in relatedKeys where validationGenerationByKey[key] == request.generation {
            validationGenerationByKey.removeValue(forKey: key)
        }
        return true
    }

    private func cacheKey(for snapshot: ScanSnapshot) -> ScanCacheKey? {
        if let options = snapshot.scanOptions {
            return ScanCacheKey(target: snapshot.target, options: options)
        }
        if let displayedScanCacheKey, displayedScanCacheKey.targetID == snapshot.target.id {
            return displayedScanCacheKey
        }
        return nil
    }

    private func retainTransferTracking(for keys: Set<ScanCacheKey>) {
        validationGenerationByKey = validationGenerationByKey.filter { keys.contains($0.key) }
        transferSourcePathsByKey = transferSourcePathsByKey.filter { keys.contains($0.key) }
    }

    private func inheritTransferTracking(for key: ScanCacheKey, from snapshot: ScanSnapshot) {
        for entry in completedScanCache.retainedEntries
        where entry.key.options == key.options
            && entry.snapshot.treeStore.backingStorageID == snapshot.treeStore.backingStorageID {
            guard let paths = transferSourcePathsByKey[entry.key] else { continue }
            transferSourcePathsByKey[key, default: []].formUnion(paths)
            if let generation = validationGenerationByKey[entry.key] {
                validationGenerationByKey[key] = max(validationGenerationByKey[key] ?? 0, generation)
            }
        }
        // Cached navigation is another explicit opportunity to catch writes
        // that completed after the immediate post-drop validation.
        if transferSourcePathsByKey[key] != nil, validationGenerationByKey[key] == nil {
            transferGeneration += 1
            validationGenerationByKey[key] = transferGeneration
        }
    }

    private static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }

    func prepareForScanStart(target: ScanTarget, options: ScanOptions) {
        let key = ScanCacheKey(target: target, options: options)
        activeScanCacheKey = key
        containingKeyByScope.removeValue(forKey: key)
        displayedScanCacheKey = nil
    }

    func currentScanExclusionRootPath(currentSnapshot: ScanSnapshot?) -> String? {
        displayedScanCacheKey?.options.exclusionRootPath
            ?? activeScanCacheKey?.options.exclusionRootPath
            ?? currentSnapshot?.target.url.path
    }

    func handleCompletedScanSnapshot(_ snapshot: ScanSnapshot) {
        defer {
            activeScanCacheKey = nil
        }

        guard let cacheKey = activeScanCacheKey ?? displayedScanCacheKey,
              cacheKey.targetID == snapshot.target.id else {
            return
        }

        completedScanCache.store(snapshot, for: cacheKey)
        displayedScanCacheKey = cacheKey
    }

    @discardableResult
    func applyCachedOrContainedSidebarTarget(
        _ target: ScanTarget,
        options: ScanOptions,
        currentSnapshot: ScanSnapshot?,
        isTargetActive: @escaping TargetActivityCheck,
        cancelDeferredScanStart: () -> Void,
        restoreSnapshot: @escaping SnapshotRestoration,
        startScan: @escaping ScanStart
    ) -> Bool {
        let cacheKey = ScanCacheKey(target: target, options: options)
        if let currentSnapshot,
           currentSnapshot.target.id == target.id,
           displayedScanCacheKey == cacheKey {
            applyExactCachedSnapshot(
                currentSnapshot,
                cacheKey: cacheKey,
                currentSnapshot: currentSnapshot,
                cancelDeferredScanStart: cancelDeferredScanStart,
                restoreSnapshot: restoreSnapshot
            )
            return false
        }

        if scheduleContainedSidebarTargetRestore(
            target,
            options: options,
            from: currentSnapshot,
            currentSnapshot: currentSnapshot,
            isTargetActive: isTargetActive,
            cancelDeferredScanStart: cancelDeferredScanStart,
            restoreSnapshot: restoreSnapshot,
            startScan: startScan
        ) {
            return false
        }

        if let cachedSnapshot = completedScanCache.mostRecentSnapshot(
            matchingOrContaining: target,
            options: options
        ) {
            if cachedSnapshot.target.id == target.id {
                applyExactCachedSnapshot(
                    cachedSnapshot,
                    cacheKey: cacheKey,
                    currentSnapshot: currentSnapshot,
                    cancelDeferredScanStart: cancelDeferredScanStart,
                    restoreSnapshot: restoreSnapshot
                )
                return false
            }

            if scheduleContainedSidebarTargetRestore(
                target,
                options: options,
                from: cachedSnapshot,
                currentSnapshot: currentSnapshot,
                isTargetActive: isTargetActive,
                cancelDeferredScanStart: cancelDeferredScanStart,
                restoreSnapshot: restoreSnapshot,
                startScan: startScan
            ) {
                return false
            }
        }

        if let cachedSnapshot = completedScanCache.snapshot(for: cacheKey) {
            applyExactCachedSnapshot(
                cachedSnapshot,
                cacheKey: cacheKey,
                currentSnapshot: currentSnapshot,
                cancelDeferredScanStart: cancelDeferredScanStart,
                restoreSnapshot: restoreSnapshot
            )
            return false
        }

        return true
    }

    private func applyExactCachedSnapshot(
        _ snapshot: ScanSnapshot,
        cacheKey: ScanCacheKey,
        currentSnapshot: ScanSnapshot?,
        cancelDeferredScanStart: () -> Void,
        restoreSnapshot: SnapshotRestoration
    ) {
        inheritTransferTracking(for: cacheKey, from: snapshot)
        if currentSnapshot?.id == snapshot.id {
            cancelPendingSidebarTargetRestore()
            cancelDeferredScanStart()
            activeScanCacheKey = nil
            displayedScanCacheKey = cacheKey
        } else {
            restoreCachedSnapshot(
                snapshot,
                cacheKey: cacheKey,
                cancelDeferredScanStart: cancelDeferredScanStart,
                restoreSnapshot: restoreSnapshot
            )
        }
    }

    private func restoreCachedSnapshot(
        _ snapshot: ScanSnapshot,
        cacheKey: ScanCacheKey,
        cancelDeferredScanStart: () -> Void,
        restoreSnapshot: SnapshotRestoration
    ) {
        cancelPendingSidebarTargetRestore()
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        displayedScanCacheKey = cacheKey
        inheritTransferTracking(for: cacheKey, from: snapshot)
        restoreSnapshot(snapshot, snapshot.target)
    }

    private func scheduleContainedSidebarTargetRestore(
        _ target: ScanTarget,
        options: ScanOptions,
        from containingSnapshot: ScanSnapshot?,
        currentSnapshot: ScanSnapshot?,
        isTargetActive: @escaping TargetActivityCheck,
        cancelDeferredScanStart: () -> Void,
        restoreSnapshot: @escaping SnapshotRestoration,
        startScan: @escaping ScanStart
    ) -> Bool {
        guard let containingSnapshot,
              containingSnapshot.target.id != target.id,
              canScope(containingSnapshot, using: options, currentSnapshot: currentSnapshot),
              containingSnapshot.treeStore.node(id: target.id) != nil else {
            return false
        }

        cancelDeferredScanStart()
        let initialContainingKey = ScanCacheKey(target: containingSnapshot.target, options: options)
        let canonicalKey = containingKeyByScope[initialContainingKey] ?? initialContainingKey
        let canonicalVersion = completedScanCache.snapshot(for: canonicalKey).map(ScanCacheSnapshotVersion.init)
        let scopeID = UUID()
        sidebarScopeID = scopeID
        sidebarScopeTask = Task { @MainActor [weak self, snapshotTransformService] in
            do {
                guard let self else { return }
                var baseline = containingSnapshot
                var containingKey = initialContainingKey
                while true {
                    let scopedSnapshot = try await snapshotTransformService.scopedSnapshot(baseline, to: target)
                    // A scan completed during cleanup may have missed admission.
                    // Retain its parent before publishing a scope, so returning to
                    // that parent still works without another filesystem scan.
                    await completedScanCache.waitForPendingReleases()
                    try Task.checkCancellation()
                    guard isCurrentSidebarScope(scopeID) else { return }
                    guard isTargetActive(target) else {
                        clearSidebarScope(scopeID)
                        return
                    }
                    let canonicalParent = completedScanCache.snapshot(for: canonicalKey)
                    let changedCanonicalParent = canonicalParent.flatMap { latest in
                        canonicalVersion != nil && ScanCacheSnapshotVersion(latest) != canonicalVersion ? latest : nil
                    }
                    if let latest = changedCanonicalParent ?? completedScanCache.snapshot(for: containingKey),
                       ScanCacheSnapshotVersion(latest) != ScanCacheSnapshotVersion(baseline) {
                        // Reconciliation replaced the parent while scoping was
                        // suspended. Derive the same selected target from that
                        // replacement and re-check after the next suspension.
                        baseline = latest
                        containingKey = ScanCacheKey(target: latest.target, options: options)
                        continue
                    }
                    clearSidebarScope(scopeID)
                    guard let scopedSnapshot else {
                        startScan(target)
                        return
                    }
                    completedScanCache.store(baseline, for: containingKey)
                    let retainedEntries = completedScanCache.retainedEntries
                    let originalParent = containingKeyByScope[containingKey]
                    let canonicalKey = (retainedEntries.first { entry in
                        entry.key == originalParent && entry.snapshot.treeStore.node(id: target.id) != nil
                    } ?? retainedEntries.first { entry in
                        entry.key.options == options
                            && entry.snapshot.treeStore.node(id: target.id) != nil
                            && entry.snapshot.treeStore.backingStorageID == baseline.treeStore.backingStorageID
                    })?.key ?? containingKey
                    containingKeyByScope[ScanCacheKey(target: target, options: options)] = canonicalKey
                    restoreScopedSidebarTarget(scopedSnapshot, target: target, options: options, restoreSnapshot: restoreSnapshot)
                    return
                }
            } catch is CancellationError {
                if let self, isCurrentSidebarScope(scopeID) {
                    clearSidebarScope(scopeID)
                }
                return
            } catch {
                guard let self,
                      isCurrentSidebarScope(scopeID) else {
                    return
                }
                guard isTargetActive(target) else {
                    clearSidebarScope(scopeID)
                    return
                }

                clearSidebarScope(scopeID)
                startScan(target)
            }
        }
        return true
    }

    private func isCurrentSidebarScope(_ scopeID: UUID) -> Bool {
        sidebarScopeID == scopeID
    }

    private func clearSidebarScope(_ scopeID: UUID) {
        guard isCurrentSidebarScope(scopeID) else { return }

        sidebarScopeID = nil
        sidebarScopeTask = nil
    }

    private func restoreScopedSidebarTarget(
        _ scopedSnapshot: ScanSnapshot,
        target: ScanTarget,
        options: ScanOptions,
        restoreSnapshot: SnapshotRestoration
    ) {
        activeScanCacheKey = nil
        let cacheKey = ScanCacheKey(target: target, options: options)
        displayedScanCacheKey = cacheKey
        inheritTransferTracking(for: cacheKey, from: scopedSnapshot)
        restoreSnapshot(scopedSnapshot, target)
    }

    private func canScope(
        _ snapshot: ScanSnapshot,
        using options: ScanOptions,
        currentSnapshot: ScanSnapshot?
    ) -> Bool {
        guard currentSnapshot?.id == snapshot.id else {
            return true
        }

        return displayedScanCacheKey?.options == options
    }
}
