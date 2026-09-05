//
//  SidebarScanCacheController.swift
//  Radix
//

import Foundation

nonisolated struct ScanCacheKey: Hashable {
    let targetID: String
    let options: ScanOptions

    init(target: ScanTarget, options: ScanOptions) {
        targetID = target.id
        self.options = options
    }
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

    func store(_ snapshot: ScanSnapshot, for key: ScanCacheKey) {
        guard snapshot.isComplete else { return }
        let backingID = snapshot.treeStore.backingStorageID
        // Keep one entry per backing tree. A cached parent can produce every
        // contained scope without accumulating additional scope bitsets.
        if let containingKey = keysByRecency.last(where: { candidate in
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
            candidate == key || snapshotsByKey[candidate]?.treeStore.backingStorageID == backingID
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

    private let snapshotTransformService: ScanSnapshotTransformService
    private let completedScanCache: CompletedScanCache
    private var activeScanCacheKey: ScanCacheKey?
    private var displayedScanCacheKey: ScanCacheKey?
    private var sidebarScopeTask: Task<Void, Never>?
    private var sidebarScopeID: UUID?

    init(
        maxTotalNodeCount: Int,
        snapshotTransformService: ScanSnapshotTransformService = ScanSnapshotTransformService()
    ) {
        self.snapshotTransformService = snapshotTransformService
        self.completedScanCache = CompletedScanCache(
            maxTotalNodeCount: maxTotalNodeCount
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
    }

    func prepareForScanStart(target: ScanTarget, options: ScanOptions) {
        activeScanCacheKey = ScanCacheKey(target: target, options: options)
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
        let scopeID = UUID()
        sidebarScopeID = scopeID
        sidebarScopeTask = Task { @MainActor [weak self, snapshotTransformService] in
            do {
                let scopedSnapshot = try await snapshotTransformService.scopedSnapshot(containingSnapshot, to: target)
                try Task.checkCancellation()
                guard let self else { return }
                // A scan completed during cleanup may have missed admission.
                // Retain its parent before publishing a scope, so returning to
                // that parent still works without another filesystem scan.
                await completedScanCache.waitForPendingReleases()
                try Task.checkCancellation()
                guard isCurrentSidebarScope(scopeID) else {
                    return
                }
                guard isTargetActive(target) else {
                    clearSidebarScope(scopeID)
                    return
                }

                clearSidebarScope(scopeID)
                guard let scopedSnapshot else {
                    startScan(target)
                    return
                }

                completedScanCache.store(containingSnapshot, for: ScanCacheKey(target: containingSnapshot.target, options: options))
                restoreScopedSidebarTarget(scopedSnapshot, target: target, options: options, restoreSnapshot: restoreSnapshot)
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
        displayedScanCacheKey = ScanCacheKey(target: target, options: options)
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
