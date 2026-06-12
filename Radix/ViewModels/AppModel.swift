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
        private let minimumRetainedSnapshotCount: Int
        private let maxTotalNodeCount: Int
        private var snapshotsByKey: [ScanCacheKey: ScanSnapshot] = [:]
        private var nodeCountsByKey: [ScanCacheKey: Int] = [:]
        private var keysByRecency: [ScanCacheKey] = []

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

            snapshotsByKey[key] = snapshot
            nodeCountsByKey[key] = nodeCount
            markRecentlyUsed(key)
            trimToBudget()
        }

        mutating func removeAll() {
            snapshotsByKey.removeAll()
            nodeCountsByKey.removeAll()
            keysByRecency.removeAll()
        }

        private mutating func markRecentlyUsed(_ key: ScanCacheKey) {
            keysByRecency.removeAll { $0 == key }
            keysByRecency.append(key)
        }

        private var totalNodeCount: Int {
            nodeCountsByKey.values.reduce(0, +)
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
            snapshotsByKey[key] = nil
            nodeCountsByKey[key] = nil
            keysByRecency.removeAll { $0 == key }
        }
    }

    private enum NavigationAction: Sendable {
        case select(FileNodeRecord.ID?)
        case focus(FileNodeRecord.ID?)
        case selectAndFocus(FileNodeRecord.ID)
        case navigateBack
        case navigateForward
        case resetFocusToRoot
        case clearSelection
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
    @Published var useScanExclusions = false
    @Published var exclusionPatterns = AppScanPreferences.defaults.exclusionPatterns
    @Published private(set) var availableTargets: [ScanTarget] = [] {
        didSet {
            refreshSidebarTargetSections()
        }
    }
    @Published var recentTargets: [ScanTarget] = [] {
        didSet {
            refreshSidebarTargetSections()
        }
    }
    @Published var showsOnboarding: Bool
    @Published private(set) var fullDiskAccessStatus: FullDiskAccessStatus
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
    private let sidebarModel: SidebarModel
    private let snapshotTransformService = ScanSnapshotTransformService()
    private let navigationModel = WorkspaceNavigationModel()
    private var lastActionErrorTitle: String?
    private var completedScanCache: CompletedScanCache
    private var activeScanCacheKey: ScanCacheKey?
    private var displayedScanCacheKey: ScanCacheKey?

    private var cancellables = Set<AnyCancellable>()
    private var quickLookEventMonitor: AppEventMonitorToken?
    private var workspaceWindowNumber: Int?
    private var deferredScanStartTask: Task<Void, Never>?
    private var deferredScanStartID: UUID?
    private var deferredSidebarSelectionTask: Task<Void, Never>?
    private var deferredSidebarSelectionID: UUID?
    private var deferredNavigationActionTask: Task<Void, Never>?
    private var deferredNavigationActionID: UUID?
    private var sidebarScopeTask: Task<Void, Never>?
    private var sidebarScopeID: UUID?
    private var fullDiskAccessRefreshTask: Task<Void, Never>?
    private var targetCapacityDescriptionsRefreshTask: Task<Void, Never>?

    init(
        dependencies: AppDependencies = .live,
        completedScanCacheMinimumRetainedSnapshotCount: Int = 2,
        completedScanCacheMaxTotalNodeCount: Int = 250_000
    ) {
        self.dependencies = dependencies
        self.scanCoordinator = ScanCoordinator(scanService: dependencies.scanService)
        self.sidebarModel = SidebarModel(
            recentTargetStore: dependencies.recentTargets,
            preferredSmartTargetIDs: dependencies.systemActions.preferredSmartTargetIDs
        )
        self.completedScanCache = CompletedScanCache(
            minimumRetainedSnapshotCount: completedScanCacheMinimumRetainedSnapshotCount,
            maxTotalNodeCount: completedScanCacheMaxTotalNodeCount
        )

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        useScanExclusions = preferences.scan.useScanExclusions
        exclusionPatterns = preferences.scan.exclusionPatterns
        showsOnboarding = !preferences.didCompleteOnboarding
        fullDiskAccessStatus = dependencies.systemActions.usesAsyncFullDiskAccessStatus
            ? .unknown
            : dependencies.systemActions.currentFullDiskAccessStatus()
        recentTargets = dependencies.recentTargets.loadAvailableTargets()

        refreshAvailableTargets()
        refreshSidebarTargetSections()
        if dependencies.systemActions.usesAsyncFullDiskAccessStatus {
            refreshFullDiskAccessStatus()
        }
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
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelSidebarScopeTask()
        fullDiskAccessRefreshTask?.cancel()
        fullDiskAccessRefreshTask = nil
        targetCapacityDescriptionsRefreshTask?.cancel()
        targetCapacityDescriptionsRefreshTask = nil
        activeScanCacheKey = nil
        displayedScanCacheKey = nil
        workspaceWindowNumber = nil
        scanCoordinator.stopScan()
        removeQuickLookKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        activeScanCacheKey = nil
        if scanCoordinator.canStopScan {
            scanCoordinator.stopScan()
        } else {
            scanCoordinator.stopScan(resetState: false)
        }
        dependencies.systemActions.quickLook.close()
    }

    func suspendBackgroundActivity() {
        dependencies.systemActions.quickLook.close()
    }

    var scanState: ScanCoordinator {
        scanCoordinator
    }

    var navigation: WorkspaceNavigationModel {
        navigationModel
    }

    var sidebar: SidebarModel {
        sidebarModel
    }

    var startupDiskTarget: ScanTarget? {
        availableTargets.first(where: { $0.kind == .volume && $0.url.path == "/" })
    }

    var smartTargets: [ScanTarget] {
        sidebarModel.smartTargets
    }

    var recentScanTargets: [ScanTarget] {
        sidebarModel.recentScanTargets
    }

    var activeSidebarTargetID: String? {
        sidebarModel.activeTargetID
    }

    var targetCapacityDescriptions: [String: String] {
        sidebarModel.targetCapacityDescriptions
    }

    private func refreshSidebarTargetSections() {
        sidebarModel.refreshTargetSections(
            availableTargets: availableTargets,
            recentTargets: recentTargets
        )
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
        fullDiskAccessRefreshTask?.cancel()

        guard dependencies.systemActions.usesAsyncFullDiskAccessStatus else {
            fullDiskAccessStatus = dependencies.systemActions.currentFullDiskAccessStatus()
            fullDiskAccessRefreshTask = nil
            return
        }

        fullDiskAccessRefreshTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.dependencies.systemActions.loadCurrentFullDiskAccessStatus()
            guard !Task.isCancelled else { return }
            self.fullDiskAccessStatus = status
            self.fullDiskAccessRefreshTask = nil
        }
    }

    func restoreDefaultPreferences() {
        showHiddenFiles = AppScanPreferences.defaults.showHiddenFiles
        treatPackagesAsDirectories = AppScanPreferences.defaults.treatPackagesAsDirectories
        maxRenderedDepth = AppScanPreferences.defaults.maxRenderedDepth
        autoSummarizeDirectories = AppScanPreferences.defaults.autoSummarizeDirectories
        useScanExclusions = AppScanPreferences.defaults.useScanExclusions
        exclusionPatterns = AppScanPreferences.defaults.exclusionPatterns
    }

    func clearRecentTargets() {
        recentTargets.removeAll()
        dependencies.recentTargets.clear()
    }

    func removeRecentTarget(_ target: ScanTarget) {
        recentTargets = dependencies.recentTargets.remove(target, currentTargets: recentTargets)
        sidebarModel.clearActiveTargetIfNeededAfterRemovingRecentTarget(target)
    }

    /// Expands an auto-summarized directory by scanning it fully and replacing the node in the tree.
    func expandSummarizedNode(_ node: FileNodeRecord, completion: @escaping () -> Void) {
        let target = ScanTarget(url: node.url)
        let options = scanOptions(
            for: target,
            autoSummarizeDirectories: false,
            preferredExclusionRootPath: currentScanExclusionRootPath
        )

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
        cancelDeferredSidebarSelection()
        cancelSidebarScopeTask()

        let scanStartID = UUID()
        deferredScanStartID = scanStartID
        deferredScanStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1))
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

    private func cancelDeferredScanStart() {
        deferredScanStartID = nil
        deferredScanStartTask?.cancel()
        deferredScanStartTask = nil
    }

    private func cancelDeferredSidebarSelection() {
        deferredSidebarSelectionID = nil
        deferredSidebarSelectionTask?.cancel()
        deferredSidebarSelectionTask = nil
    }

    private func cancelDeferredNavigationAction() {
        deferredNavigationActionID = nil
        deferredNavigationActionTask?.cancel()
        deferredNavigationActionTask = nil
    }

    private func cancelSidebarScopeTask() {
        sidebarScopeID = nil
        sidebarScopeTask?.cancel()
        sidebarScopeTask = nil
    }

    private func startScanNow(_ target: ScanTarget) {
        let options = scanOptions(for: target)
        activeScanCacheKey = ScanCacheKey(target: target, options: options)
        displayedScanCacheKey = nil
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
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelSidebarScopeTask()
        activeScanCacheKey = nil
        if resetState, scanCoordinator.snapshot == nil {
            displayedScanCacheKey = nil
        }
        scanCoordinator.stopScan(resetState: resetState)
    }

    func select(nodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.select(nodeID))
    }

    func selectAfterViewUpdate(nodeID: String?) {
        scheduleDeferredNavigationAction(.select(nodeID))
    }

    func focus(nodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.focus(nodeID))
    }

    func focusAfterViewUpdate(nodeID: String?) {
        scheduleDeferredNavigationAction(.focus(nodeID))
    }

    func selectAndFocusAfterViewUpdate(nodeID: String) {
        scheduleDeferredNavigationAction(.selectAndFocus(nodeID))
    }

    func clearSelection() {
        cancelDeferredNavigationAction()
        performNavigationAction(.clearSelection)
    }

    func setWorkspaceWindowNumber(_ windowNumber: Int?) {
        workspaceWindowNumber = windowNumber
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
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateBack)
    }

    func navigateForward() {
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateForward)
    }

    func resetFocusToRoot() {
        cancelDeferredNavigationAction()
        performNavigationAction(.resetFocusToRoot)
    }

    private func scheduleDeferredNavigationAction(_ action: NavigationAction) {
        cancelDeferredNavigationAction()

        let actionID = UUID()
        deferredNavigationActionID = actionID
        deferredNavigationActionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1))
            guard let self,
                  self.deferredNavigationActionID == actionID,
                  !Task.isCancelled else {
                return
            }

            self.deferredNavigationActionID = nil
            self.deferredNavigationActionTask = nil
            self.performNavigationAction(action)
        }
    }

    private func performNavigationAction(_ action: NavigationAction) {
        switch action {
        case .select(let nodeID):
            navigationModel.select(nodeID: nodeID)
        case .focus(let nodeID):
            navigationModel.focus(nodeID: nodeID)
        case .selectAndFocus(let nodeID):
            navigationModel.selectAndFocus(nodeID: nodeID)
        case .navigateBack:
            navigationModel.navigateBack()
        case .navigateForward:
            navigationModel.navigateForward()
        case .resetFocusToRoot:
            navigationModel.resetFocusToRoot()
        case .clearSelection:
            navigationModel.clearSelection()
        }
    }

    func selectSidebarTarget(id: String?) {
        cancelDeferredSidebarSelection()
        selectSidebarTargetNow(id: id)
    }

    func selectSidebarTargetAfterViewUpdate(id: String?) {
        cancelDeferredSidebarSelection()

        let selectionID = UUID()
        deferredSidebarSelectionID = selectionID
        deferredSidebarSelectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1))
            guard let self,
                  self.deferredSidebarSelectionID == selectionID,
                  !Task.isCancelled else {
                return
            }

            self.deferredSidebarSelectionID = nil
            self.deferredSidebarSelectionTask = nil
            self.selectSidebarTargetNow(id: id)
        }
    }

    private func selectSidebarTargetNow(id: String?) {
        guard let id,
              let target = sidebarTarget(id: id) else {
            return
        }

        cancelSidebarScopeTask()
        sidebarModel.setActiveTargetID(target.id)
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
                sidebarModel.setActiveTargetID(nil)
                displayedScanCacheKey = nil
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
        guard isWorkspaceKeyEvent(event) else { return false }
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

    private func isWorkspaceKeyEvent(_ event: NSEvent) -> Bool {
        guard let workspaceWindowNumber else { return false }
        return event.windowNumber == workspaceWindowNumber
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
        sidebarModel.setActiveTargetID(target.id)

        registerRecentTarget(target)
        refreshAvailableTargets()
    }

    private func scanOptions(
        for target: ScanTarget,
        autoSummarizeDirectories: Bool? = nil,
        preferredExclusionRootPath: String? = nil
    ) -> ScanOptions {
        let exclusionPatterns = activeExclusionPatterns
        return ScanOptions(
            includeHiddenFiles: showHiddenFiles || target.kind == .volume,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            autoSummarizeDirectories: autoSummarizeDirectories ?? self.autoSummarizeDirectories,
            exclusionPatterns: exclusionPatterns,
            exclusionRootPath: exclusionRootPath(
                for: target,
                patterns: exclusionPatterns,
                preferredRootPath: preferredExclusionRootPath
            )
        )
    }

    private var activeExclusionPatterns: [String] {
        guard useScanExclusions else { return [] }
        return ScanExclusionMatcher.normalizedPatterns(exclusionPatterns)
    }

    private var currentScanExclusionRootPath: String? {
        displayedScanCacheKey?.options.exclusionRootPath
            ?? activeScanCacheKey?.options.exclusionRootPath
            ?? scanCoordinator.snapshot?.target.url.path
    }

    private func exclusionRootPath(
        for target: ScanTarget,
        patterns: [String],
        preferredRootPath: String?
    ) -> String? {
        guard !patterns.isEmpty,
              ScanExclusionMatcher.patternsRequirePathScopedRoot(patterns) else {
            return nil
        }

        return ScanExclusionMatcher.normalizedRootPath(preferredRootPath ?? target.url.path)
    }

    private func registerRecentTarget(_ target: ScanTarget) {
        recentTargets = dependencies.recentTargets.record(target, currentTargets: recentTargets)
    }

    private func refreshAvailableTargets() {
        targetCapacityDescriptionsRefreshTask?.cancel()
        availableTargets = dependencies.systemActions.defaultTargets()

        guard dependencies.systemActions.usesAsyncTargetCapacityDescriptions else {
            sidebarModel.replaceTargetCapacityDescriptions(
                dependencies.systemActions.currentTargetCapacityDescriptions()
            )
            targetCapacityDescriptionsRefreshTask = nil
            return
        }

        targetCapacityDescriptionsRefreshTask = Task { [weak self] in
            guard let self else { return }
            let descriptions = await self.dependencies.systemActions.loadCurrentTargetCapacityDescriptions()
            guard !Task.isCancelled else { return }
            self.sidebarModel.replaceTargetCapacityDescriptions(descriptions)
            self.targetCapacityDescriptionsRefreshTask = nil
        }
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
        displayedScanCacheKey = cacheKey
    }

    private func applyCachedOrContainedSidebarTarget(_ target: ScanTarget) -> Bool {
        let options = scanOptions(for: target)

        if scheduleContainedSidebarTargetRestore(target, options: options, from: scanCoordinator.snapshot) {
            return false
        }

        let cacheKey = ScanCacheKey(target: target, options: options)
        if let cachedSnapshot = completedScanCache.snapshot(for: cacheKey),
           scanCoordinator.snapshot?.id != cachedSnapshot.id {
            restoreCachedSnapshot(cachedSnapshot)
            return false
        }

        if let containingSnapshot = completedScanCache.snapshot(containing: target, options: options),
           scheduleContainedSidebarTargetRestore(target, options: options, from: containingSnapshot) {
            return false
        }

        return true
    }

    private func restoreCachedSnapshot(_ snapshot: ScanSnapshot) {
        cancelSidebarScopeTask()
        cancelDeferredScanStart()
        activeScanCacheKey = nil
        displayedScanCacheKey = ScanCacheKey(target: snapshot.target, options: scanOptions(for: snapshot.target))
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForScan(snapshot.target)
        }
    }

    private func scheduleContainedSidebarTargetRestore(
        _ target: ScanTarget,
        options: ScanOptions,
        from containingSnapshot: ScanSnapshot?
    ) -> Bool {
        guard let containingSnapshot,
              containingSnapshot.target.id != target.id,
              canScope(containingSnapshot, using: options),
              containingSnapshot.treeStore.node(id: target.id) != nil else {
            return false
        }

        cancelDeferredScanStart()
        let scopeID = UUID()
        sidebarScopeID = scopeID
        sidebarScopeTask = Task { [weak self, snapshotTransformService] in
            do {
                let scopedSnapshot = try await snapshotTransformService.scopedSnapshot(containingSnapshot, to: target)
                try Task.checkCancellation()
                guard let self,
                      sidebarScopeID == scopeID,
                      sidebarModel.activeTargetID == target.id else {
                    return
                }

                sidebarScopeID = nil
                sidebarScopeTask = nil
                guard let scopedSnapshot else {
                    startScan(target)
                    return
                }

                restoreScopedSidebarTarget(scopedSnapshot, target: target, options: options)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      sidebarScopeID == scopeID,
                      sidebarModel.activeTargetID == target.id else {
                    return
                }

                sidebarScopeID = nil
                sidebarScopeTask = nil
                startScan(target)
            }
        }
        return true
    }

    private func restoreScopedSidebarTarget(
        _ scopedSnapshot: ScanSnapshot,
        target: ScanTarget,
        options: ScanOptions
    ) {
        activeScanCacheKey = nil
        displayedScanCacheKey = ScanCacheKey(target: target, options: options)
        lastErrorMessage = nil
        pendingTrashNode = nil
        scanCoordinator.restoreCompletedSnapshot(scopedSnapshot) {
            prepareForScan(target)
        }
    }

    private func canScope(_ snapshot: ScanSnapshot, using options: ScanOptions) -> Bool {
        guard scanCoordinator.snapshot?.id == snapshot.id else {
            return true
        }

        return displayedScanCacheKey?.options == options
    }

    private func sidebarTarget(id: String) -> ScanTarget? {
        sidebarModel.target(id: id)
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

        $useScanExclusions
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(useScanExclusions: value) }
            .store(in: &cancellables)

        $exclusionPatterns
            .dropFirst()
            .sink { [weak self] value in self?.persistScanPreferences(exclusionPatterns: value) }
            .store(in: &cancellables)
    }

    private func persistScanPreferences(
        showHiddenFiles: Bool? = nil,
        treatPackagesAsDirectories: Bool? = nil,
        maxRenderedDepth: Int? = nil,
        autoSummarizeDirectories: Bool? = nil,
        useScanExclusions: Bool? = nil,
        exclusionPatterns: [String]? = nil
    ) {
        dependencies.preferences.saveScanPreferences(
            AppScanPreferences(
                showHiddenFiles: showHiddenFiles ?? self.showHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories ?? self.treatPackagesAsDirectories,
                maxRenderedDepth: maxRenderedDepth ?? self.maxRenderedDepth,
                autoSummarizeDirectories: autoSummarizeDirectories ?? self.autoSummarizeDirectories,
                useScanExclusions: useScanExclusions ?? self.useScanExclusions,
                exclusionPatterns: exclusionPatterns ?? self.exclusionPatterns
            )
        )
    }
}
