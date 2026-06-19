//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    private struct PostTrashRemovalRequest: Sendable {
        let nodeID: FileNodeRecord.ID
        let fallbackFocusID: FileNodeRecord.ID?
    }

    struct PendingTrashSelection {
        let nodes: [FileNodeRecord]
    }

    private enum NavigationAction: Sendable {
        case select(FileNodeRecord.ID?)
        case selectMultiple(Set<FileNodeRecord.ID>, primary: FileNodeRecord.ID?)
        case focus(FileNodeRecord.ID?)
        case selectAndFocus(FileNodeRecord.ID)
        case navigateBack
        case navigateForward
        case navigateToParent
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
    @Published var scanCloudStorageFolders = false
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
    @Published var pendingTrashSelection: PendingTrashSelection?

    private let dependencies: AppDependencies
    private let scanCoordinator: ScanCoordinator
    private let sidebarModel: SidebarModel
    private let quickLookController: AppQuickLookController
    private let navigationModel = WorkspaceNavigationModel()
    private var lastActionErrorTitle: String?
    private let sidebarScanCacheController: SidebarScanCacheController
    private var lastPersistedScanPreferences: AppScanPreferences?

    private static let viewUpdateDeferralDelay: Duration = .milliseconds(1)
    private static let scanPreferencePersistenceDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(50)
    private static let postTrashRescanDelay: Duration = .seconds(1)

    private var cancellables = Set<AnyCancellable>()
    private var deferredScanStartTask: Task<Void, Never>?
    private var deferredScanStartID: UUID?
    private var deferredSidebarSelectionTask: Task<Void, Never>?
    private var deferredSidebarSelectionID: UUID?
    private var deferredNavigationActionTask: Task<Void, Never>?
    private var deferredNavigationActionID: UUID?
    private var postTrashRescanTask: Task<Void, Never>?
    private var postTrashRescanID: UUID?
    private var postTrashRemovalTask: Task<Void, Never>?
    private var postTrashRemovalRequests: [PostTrashRemovalRequest] = []
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
        self.quickLookController = AppQuickLookController(systemActions: dependencies.systemActions)
        self.sidebarScanCacheController = SidebarScanCacheController(
            minimumRetainedSnapshotCount: completedScanCacheMinimumRetainedSnapshotCount,
            maxTotalNodeCount: completedScanCacheMaxTotalNodeCount
        )

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        scanCloudStorageFolders = preferences.scan.scanCloudStorageFolders
        useScanExclusions = preferences.scan.useScanExclusions
        exclusionPatterns = preferences.scan.exclusionPatterns
        lastPersistedScanPreferences = preferences.scan
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
        quickLookController.delegate = self
        observeNavigationModel()
        observeScanCoordinator()
        observeMountedVolumes()
        observePreferences()
        quickLookController.installKeyMonitor()
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    func cleanup() {
        flushPendingScanPreferences()
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelPostTrashSnapshotRemoval()
        cancelPostTrashRescan()
        sidebarScanCacheController.resetTransientState()
        fullDiskAccessRefreshTask?.cancel()
        fullDiskAccessRefreshTask = nil
        targetCapacityDescriptionsRefreshTask?.cancel()
        targetCapacityDescriptionsRefreshTask = nil
        quickLookController.setWorkspaceWindowNumber(nil)
        scanCoordinator.stopScan()
        quickLookController.removeKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelPostTrashSnapshotRemoval()
        cancelPostTrashRescan()
        sidebarScanCacheController.clearActiveScanTracking()
        if scanCoordinator.canStopScan {
            scanCoordinator.stopScan()
        } else {
            scanCoordinator.stopScan(resetState: false)
        }
        quickLookController.closePreview()
    }

    func suspendBackgroundActivity() {
        cancelPostTrashRescan()
        quickLookController.closePreview()
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
        scanCloudStorageFolders = AppScanPreferences.defaults.scanCloudStorageFolders
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
        cancelPostTrashSnapshotRemoval()
        cancelPostTrashRescan()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()

        scheduleDeferredViewUpdate(
            id: \.deferredScanStartID,
            task: \.deferredScanStartTask
        ) { model in
            model.startScanNow(target)
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

    private func cancelPostTrashSnapshotRemoval() {
        postTrashRemovalRequests.removeAll()
        postTrashRemovalTask?.cancel()
        postTrashRemovalTask = nil
    }

    private func cancelPostTrashRescan() {
        postTrashRescanID = nil
        postTrashRescanTask?.cancel()
        postTrashRescanTask = nil
    }

    private func scheduleDeferredViewUpdate(
        id idKeyPath: ReferenceWritableKeyPath<AppModel, UUID?>,
        task taskKeyPath: ReferenceWritableKeyPath<AppModel, Task<Void, Never>?>,
        perform: @MainActor @Sendable @escaping (AppModel) -> Void
    ) {
        let actionID = UUID()
        self[keyPath: idKeyPath] = actionID
        self[keyPath: taskKeyPath] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.viewUpdateDeferralDelay)
            guard let self,
                  self[keyPath: idKeyPath] == actionID,
                  !Task.isCancelled else {
                return
            }

            self[keyPath: idKeyPath] = nil
            self[keyPath: taskKeyPath] = nil
            perform(self)
        }
    }

    private func startScanNow(_ target: ScanTarget) {
        let options = scanOptions(for: target)
        sidebarScanCacheController.prepareForScanStart(target: target, options: options)
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
        cancelPostTrashSnapshotRemoval()
        cancelPostTrashRescan()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
        sidebarScanCacheController.clearActiveScanTracking()
        if resetState, scanCoordinator.snapshot == nil {
            sidebarModel.setActiveTargetID(nil)
            sidebarScanCacheController.clearDisplayedSnapshot()
        }
        scanCoordinator.stopScan(resetState: resetState)
    }

    func select(nodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.select(nodeID))
    }

    func select(nodeIDs: Set<String>, primaryNodeID: String?) {
        cancelDeferredNavigationAction()
        performNavigationAction(.selectMultiple(nodeIDs, primary: primaryNodeID))
    }

    func selectAfterViewUpdate(nodeID: String?) {
        scheduleDeferredNavigationAction(.select(nodeID))
    }

    func selectAfterViewUpdate(nodeIDs: Set<String>, primaryNodeID: String?) {
        scheduleDeferredNavigationAction(.selectMultiple(nodeIDs, primary: primaryNodeID))
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
        quickLookController.setWorkspaceWindowNumber(windowNumber)
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

    func navigateToParent() {
        cancelDeferredNavigationAction()
        performNavigationAction(.navigateToParent)
    }

    func resetFocusToRoot() {
        cancelDeferredNavigationAction()
        performNavigationAction(.resetFocusToRoot)
    }

    private func scheduleDeferredNavigationAction(_ action: NavigationAction) {
        cancelDeferredNavigationAction()

        scheduleDeferredViewUpdate(
            id: \.deferredNavigationActionID,
            task: \.deferredNavigationActionTask
        ) { model in
            model.performNavigationAction(action)
        }
    }

    private func performNavigationAction(_ action: NavigationAction) {
        switch action {
        case .select(let nodeID):
            navigationModel.select(nodeID: nodeID)
        case .selectMultiple(let nodeIDs, let primary):
            navigationModel.select(nodeIDs: nodeIDs, primaryNodeID: primary)
        case .focus(let nodeID):
            navigationModel.focus(nodeID: nodeID)
        case .selectAndFocus(let nodeID):
            navigationModel.selectAndFocus(nodeID: nodeID)
        case .navigateBack:
            navigationModel.navigateBack()
        case .navigateForward:
            navigationModel.navigateForward()
        case .navigateToParent:
            navigationModel.navigateToParent()
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

        scheduleDeferredViewUpdate(
            id: \.deferredSidebarSelectionID,
            task: \.deferredSidebarSelectionTask
        ) { model in
            model.selectSidebarTargetNow(id: id)
        }
    }

    private func selectSidebarTargetNow(id: String?) {
        guard let id,
              let target = sidebarTarget(id: id) else {
            return
        }

        if scanCoordinator.selectedTarget?.id != target.id {
            cancelPostTrashSnapshotRemoval()
            cancelPostTrashRescan()
        }
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
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
            let nodes = try validatedSelectedNodes()
            if let node = nodes.first, nodes.count == 1 {
                dependencies.systemActions.reveal(node.url)
            } else {
                dependencies.systemActions.revealMany(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func revealPrimarySelectionInFinder() {
        do {
            let node = try validatedSelection()
            dependencies.systemActions.reveal(node.url)
        } catch {
            presentError(error)
        }
    }

    func revealNodesInFinder(_ nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodes(nodes)
            if let node = nodes.first, nodes.count == 1 {
                dependencies.systemActions.reveal(node.url)
            } else {
                dependencies.systemActions.revealMany(nodes.map(\.url))
            }
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
        quickLookController.previewSelected()
    }

    func toggleQuickLookForSelected() {
        quickLookController.toggleSelected()
    }

    func copySelectedPath() {
        do {
            let nodes = try validatedSelectedNodes()
            if let node = nodes.first, nodes.count == 1 {
                try dependencies.systemActions.copyPath(node.url)
            } else {
                try dependencies.systemActions.copyPaths(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func copyPrimarySelectionPath() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.copyPath(node.url)
        } catch {
            presentError(error)
        }
    }

    func copyPaths(for nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodes(nodes)
            if let node = nodes.first, nodes.count == 1 {
                try dependencies.systemActions.copyPath(node.url)
            } else {
                try dependencies.systemActions.copyPaths(nodes.map(\.url))
            }
        } catch {
            presentError(error)
        }
    }

    func requestMoveSelectedToTrash() {
        requestMoveNodesToTrash(navigationModel.selectedNodes)
    }

    func requestMovePrimarySelectionToTrash() {
        do {
            let node = try validatedSelection()
            guard node.supportsMoveToTrash(
                activeTarget: scanCoordinator.selectedTarget,
                trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
            ) else {
                throw FileActionError.unsupported
            }

            pendingTrashNode = node
            pendingTrashSelection = PendingTrashSelection(nodes: [node])
        } catch {
            presentError(error)
        }
    }

    func requestMoveNodesToTrash(_ nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodes(nodes)
            guard nodes.allSatisfy({ node in
                node.supportsMoveToTrash(
                    activeTarget: scanCoordinator.selectedTarget,
                    trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
                )
            }) else {
                throw FileActionError.unsupported
            }

            let trashNodes = topLevelTrashNodes(from: nodes)
            pendingTrashNode = trashNodes.first
            pendingTrashSelection = PendingTrashSelection(nodes: trashNodes)
        } catch {
            presentError(error)
        }
    }

    func confirmMovePendingNodeToTrash() {
        confirmMovePendingSelectionToTrash()
    }

    func confirmMovePendingSelectionToTrash() {
        let nodes = pendingTrashSelection?.nodes ?? pendingTrashNode.map { [$0] }
        guard let nodes, !nodes.isEmpty else { return }
        pendingTrashNode = nil
        self.pendingTrashSelection = nil

        var movedNodes: [FileNodeRecord] = []
        var actionError: Error?

        for node in nodes {
            guard dependencies.systemActions.fileExists(node.url) else {
                actionError = FileActionError.unavailable(path: node.url.path)
                break
            }

            do {
                try dependencies.systemActions.moveToTrash(node.url)
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        if !movedNodes.isEmpty {
            sidebarScanCacheController.clearCache()
            handleMovedToTrash(movedNodes)
            refreshAvailableTargets()
        }

        if let actionError {
            presentError(actionError)
        }
    }

    private func handleMovedToTrash(_ nodes: [FileNodeRecord]) {
        var shouldClearActiveScan = false
        var shouldRescan = false

        for node in nodes {
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: scanCoordinator.selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                shouldClearActiveScan = true
            case .removeFromActiveScan:
                enqueuePostTrashSnapshotRemoval(
                    nodeID: node.id,
                    fallbackFocusID: postTrashFocusFallbackID(for: node)
                )
                shouldRescan = true
            case .none:
                break
            }
        }

        if shouldClearActiveScan {
            cancelPostTrashSnapshotRemoval()
            cancelPostTrashRescan()
            scanCoordinator.clearScan()
            navigationModel.reset()
            sidebarModel.setActiveTargetID(nil)
            sidebarScanCacheController.clearDisplayedSnapshot()
        } else if shouldRescan, let selectedTarget = scanCoordinator.selectedTarget {
            schedulePostTrashRescan(for: selectedTarget)
        }
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
        pendingTrashSelection = nil
    }

    private func postTrashFocusFallbackID(for node: FileNodeRecord) -> FileNodeRecord.ID? {
        guard let treeStore = scanCoordinator.fileTreeStore,
              treeStore.isAncestor(node.id, of: navigationModel.focusedNodeID) else {
            return nil
        }

        return treeStore.parent(of: node.id)?.id ?? treeStore.root.id
    }

    private func enqueuePostTrashSnapshotRemoval(
        nodeID: FileNodeRecord.ID,
        fallbackFocusID: FileNodeRecord.ID?
    ) {
        postTrashRemovalRequests.append(PostTrashRemovalRequest(
            nodeID: nodeID,
            fallbackFocusID: fallbackFocusID
        ))
        startPostTrashSnapshotRemovalIfNeeded()
    }

    private func startPostTrashSnapshotRemovalIfNeeded() {
        guard postTrashRemovalTask == nil else { return }

        postTrashRemovalTask = Task { @MainActor [weak self] in
            while let self, !self.postTrashRemovalRequests.isEmpty {
                if Task.isCancelled {
                    self.postTrashRemovalRequests.removeAll()
                    self.postTrashRemovalTask = nil
                    return
                }

                let request = self.postTrashRemovalRequests.removeFirst()
                let didRemove = await self.scanCoordinator.removeNodeFromCurrentSnapshot(id: request.nodeID)
                guard !Task.isCancelled else {
                    self.postTrashRemovalRequests.removeAll()
                    self.postTrashRemovalTask = nil
                    return
                }

                if didRemove,
                   let fallbackFocusID = request.fallbackFocusID,
                   self.scanCoordinator.fileTreeStore?.node(id: fallbackFocusID) != nil {
                    self.navigationModel.setFocusedNodeID(fallbackFocusID)
                }
                self.navigationModel.reconcileAfterSnapshotApplied(self.scanCoordinator.snapshot)
            }

            self?.postTrashRemovalTask = nil
        }
    }

    private func schedulePostTrashRescan(for target: ScanTarget) {
        postTrashRescanTask?.cancel()

        let rescanID = UUID()
        postTrashRescanID = rescanID
        postTrashRescanTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.postTrashRescanDelay)
            } catch {
                return
            }

            guard let self,
                  self.postTrashRescanID == rescanID,
                  !Task.isCancelled else {
                return
            }

            self.postTrashRescanID = nil
            self.postTrashRescanTask = nil
            guard self.scanCoordinator.selectedTarget?.id == target.id else { return }
            self.startScan(target)
        }
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

    private func validatedSelectedNodes() throws -> [FileNodeRecord] {
        try validatedNodes(navigationModel.selectedNodes)
    }

    private func validatedNodes(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        guard !nodes.isEmpty else {
            throw FileActionError.noSelection
        }

        for node in nodes {
            guard node.supportsFileActions else {
                throw FileActionError.unsupported
            }
            guard dependencies.systemActions.fileExists(node.url) else {
                clearSelection()
                throw FileActionError.unavailable(path: node.url.path)
            }
        }

        return nodes
    }

    private func topLevelTrashNodes(from nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return nodes }
        let selectedIDs = Set(nodes.map(\.id))

        return nodes.filter { node in
            !selectedIDs.contains { selectedID in
                selectedID != node.id && fileTreeStore.isAncestor(selectedID, of: node.id)
            }
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        dependencies.systemActions.isExistingDirectory(url)
    }

    private func prepareForScan(_ target: ScanTarget) {
        lastErrorMessage = nil
        navigationModel.reset()
        pendingTrashNode = nil
        pendingTrashSelection = nil
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
            includeCloudStorage: scanCloudStorageFolders,
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
        sidebarScanCacheController.currentScanExclusionRootPath(currentSnapshot: scanCoordinator.snapshot)
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
        scanCoordinator.replaceTrashSafetyPolicy(dependencies.systemActions.trashSafetyPolicy())
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
            self?.quickLookController.syncVisiblePreview()
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
                self?.sidebarScanCacheController.handleCompletedScanSnapshot(snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$scanErrorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.presentErrorMessage(message)
            }
            .store(in: &cancellables)
    }

    private func applyCachedOrContainedSidebarTarget(_ target: ScanTarget) -> Bool {
        let options = scanOptions(for: target)
        return sidebarScanCacheController.applyCachedOrContainedSidebarTarget(
            target,
            options: options,
            currentSnapshot: scanCoordinator.snapshot,
            isTargetActive: { [weak self] target in
                self?.sidebarModel.activeTargetID == target.id
            },
            cancelDeferredScanStart: { [weak self] in
                self?.cancelDeferredScanStart()
            },
            restoreSnapshot: { [weak self] snapshot, target in
                self?.restoreSidebarSnapshot(snapshot, target: target)
            },
            startScan: { [weak self] target in
                self?.startScan(target)
            }
        )
    }

    private func restoreSidebarSnapshot(_ snapshot: ScanSnapshot, target: ScanTarget) {
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForScan(target)
        }
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
        Publishers.CombineLatest4(
            $showHiddenFiles,
            $treatPackagesAsDirectories,
            $maxRenderedDepth,
            $scanCloudStorageFolders
        )
            .combineLatest(Publishers.CombineLatest3($autoSummarizeDirectories, $useScanExclusions, $exclusionPatterns))
            .map { scanBasics, scanFilters in
                Self.scanPreferences(scanBasics, scanFilters)
            }
            .dropFirst()
            .removeDuplicates()
            .debounce(for: Self.scanPreferencePersistenceDebounce, scheduler: RunLoop.main)
            .sink { [weak self] preferences in
                self?.persistScanPreferences(preferences)
            }
            .store(in: &cancellables)
    }

    private var currentScanPreferences: AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: showHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            maxRenderedDepth: maxRenderedDepth,
            autoSummarizeDirectories: autoSummarizeDirectories,
            scanCloudStorageFolders: scanCloudStorageFolders,
            useScanExclusions: useScanExclusions,
            exclusionPatterns: exclusionPatterns
        )
    }

    private func flushPendingScanPreferences() {
        persistScanPreferences(currentScanPreferences)
    }

    private func persistScanPreferences(_ preferences: AppScanPreferences) {
        guard lastPersistedScanPreferences != preferences else { return }
        dependencies.preferences.saveScanPreferences(preferences)
        lastPersistedScanPreferences = preferences
    }

    private static func scanPreferences(
        _ scanBasics: (Bool, Bool, Int, Bool),
        _ scanFilters: (Bool, Bool, [String])
    ) -> AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: scanBasics.0,
            treatPackagesAsDirectories: scanBasics.1,
            maxRenderedDepth: scanBasics.2,
            autoSummarizeDirectories: scanFilters.0,
            scanCloudStorageFolders: scanBasics.3,
            useScanExclusions: scanFilters.1,
            exclusionPatterns: scanFilters.2
        )
    }
}

extension AppModel: AppQuickLookControllerDelegate {
    var quickLookSelectionContext: AppQuickLookSelectionContext {
        AppQuickLookSelectionContext(
            selectedNode: navigationModel.selectedNode,
            activeTarget: scanCoordinator.selectedTarget,
            trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
        )
    }

    var isQuickLookKeyboardShortcutBlocked: Bool {
        showsOnboarding ||
            pendingTrashNode != nil ||
            pendingTrashSelection != nil ||
            navigationModel.selectedNodeIDs.count > 1
    }

    func validatedSelectionForQuickLook() throws -> FileNodeRecord {
        try validatedSelection()
    }

    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error) {
        presentError(error)
    }
}
