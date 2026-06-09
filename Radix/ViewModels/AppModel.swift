//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    private struct ScanCacheKey: Hashable {
        let targetID: String
        let options: ScanOptions

        init(target: ScanTarget, options: ScanOptions) {
            targetID = target.id
            self.options = options
        }
    }

    private struct CompletedScanCache {
        private let capacity: Int
        private var snapshotsByKey: [ScanCacheKey: ScanSnapshot] = [:]
        private var keysByRecency: [ScanCacheKey] = []

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
        }

        mutating func snapshot(for key: ScanCacheKey) -> ScanSnapshot? {
            guard let snapshot = snapshotsByKey[key] else { return nil }
            markRecentlyUsed(key)
            return snapshot
        }

        mutating func store(_ snapshot: ScanSnapshot, for key: ScanCacheKey) {
            guard snapshot.isComplete else { return }
            snapshotsByKey[key] = snapshot
            markRecentlyUsed(key)
            trimToCapacity()
        }

        mutating func removeAll() {
            snapshotsByKey.removeAll()
            keysByRecency.removeAll()
        }

        private mutating func markRecentlyUsed(_ key: ScanCacheKey) {
            keysByRecency.removeAll { $0 == key }
            keysByRecency.append(key)
        }

        private mutating func trimToCapacity() {
            while snapshotsByKey.count > capacity, let oldestKey = keysByRecency.first {
                keysByRecency.removeFirst()
                snapshotsByKey[oldestKey] = nil
            }
        }
    }

    private enum FileActionError: LocalizedError {
        case noSelection
        case unavailable(path: String)
        case unsupported
        case directoryRequired
        case packageContentsHidden(settingEnabled: Bool)
        case folderRequiredForDrop
        case fullDiskAccessSettingsUnavailable

        var alertTitle: String? {
            switch self {
            case .packageContentsHidden:
                return "Package Contents Hidden"
            default:
                return nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return "Select an item first."
            case .unavailable(let path):
                return "The item at \(path) is no longer available."
            case .unsupported:
                return "This item does not support that action."
            case .directoryRequired:
                return "Choose a folder with contents to zoom in."
            case .packageContentsHidden(let settingEnabled):
                if settingEnabled {
                    return "Radix scanned this package before package contents were expanded. Rescan this location to zoom into it."
                }
                return "Radix scanned this package as a single item. To zoom into it, turn on “Treat app bundles and packages as folders” in Settings, then rescan this location."
            case .folderRequiredForDrop:
                return "Drop a folder or mounted volume to start a scan."
            case .fullDiskAccessSettingsUnavailable:
                return "Radix could not open Full Disk Access settings."
            }
        }
    }

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published private(set) var availableTargets: [ScanTarget] = []
    @Published var recentTargets: [ScanTarget] = []
    @Published var showsOnboarding: Bool
    @Published private(set) var fullDiskAccessStatus: FullDiskAccessStatus
    @Published private(set) var activeSidebarTargetID: String?
    @Published var lastErrorMessage: String? {
        didSet {
            if lastErrorMessage == nil {
                lastActionErrorTitle = nil
            }
        }
    }
    @Published var pendingTrashNode: FileNodeRecord?

    private let dependencies: AppDependencies
    private let scanCoordinator: ScanCoordinator
    private let navigationModel = WorkspaceNavigationModel()
    private var lastActionErrorTitle: String?
    private var completedScanCache = CompletedScanCache(capacity: 6)
    private var activeScanCacheKey: ScanCacheKey?

    private var cancellables = Set<AnyCancellable>()
    private var quickLookEventMonitor: AppEventMonitorToken?
    private var deferredScanStartTask: Task<Void, Never>?
    private var deferredScanStartID: UUID?

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
        self.scanCoordinator = ScanCoordinator(scanService: dependencies.scanService)

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        showsOnboarding = !preferences.didCompleteOnboarding
        fullDiskAccessStatus = dependencies.systemActions.fullDiskAccessStatus()
        recentTargets = dependencies.recentTargets.loadAvailableTargets()

        refreshAvailableTargets()
        observeNavigationModel()
        observeScanCoordinator()
        observeMountedVolumes()
        observePreferences()
        installQuickLookKeyMonitor()
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    func cleanup() {
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        scanCoordinator.stopScan()
        removeQuickLookKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        if scanCoordinator.canStopScan {
            scanCoordinator.stopScan()
        } else {
            scanCoordinator.stopScan(resetState: false)
        }
        dependencies.systemActions.quickLook.close()
    }

    var scanState: ScanCoordinator {
        scanCoordinator
    }

    var navigation: WorkspaceNavigationModel {
        navigationModel
    }

    var startupDiskTarget: ScanTarget? {
        availableTargets.first(where: { $0.kind == .volume && $0.url.path == "/" })
    }

    var smartTargets: [ScanTarget] {
        let indexedTargets = Dictionary(uniqueKeysWithValues: availableTargets.map { ($0.id, $0) })
        return preferredSmartTargetPaths.compactMap { indexedTargets[$0] }
    }

    var mountedVolumeTargets: [ScanTarget] {
        let excluded = Set(smartTargets.map(\.id))
        return availableTargets.filter { $0.kind == .volume && !excluded.contains($0.id) }
    }

    var recentScanTargets: [ScanTarget] {
        let excluded = Set((smartTargets + mountedVolumeTargets).map(\.id))
        return dependencies.recentTargets
            .availableTargets(from: recentTargets)
            .filter { !excluded.contains($0.id) }
    }

    var errorAlertTitle: String {
        if scanCoordinator.phase == .failed {
            return "Scan Failed"
        }
        return lastActionErrorTitle ?? "Action Failed"
    }

    var canRescanFromErrorAlert: Bool {
        scanCoordinator.phase == .failed && scanCoordinator.canRescan
    }

    func dismissOnboarding() {
        showsOnboarding = false
        dependencies.preferences.markOnboardingComplete()
    }

    func presentOnboarding() {
        showsOnboarding = true
    }

    func refreshFullDiskAccessStatus() {
        fullDiskAccessStatus = dependencies.systemActions.fullDiskAccessStatus()
    }

    func restoreDefaultPreferences() {
        showHiddenFiles = true
        treatPackagesAsDirectories = false
        maxRenderedDepth = 6
        autoSummarizeDirectories = true
    }

    func clearRecentTargets() {
        recentTargets.removeAll()
        dependencies.recentTargets.clear()
    }

    /// Expands an auto-summarized directory by scanning it fully and replacing the node in the tree.
    func expandSummarizedNode(_ node: FileNodeRecord, completion: @escaping () -> Void) {
        let target = ScanTarget(url: node.url)
        let options = scanOptions(for: target, autoSummarizeDirectories: false)

        scanCoordinator.expandSummarizedNode(node, options: options) { [weak self] result in
            guard let self else {
                completion()
                return
            }

            switch result {
            case .skipped, .cancelled:
                break
            case .expanded(let replacementRootID):
                navigationModel.select(nodeID: replacementRootID)
            case .failed(let message):
                presentErrorMessage(message)
            }

            completion()
        }
    }

    func presentOpenPanelAndScan() {
        guard !scanCoordinator.isScanning else { return }
        if let target = dependencies.systemActions.presentOpenPanel() {
            startScan(target)
        }
    }

    func startScan(_ target: ScanTarget) {
        // Defer state mutations to the next runloop to avoid
        // "Publishing changes from within view updates is not allowed."
        cancelDeferredScanStart()

        let scanStartID = UUID()
        deferredScanStartID = scanStartID
        deferredScanStartTask = Task { [weak self] in
            await MainActor.run { [weak self] in
                guard let self,
                      self.deferredScanStartID == scanStartID,
                      !Task.isCancelled else {
                    return
                }

                self.deferredScanStartID = nil
                self.deferredScanStartTask = nil
                self.startScanNow(target)
            }
        }
    }

    private func cancelDeferredScanStart() {
        deferredScanStartID = nil
        deferredScanStartTask?.cancel()
        deferredScanStartTask = nil
    }

    private func startScanNow(_ target: ScanTarget) {
        let options = scanOptions(for: target)
        activeScanCacheKey = ScanCacheKey(target: target, options: options)
        scanCoordinator.startScan(target, options: options) {
            prepareForScan(target)
        }
    }

    func rescan() {
        guard let selectedTarget = scanCoordinator.selectedTarget else { return }
        startScan(selectedTarget)
    }

    func stopScan(resetState: Bool = true) {
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        scanCoordinator.stopScan(resetState: resetState)
    }

    func select(nodeID: String?) {
        navigationModel.select(nodeID: nodeID)
    }

    func focus(nodeID: String?) {
        navigationModel.focus(nodeID: nodeID)
    }

    func clearSelection() {
        navigationModel.clearSelection()
    }

    func zoomIntoSelection() {
        do {
            let node = try validatedSelection(requiresDirectory: true)
            guard navigationModel.canZoomIntoSelection else {
                if shouldPresentPackageContentsHint(for: node) {
                    throw FileActionError.packageContentsHidden(settingEnabled: treatPackagesAsDirectories)
                }
                throw FileActionError.directoryRequired
            }
            focus(nodeID: node.id)
        } catch {
            presentError(error)
        }
    }

    func navigateBack() {
        navigationModel.navigateBack()
    }

    func navigateForward() {
        navigationModel.navigateForward()
    }

    func resetFocusToRoot() {
        navigationModel.resetFocusToRoot()
    }

    func selectSidebarTarget(id: String?) {
        guard let id,
              let target = sidebarTarget(id: id) else {
            return
        }

        activeSidebarTargetID = target.id
        guard applyCachedOrContainedSidebarTarget(target) else { return }
        startScan(target)
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        guard isDirectoryURL(first) else {
            presentError(FileActionError.folderRequiredForDrop)
            return false
        }
        startScan(ScanTarget(url: first))
        return true
    }

    func revealSelectedInFinder() {
        do {
            let node = try validatedSelection()
            dependencies.systemActions.reveal(node.url)
        } catch {
            presentError(error)
        }
    }

    func revealTargetInFinder(_ target: ScanTarget) {
        dependencies.systemActions.reveal(target.url)
    }

    func openSelected() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.open(node.url)
        } catch {
            presentError(error)
        }
    }

    func previewSelectedWithQuickLook() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.quickLook.present(node.url)
        } catch {
            presentError(error)
        }
    }

    func toggleQuickLookForSelected() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.quickLook.toggle(node.url)
        } catch {
            presentError(error)
        }
    }

    func copySelectedPath() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.copyPath(node.url)
        } catch {
            presentError(error)
        }
    }

    func requestMoveSelectedToTrash() {
        do {
            let node = try validatedSelection()
            guard node.supportsMoveToTrash(activeTarget: scanCoordinator.selectedTarget) else {
                throw FileActionError.unsupported
            }
            pendingTrashNode = node
        } catch {
            presentError(error)
        }
    }

    func confirmMovePendingNodeToTrash() {
        guard let node = pendingTrashNode else { return }
        pendingTrashNode = nil

        do {
            guard dependencies.systemActions.fileExists(node.url) else {
                throw FileActionError.unavailable(path: node.url.path)
            }
            try dependencies.systemActions.moveToTrash(node.url)
            completedScanCache.removeAll()
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: scanCoordinator.selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                scanCoordinator.clearScan()
                navigationModel.reset()
                activeSidebarTargetID = nil
            case .rescanActiveScan:
                rescan()
            case .none:
                break
            }
            refreshAvailableTargets()
        } catch {
            presentError(error)
        }
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
    }

    func prepareAndOpenFullDiskAccessSettings() {
        guard dependencies.systemActions.prepareAndOpenFullDiskAccessSettings() else {
            presentError(FileActionError.fullDiskAccessSettingsUnavailable)
            return
        }
    }

    func prepareAndOpenFullDiskAccessSettingsFromOnboarding() {
        guard dependencies.systemActions.prepareAndOpenFullDiskAccessSettings() else {
            presentError(FileActionError.fullDiskAccessSettingsUnavailable)
            return
        }

        dependencies.preferences.markOnboardingIncomplete()
    }

    private func presentError(_ error: Error) {
        if let fileActionError = error as? FileActionError {
            lastActionErrorTitle = fileActionError.alertTitle
        } else {
            lastActionErrorTitle = nil
        }
        lastErrorMessage = error.localizedDescription
    }

    private func presentErrorMessage(_ message: String) {
        lastActionErrorTitle = nil
        lastErrorMessage = message
    }

    private func shouldPresentPackageContentsHint(for node: FileNodeRecord) -> Bool {
        node.isPackage && (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0)
    }

    private func validatedSelection(requiresDirectory: Bool = false) throws -> FileNodeRecord {
        guard let selectedNode = navigationModel.selectedNode else {
            throw FileActionError.noSelection
        }
        guard selectedNode.supportsFileActions else {
            throw FileActionError.unsupported
        }
        if requiresDirectory, !selectedNode.isDirectory {
            throw FileActionError.directoryRequired
        }
        guard dependencies.systemActions.fileExists(selectedNode.url) else {
            clearSelection()
            throw FileActionError.unavailable(path: selectedNode.url.path)
        }
        return selectedNode
    }

    private func syncVisibleQuickLookPreview() {
        guard dependencies.systemActions.quickLook.isPreviewVisible() else { return }

        guard let selectedNode = navigationModel.selectedNode,
              selectedNode.actionAvailability(activeTarget: scanCoordinator.selectedTarget).canPreviewWithQuickLook else {
            dependencies.systemActions.quickLook.close()
            return
        }

        dependencies.systemActions.quickLook.updateVisiblePreview(selectedNode.url)
    }

    private func installQuickLookKeyMonitor() {
        removeQuickLookKeyMonitor()
        quickLookEventMonitor = dependencies.systemActions.installQuickLookKeyMonitor { [weak self] event in
            let didHandleEvent = MainActor.assumeIsolated {
                self?.handleQuickLookKeyDown(event) == true
            }
            return didHandleEvent
        }
    }

    private func removeQuickLookKeyMonitor() {
        quickLookEventMonitor?.remove()
        quickLookEventMonitor = nil
    }

    private func handleQuickLookKeyDown(_ event: NSEvent) -> Bool {
        guard Self.isPlainSpaceKey(event) else { return false }
        guard !showsOnboarding, pendingTrashNode == nil else { return false }
        guard !dependencies.systemActions.quickLook.isPreviewPanelKeyWindow() else { return false }
        guard !Self.shouldPreserveSpaceKey(for: event.window?.firstResponder) else { return false }
        guard navigationModel.selectedNode?.actionAvailability(
            activeTarget: scanCoordinator.selectedTarget
        ).canPreviewWithQuickLook == true else { return false }

        toggleQuickLookForSelected()
        return true
    }

    private static func isPlainSpaceKey(_ event: NSEvent) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return false }
        return event.keyCode == 49 || event.charactersIgnoringModifiers == " "
    }

    private static func shouldPreserveSpaceKey(for responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if responder is NSTextView || responder is NSTextField || responder is NSButton {
            return true
        }

        if responder is NSTableView || responder is NSOutlineView || responder is NSCollectionView {
            return false
        }

        return responder is NSControl
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        dependencies.systemActions.isExistingDirectory(url)
    }

    private func prepareForScan(_ target: ScanTarget) {
        lastErrorMessage = nil
        navigationModel.reset()
        pendingTrashNode = nil
        activeSidebarTargetID = target.id

        registerRecentTarget(target)
        refreshAvailableTargets()
    }

    private func scanOptions(
        for target: ScanTarget,
        autoSummarizeDirectories: Bool? = nil
    ) -> ScanOptions {
        ScanOptions(
            includeHiddenFiles: showHiddenFiles || target.kind == .volume,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            autoSummarizeDirectories: autoSummarizeDirectories ?? self.autoSummarizeDirectories
        )
    }

    private func registerRecentTarget(_ target: ScanTarget) {
        recentTargets = dependencies.recentTargets.record(target, currentTargets: recentTargets)
    }

    private var preferredSmartTargetPaths: [String] {
        dependencies.systemActions.preferredSmartTargetIDs()
    }

    private func refreshAvailableTargets() {
        availableTargets = dependencies.systemActions.defaultTargets()
    }

    private func observeNavigationModel() {
        navigationModel.onSelectionChanged = { [weak self] in
            self?.syncVisibleQuickLookPreview()
        }
    }

    private func observeScanCoordinator() {
        scanCoordinator.$snapshot
            .sink { [weak self] snapshot in
                self?.navigationModel.updateScanContext(snapshot: snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$completedScanSnapshot
            .compactMap { $0 }
            .sink { [weak self] snapshot in
                self?.handleCompletedScanSnapshot(snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$scanErrorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.presentErrorMessage(message)
            }
            .store(in: &cancellables)
    }

    private func handleCompletedScanSnapshot(_ snapshot: ScanSnapshot) {
        navigationModel.reconcileAfterSnapshotApplied(snapshot)

        defer {
            activeScanCacheKey = nil
        }

        guard let cacheKey = activeScanCacheKey,
              cacheKey.targetID == snapshot.target.id else {
            return
        }

        completedScanCache.store(snapshot, for: cacheKey)
    }

    private func applyCachedOrContainedSidebarTarget(_ target: ScanTarget) -> Bool {
        if focusSidebarTargetIfContained(target) {
            return false
        }

        let cacheKey = ScanCacheKey(target: target, options: scanOptions(for: target))
        if let cachedSnapshot = completedScanCache.snapshot(for: cacheKey),
           scanCoordinator.snapshot?.id != cachedSnapshot.id {
            restoreCachedSnapshot(cachedSnapshot)
            return false
        }

        return true
    }

    private func restoreCachedSnapshot(_ snapshot: ScanSnapshot) {
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForScan(snapshot.target)
        }
    }

    private func focusSidebarTargetIfContained(_ target: ScanTarget) -> Bool {
        guard scanCoordinator.snapshot?.treeStore.node(id: target.id) != nil else {
            return false
        }

        cancelDeferredScanStart()
        activeScanCacheKey = nil
        lastErrorMessage = nil
        pendingTrashNode = nil
        navigationModel.focus(nodeID: target.id)
        return true
    }

    private func sidebarTarget(id: String) -> ScanTarget? {
        (availableTargets + recentScanTargets).first { $0.id == id }
    }

    private func observeMountedVolumes() {
        dependencies.systemActions.mountedVolumeEvents()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableTargets()
            }
            .store(in: &cancellables)
    }

    private func observePreferences() {
        $showHiddenFiles
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(showHiddenFiles: value) }
            .store(in: &cancellables)

        $treatPackagesAsDirectories
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(treatPackagesAsDirectories: value) }
            .store(in: &cancellables)

        $maxRenderedDepth
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(maxRenderedDepth: value) }
            .store(in: &cancellables)

        $autoSummarizeDirectories
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(autoSummarizeDirectories: value) }
            .store(in: &cancellables)
    }

    private func persistScanPreferences(
        showHiddenFiles: Bool? = nil,
        treatPackagesAsDirectories: Bool? = nil,
        maxRenderedDepth: Int? = nil,
        autoSummarizeDirectories: Bool? = nil
    ) {
        dependencies.preferences.saveScanPreferences(
            AppScanPreferences(
                showHiddenFiles: showHiddenFiles ?? self.showHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories ?? self.treatPackagesAsDirectories,
                maxRenderedDepth: maxRenderedDepth ?? self.maxRenderedDepth,
                autoSummarizeDirectories: autoSummarizeDirectories ?? self.autoSummarizeDirectories
            )
        )
    }
}
