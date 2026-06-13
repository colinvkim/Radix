//
//  SidebarScanCacheController.swift
//  Radix
//

import Foundation

struct ScanCacheKey: Hashable {
    let targetID: String
    let options: ScanOptions

    init(target: ScanTarget, options: ScanOptions) {
        targetID = target.id
        self.options = options
    }
}

struct CompletedScanCache {
    private let minimumRetainedSnapshotCount: Int
    private let maxTotalNodeCount: Int
    private var snapshotsByKey: [ScanCacheKey: ScanSnapshot] = [:]
    private var nodeCountsByKey: [ScanCacheKey: Int] = [:]
    private var keysByRecency: [ScanCacheKey] = []
    private var totalNodeCount = 0

    init(minimumRetainedSnapshotCount: Int, maxTotalNodeCount: Int) {
        self.minimumRetainedSnapshotCount = max(minimumRetainedSnapshotCount, 1)
        self.maxTotalNodeCount = max(maxTotalNodeCount, 1)
    }

    mutating func snapshot(for key: ScanCacheKey) -> ScanSnapshot? {
        guard let snapshot = snapshotsByKey[key] else { return nil }
        markRecentlyUsed(key)
        return snapshot
    }

    mutating func snapshot(containing target: ScanTarget, options: ScanOptions) -> ScanSnapshot? {
        for key in keysByRecency.reversed() where key.options == options {
            guard let snapshot = snapshotsByKey[key],
                  snapshot.target.id != target.id,
                  snapshot.treeStore.node(id: target.id) != nil else {
                continue
            }

            markRecentlyUsed(key)
            return snapshot
        }

        return nil
    }

    mutating func store(_ snapshot: ScanSnapshot, for key: ScanCacheKey) {
        guard snapshot.isComplete else { return }
        let nodeCount = snapshot.treeStore.nodeCount
        let previousNodeCount = nodeCountsByKey[key] ?? 0

        snapshotsByKey[key] = snapshot
        nodeCountsByKey[key] = nodeCount
        totalNodeCount += nodeCount - previousNodeCount
        markRecentlyUsed(key)
        trimToBudget()
    }

    mutating func removeAll() {
        snapshotsByKey.removeAll()
        nodeCountsByKey.removeAll()
        keysByRecency.removeAll()
        totalNodeCount = 0
    }

    private mutating func markRecentlyUsed(_ key: ScanCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func trimToBudget() {
        // Keep the most recent scans even when one is larger than the soft
        // node budget, so sidebar back-and-forth does not forget a large parent.
        while totalNodeCount > maxTotalNodeCount,
              snapshotsByKey.count > minimumRetainedSnapshotCount,
              let oldestKey = keysByRecency.first {
            removeSnapshot(for: oldestKey)
        }
    }

    private mutating func removeSnapshot(for key: ScanCacheKey) {
        if let nodeCount = nodeCountsByKey[key] {
            totalNodeCount -= nodeCount
        }
        snapshotsByKey[key] = nil
        nodeCountsByKey[key] = nil
        keysByRecency.removeAll { $0 == key }
    }
}

@MainActor
final class SidebarScanCacheController {
    typealias TargetActivityCheck = @MainActor @Sendable (ScanTarget) -> Bool
    typealias SnapshotRestoration = @MainActor @Sendable (ScanSnapshot, ScanTarget) -> Void
    typealias ScanStart = @MainActor @Sendable (ScanTarget) -> Void

    private let snapshotTransformService: ScanSnapshotTransformService
    private var completedScanCache: CompletedScanCache
    private var activeScanCacheKey: ScanCacheKey?
    private var displayedScanCacheKey: ScanCacheKey?
    private var sidebarScopeTask: Task<Void, Never>?
    private var sidebarScopeID: UUID?

    init(
        minimumRetainedSnapshotCount: Int,
        maxTotalNodeCount: Int,
        snapshotTransformService: ScanSnapshotTransformService = ScanSnapshotTransformService()
    ) {
        self.snapshotTransformService = snapshotTransformService
        self.completedScanCache = CompletedScanCache(
            minimumRetainedSnapshotCount: minimumRetainedSnapshotCount,
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

        guard let cacheKey = activeScanCacheKey,
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

        let cacheKey = ScanCacheKey(target: target, options: options)
        if let cachedSnapshot = completedScanCache.snapshot(for: cacheKey),
           currentSnapshot?.id != cachedSnapshot.id {
            restoreCachedSnapshot(
                cachedSnapshot,
                cacheKey: cacheKey,
                cancelDeferredScanStart: cancelDeferredScanStart,
                restoreSnapshot: restoreSnapshot
            )
            return false
        }

        if let containingSnapshot = completedScanCache.snapshot(containing: target, options: options),
           scheduleContainedSidebarTargetRestore(
               target,
               options: options,
               from: containingSnapshot,
               currentSnapshot: currentSnapshot,
               isTargetActive: isTargetActive,
               cancelDeferredScanStart: cancelDeferredScanStart,
               restoreSnapshot: restoreSnapshot,
               startScan: startScan
           ) {
            return false
        }

        return true
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
                guard let self,
                      isCurrentSidebarScope(scopeID) else {
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
