//
//  FolderRefreshController.swift
//  Radix
//

import Foundation

/// Watches the scan as a whole, but only refreshes the directory being browsed.
/// Dirty paths survive navigation and subtree replacements of the same scan.
@MainActor
final class FolderRefreshController {
    private struct WatchIdentity: Equatable {
        let snapshotID: UUID
        let targetPath: String
        let options: ScanOptions?
    }

    private struct Change {
        let version: UInt64
        let receivedAt: ContinuousClock.Instant
    }

    private struct Refresh {
        let nodeID: String
        let path: String
        let version: UInt64
        let startedAt: ContinuousClock.Instant
    }

    private let watcher: any FileSystemChangeWatching
    private let debounce: Duration
    private let minimumRefreshInterval: Duration
    private let maximumPendingPaths: Int
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async throws -> Void
    private let requestRefresh: @MainActor (String) -> Bool
    private var watchIdentity: WatchIdentity?
    private var snapshot: ScanSnapshot?
    private var focusedNodeID: String?
    private var canRefresh = false
    private var watchTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var scheduledNodeID: String?
    private var scheduledDue: ContinuousClock.Instant?
    private var scheduledGeneration = 0
    private var version: UInt64 = 0
    private var pendingChanges: [String: Change] = [:]
    // An ancestor event (including an overflow marker at the scan root) remains
    // dirty for other folders after one subtree has been refreshed.
    private var acknowledgedScopes: [String: UInt64] = [:]
    private var blockedScopes: [String: UInt64] = [:]
    private var inFlight: Refresh?
    private var nextRefreshNotBefore: ContinuousClock.Instant?

    init(
        watcher: any FileSystemChangeWatching = DarwinFileSystemChangeWatcher(),
        debounce: Duration = .seconds(1),
        minimumRefreshInterval: Duration = .seconds(5),
        maximumPendingPaths: Int = 4_096,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        requestRefresh: @escaping @MainActor (String) -> Bool
    ) {
        self.watcher = watcher
        self.debounce = max(debounce, .zero)
        self.minimumRefreshInterval = max(minimumRefreshInterval, .zero)
        self.maximumPendingPaths = max(maximumPendingPaths, 1)
        self.now = now
        self.sleep = sleep
        self.requestRefresh = requestRefresh
    }

    deinit {
        watchTask?.cancel()
        scheduledTask?.cancel()
    }

    func update(snapshot: ScanSnapshot?, focusedNodeID: String?, canRefresh: Bool) {
        let identity = snapshot.flatMap { snapshot -> WatchIdentity? in
            guard snapshot.isComplete, !snapshot.source.isImported else { return nil }
            return WatchIdentity(
                snapshotID: snapshot.id,
                targetPath: snapshot.target.url.path,
                options: snapshot.scanOptions
            )
        }
        if identity != watchIdentity {
            reset()
            watchIdentity = identity
        } else if let previous = self.snapshot,
                  let snapshot,
                  previous.treeStore.contentID != snapshot.treeStore.contentID,
                  inFlight == nil {
            // A manual update can make a previously failed folder refreshable.
            blockedScopes.removeAll(keepingCapacity: true)
        }
        self.snapshot = identity == nil ? nil : snapshot
        self.focusedNodeID = focusedNodeID
        self.canRefresh = canRefresh
        if let identity, watchTask == nil, let snapshot {
            startWatching(snapshot: snapshot, identity: identity)
        }
        scheduleRefresh()
    }

    func refreshStarted(nodeID: String) {
        guard inFlight == nil, watchIdentity != nil,
              let node = snapshot?.treeStore.node(id: nodeID) else { return }
        cancelScheduledRefresh()
        inFlight = Refresh(nodeID: nodeID, path: node.url.path, version: version, startedAt: now())
    }

    func refreshFinished(nodeID: String, result: FolderRescanResult) {
        guard let refresh = inFlight, refresh.nodeID == nodeID else { return }
        inFlight = nil
        switch result {
        case .updated:
            pendingChanges = pendingChanges.filter { path, change in
                change.version > refresh.version || !Self.contains(path, in: refresh.path)
            }
            acknowledge(path: refresh.path, through: refresh.version)
            blockedScopes.removeValue(forKey: refresh.path)
        case .failed:
            // A failure waits for another relevant event or a manual update,
            // rather than endlessly retrying unchanged, unavailable contents.
            blockedScopes[refresh.path] = refresh.version
            boundScopeRecords(&blockedScopes)
        case .cancelled:
            // Window/interaction changes can cancel useful work temporarily.
            // Keep its changes pending so reopening resumes without a new event.
            break
        }
        applyCooldown(after: refresh)
        scheduleRefresh()
    }

    /// An explicit Stop action suppresses the work already known at that
    /// moment. Lifecycle cancellation, by contrast, keeps it eligible to resume.
    func pauseCurrentRefresh() {
        guard let refresh = inFlight else { return }
        blockedScopes[refresh.path] = version
        boundScopeRecords(&blockedScopes)
        inFlight = nil
        applyCooldown(after: refresh)
        cancelScheduledRefresh()
    }

    private func reset() {
        watchTask?.cancel()
        watchTask = nil
        cancelScheduledRefresh()
        pendingChanges.removeAll(keepingCapacity: true)
        acknowledgedScopes.removeAll(keepingCapacity: true)
        blockedScopes.removeAll(keepingCapacity: true)
        inFlight = nil
        nextRefreshNotBefore = nil
        version = 0
    }

    private func startWatching(snapshot: ScanSnapshot, identity: WatchIdentity) {
        let watcher = watcher
        let targetURL = snapshot.target.url
        let checkpoint = snapshot.incrementalCheckpoint
        watchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                for try await events in watcher.changes(for: targetURL, since: checkpoint) {
                    guard !Task.isCancelled else { return }
                    self?.receive(events, identity: identity)
                }
            } catch {
                // Unsupported/non-local locations and startup failures retain
                // manual refresh. A failed watcher is not a filesystem change.
            }
        }
    }

    private func receive(_ events: [FileSystemEventRecord], identity: WatchIdentity) {
        guard watchIdentity == identity, let snapshot else { return }
        let options = snapshot.scanOptions ?? ScanOptions()
        let matcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? identity.targetPath
        )
        let uncertainFlags: FileSystemEventFlags = [
            .userDropped, .kernelDropped, .eventIDsWrapped, .rootChanged,
            .volumeMounted, .volumeUnmounted
        ]
        let mutationFlags: FileSystemEventFlags = [
            .itemCreated, .itemRemoved, .itemRenamed, .itemModified,
            .itemMetadataModified, .itemCloned, .itemIsHardLink,
            .itemIsLastHardLink, .mustScanSubdirectories
        ]
        var recordedChange = false
        for event in events {
            if !event.flags.intersection(uncertainFlags).isEmpty {
                recordChange(at: identity.targetPath)
                recordedChange = true
                continue
            }
            guard !event.flags.intersection(mutationFlags).isEmpty,
                  Self.contains(event.path, in: identity.targetPath),
                  !isExcluded(event, rootPath: identity.targetPath, options: options, matcher: matcher)
            else { continue }
            // File events are folded into their containing directory. A
            // directory event also intersects its parent when that is focused.
            let path = event.flags.contains(.itemIsFile) || event.flags.contains(.itemIsSymbolicLink)
                ? URL(filePath: event.path).deletingLastPathComponent().path
                : event.path
            recordChange(at: path)
            recordedChange = true
        }
        if recordedChange {
            scheduleRefresh()
        }
    }

    private func isExcluded(
        _ event: FileSystemEventRecord,
        rootPath: String,
        options: ScanOptions,
        matcher: ScanExclusionMatcher
    ) -> Bool {
        guard event.path != rootPath else { return false }
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        let components = event.path.dropFirst(prefix.count).split(separator: "/")
        var path = rootPath
        for (index, component) in components.enumerated() {
            if !options.includeHiddenFiles, component.hasPrefix(".") { return true }
            path = path == "/" ? path + component : path + "/" + component
            let isDirectory = index < components.count - 1
                || event.flags.intersection([.itemIsFile, .itemIsSymbolicLink]).isEmpty
            if matcher.excludesKnownNormalizedPath(path, isDirectory: isDirectory) { return true }
        }
        return false
    }

    private func recordChange(at path: String) {
        version += 1
        let change = Change(version: version, receivedAt: now())
        if pendingChanges[path] == nil, pendingChanges.count >= maximumPendingPaths,
           let rootPath = watchIdentity?.targetPath {
            // Never discard unseen changes: collapse to a conservative root
            // marker. Each visited folder can acknowledge it independently.
            pendingChanges = [rootPath: change]
            acknowledgedScopes.removeAll(keepingCapacity: true)
        } else {
            pendingChanges[path] = change
        }
    }

    private func focusedDirectory() -> FileNodeRecord? {
        guard canRefresh, let snapshot,
              let node = snapshot.treeStore.node(id: focusedNodeID),
              node.isDirectory, !node.isSymbolicLink, !node.isSynthetic,
              node.isSelfAccessible,
              !(snapshot.target.kind == .volume && node.id == snapshot.root.id)
        else { return nil }
        return node
    }

    private func latestChange(in scope: String) -> Change? {
        let blockedVersion = blockedScopes[scope] ?? 0
        var acknowledgedVersion: UInt64 = 0
        var ancestor = scope
        while true {
            acknowledgedVersion = max(acknowledgedVersion, acknowledgedScopes[ancestor] ?? 0)
            guard ancestor != "/" else { break }
            ancestor = URL(filePath: ancestor).deletingLastPathComponent().path
        }
        var latest: Change?
        for (path, change) in pendingChanges where change.version > blockedVersion {
            let intersects = Self.contains(path, in: scope)
                || (Self.contains(scope, in: path) && change.version > acknowledgedVersion)
            if intersects, change.version > (latest?.version ?? 0) { latest = change }
        }
        return latest
    }

    private func scheduleRefresh() {
        guard inFlight == nil, let node = focusedDirectory(),
              let change = latestChange(in: node.url.path) else {
            cancelScheduledRefresh()
            return
        }
        let due = max(
            change.receivedAt.advanced(by: debounce),
            nextRefreshNotBefore ?? change.receivedAt
        )
        // Progress, hover, and unrelated filesystem activity may update the
        // context repeatedly. Preserve an unchanged timer and its boundary.
        guard scheduledTask == nil || scheduledNodeID != node.id || scheduledDue != due else { return }
        cancelScheduledRefresh()
        scheduledNodeID = node.id
        scheduledDue = due
        let delay = max(now().duration(to: due), .zero)
        let generation = scheduledGeneration
        let sleep = sleep
        scheduledTask = Task { [weak self] in
            do {
                if delay > .zero { try await sleep(delay) }
                guard !Task.isCancelled else { return }
                self?.beginRefresh(generation: generation)
            } catch {
                // Cancellation is used when focus, interaction eligibility,
                // or the trailing debounce boundary changes.
            }
        }
    }

    private func cancelScheduledRefresh() {
        scheduledGeneration += 1
        scheduledTask?.cancel()
        scheduledTask = nil
        scheduledNodeID = nil
        scheduledDue = nil
    }

    private func beginRefresh(generation: Int) {
        guard generation == scheduledGeneration, inFlight == nil,
              let node = focusedDirectory(), latestChange(in: node.url.path) != nil else { return }
        scheduledTask = nil
        scheduledNodeID = nil
        scheduledDue = nil
        let refresh = Refresh(nodeID: node.id, path: node.url.path, version: version, startedAt: now())
        inFlight = refresh
        if !requestRefresh(node.id), inFlight?.nodeID == node.id {
            // Eligibility can change before its deferred UI observation arrives.
            // A rejected start leaves changes pending for the next readiness update.
            inFlight = nil
        }
    }

    private func applyCooldown(after refresh: Refresh) {
        let finishedAt = now()
        let elapsed = max(refresh.startedAt.duration(to: finishedAt), .zero)
        // Leave real idle time between scans. Expensive selected folders get
        // proportionally more rest instead of scanning continually under writes.
        let cooldown = max(minimumRefreshInterval, elapsed * 2)
        nextRefreshNotBefore = finishedAt.advanced(by: cooldown)
    }

    private func acknowledge(path: String, through version: UInt64) {
        acknowledgedScopes = acknowledgedScopes.filter { scope, acknowledgedVersion in
            !Self.contains(scope, in: path) || acknowledgedVersion > version
        }
        acknowledgedScopes[path] = version
        boundScopeRecords(&acknowledgedScopes)
    }

    private func boundScopeRecords(_ scopes: inout [String: UInt64]) {
        guard scopes.count > maximumPendingPaths,
              let oldest = scopes.min(by: { $0.value < $1.value })?.key else { return }
        scopes.removeValue(forKey: oldest)
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}
