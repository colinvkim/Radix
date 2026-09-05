//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Combine
import Foundation

private nonisolated struct DiskFreeSpaceCapacityKey: Equatable, Sendable {
    let snapshotID: UUID
    let volumePath: String
}

private nonisolated struct DiskFreeSpaceCapacityCache: Equatable, Sendable {
    let key: DiskFreeSpaceCapacityKey
    let availableCapacity: Int64?
}

struct ExportConfirmationState: Identifiable, Equatable, Sendable {
    let id: UUID
    let archiveURL: URL
}

struct DiscardPileState: Equatable, Sendable {
    let nodeIDs: [FileNodeRecord.ID]
    let snapshotID: UUID?

    init(
        nodeIDs: [FileNodeRecord.ID] = [],
        snapshotID: UUID? = nil
    ) {
        self.nodeIDs = nodeIDs
        self.snapshotID = nodeIDs.isEmpty ? nil : snapshotID
    }

    var isEmpty: Bool {
        nodeIDs.isEmpty
    }
}

struct DiscardPileSummary: Equatable, Sendable {
    let itemCount: Int
    let totalAllocatedSize: Int64

    init(itemCount: Int, totalAllocatedSize: Int64) {
        self.itemCount = itemCount
        self.totalAllocatedSize = totalAllocatedSize
    }

    var isEmpty: Bool {
        itemCount == 0
    }

    init(nodes: [FileNodeRecord]) {
        self.init(
            itemCount: nodes.count,
            totalAllocatedSize: nodes.reduce(into: Int64(0)) { total, node in
                total += node.allocatedSize
            }
        )
    }
}

struct DiscardPileSnapshot: Equatable, Sendable {
    let nodes: [FileNodeRecord]
    let summary: DiscardPileSummary
}

enum FileActionError: LocalizedError {
    case noSelection
    case unavailable(path: String)
    case changedSinceScan(path: String)
    case missingScannedIdentity(path: String)
    case currentIdentityUnavailable(path: String, reason: String)
    case unsupported
    case directoryRequired
    case packageContentsHidden(settingEnabled: Bool)
    case folderRequiredForDrop
    case fullDiskAccessSettingsUnavailable
    case readOnlySnapshot
    case currentComparisonSnapshotUnavailable

    var alertTitle: String? {
        switch self {
        case .packageContentsHidden:
            return String(localized: "Package Contents Hidden", comment: "Alert title explaining that a package's contents were not expanded.")
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return String(localized: "Select an item first.", comment: "Error shown when a file action is requested without a selection.")
        case .unavailable(let path):
            return String(localized: "The item at \(path) is no longer available.", comment: "Error shown when a selected item has disappeared.")
        case .changedSinceScan(let path):
            return String(localized: "The item at \(path) changed since this scan. Rescan before moving it to Trash.", comment: "Safety error shown when a selected item changed after scanning.")
        case .missingScannedIdentity(let path):
            return String(localized: "Radix could not verify the scanned identity for \(path). Rescan before moving it to Trash.", comment: "Safety error shown when a scanned file identity cannot be verified.")
        case .currentIdentityUnavailable(let path, let reason):
            return String(localized: "Radix could not verify the current identity for \(path): \(reason)", comment: "Safety error shown when the current file identity cannot be verified.")
        case .unsupported:
            return String(localized: "This item does not support that action.", comment: "Error shown when a selected item cannot perform the requested action.")
        case .directoryRequired:
            return String(localized: "Choose a folder with contents to zoom in.", comment: "Error shown when zooming requires a directory.")
        case .packageContentsHidden(let settingEnabled):
            if settingEnabled {
                return String(localized: "Radix scanned this package before package contents were expanded. Rescan this location to zoom into it.", comment: "Error shown when a package needs to be rescanned after enabling package expansion.")
            }
            return String(localized: "Radix scanned this package as a single item. To zoom into it, turn on “Treat app bundles and packages as folders” in Settings, then rescan this location.", comment: "Error explaining how to enable package expansion before zooming into a package.")
        case .folderRequiredForDrop:
            return String(localized: "Drop a folder or mounted volume to start a scan.", comment: "Error shown when a dropped item is not a folder or volume.")
        case .fullDiskAccessSettingsUnavailable:
            return String(localized: "Radix could not open Full Disk Access settings.", comment: "Error shown when System Settings cannot open Full Disk Access.")
        case .readOnlySnapshot:
            return String(localized: "Imported snapshots are read-only.", comment: "Error shown when a file action is attempted on an imported snapshot.")
        case .currentComparisonSnapshotUnavailable:
            return String(localized: "Current scan changed. Start the comparison again.", comment: "Error shown when the live scan changed during comparison setup.")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias PendingTrashSelection = TrashFlowController.PendingTrashSelection
    typealias PendingCloudFileAction = TrashFlowController.PendingCloudFileAction
    typealias PostTrashRemovalRequest = TrashFlowController.PostTrashRemovalRequest

    private enum NavigationAction: Sendable {
        case select(FileNodeRecord.ID?)
        case selectMultiple(Set<FileNodeRecord.ID>, primary: FileNodeRecord.ID?)
        case focus(FileNodeRecord.ID?)
        case selectAndFocus(FileNodeRecord.ID)
        case reveal(FileNodeRecord.ID)
        case navigateBack
        case navigateForward
        case navigateToParent
        case resetFocusToRoot
        case clearSelection
    }

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published var showFreeSpaceInDiskMaps = false {
        didSet {
            guard showFreeSpaceInDiskMaps != oldValue else { return }
            refreshDiskFreeSpaceCapacity(for: scanCoordinator.snapshot)
        }
    }
    @Published var scanVisualizationMode = ScanVisualizationMode.sunburst
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
    @Published var showsOnboarding: Bool {
        didSet {
            synchronizeOnboardingPresentation()
        }
    }
    @Published private(set) var showsDiscardPileReview = false {
        didSet {
            synchronizeDiscardPileReviewPresentation()
        }
    }
    @Published private(set) var fullDiskAccessStatus: FullDiskAccessStatus
    @Published private(set) var isExportPanelPresented = false
    @Published var lastErrorMessage: String? {
        didSet {
            if lastErrorMessage == nil {
                lastActionErrorTitle = nil
            }
            synchronizeErrorPresentation()
        }
    }
    @Published private(set) var exportConfirmation: ExportConfirmationState?
    let trashFlow = TrashFlowController()
    let comparisonFlow = ComparisonFlowController()

    private(set) var scanComparison: ScanComparison? {
        get { comparisonFlow.scanComparison }
        set { comparisonFlow.setScanComparison(newValue) }
    }

    var pendingComparisonSetup: ScanComparisonSetup? {
        get { comparisonFlow.pendingComparisonSetup }
        set { comparisonFlow.pendingComparisonSetup = newValue }
    }
    @Published var pendingImportPreview: ScanArchivePreview? {
        didSet {
            synchronizeImportPreviewPresentation()
        }
    }

    var pendingTrashSelection: PendingTrashSelection? {
        get { trashFlow.pendingTrashSelection }
        set { trashFlow.pendingTrashSelection = newValue }
    }

    private(set) var pendingCloudFileAction: PendingCloudFileAction? {
        get { trashFlow.pendingCloudFileAction }
        set { trashFlow.pendingCloudFileAction = newValue }
    }

    private(set) var discardPile: DiscardPileState {
        get { trashFlow.discardPile }
        set { trashFlow.discardPile = newValue }
    }

    private var optimisticTrashVisibility: TrashFlowController.OptimisticTrashVisibilityState {
        trashFlow.optimisticTrashVisibility
    }

    private var confirmedTrashMoveTask: Task<Void, Never>? {
        get { trashFlow.confirmedTrashMoveTask }
        set { trashFlow.confirmedTrashMoveTask = newValue }
    }

    private var postTrashRemovalTask: Task<Void, Never>? {
        get { trashFlow.postTrashRemovalTask }
        set { trashFlow.postTrashRemovalTask = newValue }
    }

    private var postTrashRemovalRequests: [TrashFlowController.PostTrashRemovalRequest] {
        get { trashFlow.postTrashRemovalRequests }
        set { trashFlow.postTrashRemovalRequests = newValue }
    }

    @Published private(set) var usageStats = AppUsageStats.empty
    @Published private var diskFreeSpaceCapacityCache: DiskFreeSpaceCapacityCache?

    private let dependencies: AppDependencies
    let presentationCoordinator: AppPresentationCoordinator
    private let scanCoordinator: ScanCoordinator
    private let sidebarModel: SidebarModel
    private let quickLookController: AppQuickLookController
    private let archiveWorkflow: ArchiveWorkflowCoordinator
    private let navigationModel = WorkspaceNavigationModel()
    private var lastActionErrorTitle: String?
    private let sidebarScanCacheController: SidebarScanCacheController
    private var lastPersistedScanPreferences: AppScanPreferences?

    private static let viewUpdateDeferralDelay: Duration = .milliseconds(1)
    private static let scanPreferencePersistenceDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(50)
    private var cancellables = Set<AnyCancellable>()
    private enum DeferredWorkKind {
        case scanStart
        case sidebarSelection
        case navigationAction
        case visualizationMode
        case discardPileAdd
        case navigationContext
    }

    private struct DeferredWorkBox {
        var id: UUID?
        var task: Task<Void, Never>?

        mutating func cancel() {
            task?.cancel()
            self = DeferredWorkBox()
        }
    }

    private var deferredWorkBoxes: [DeferredWorkKind: DeferredWorkBox] = [:]
    private var deferredNavigationContextSnapshotID: UUID?
    private var exportPanelTask: Task<Void, Never>?
    private var exportPanelRequestID: UUID?
    private var comparisonPanelTask: Task<Void, Never>?
    private var comparisonPanelRequestID: UUID?
    private var readyDeferredArchiveImportURL: URL?
    private var exportConfirmationDismissTask: Task<Void, Never>?
    private var fullDiskAccessRefreshTask: Task<Void, Never>?
    private var targetCapacityDescriptionsRefreshTask: Task<Void, Never>?
    private var diskFreeSpaceCapacityRefreshTask: Task<Void, Never>?
    private var diskFreeSpaceCapacityRefreshGeneration = 0

    init(
        dependencies: AppDependencies = .live,
        completedScanCacheMaxTotalNodeCount: Int = 250_000
    ) {
        self.dependencies = dependencies
        self.scanCoordinator = ScanCoordinator(scanService: dependencies.scanService)
        self.sidebarModel = SidebarModel(
            recentTargetStore: dependencies.recentTargets,
            preferredSmartTargetIDs: dependencies.systemActions.preferredSmartTargetIDs
        )
        self.quickLookController = AppQuickLookController(systemActions: dependencies.systemActions)
        self.archiveWorkflow = ArchiveWorkflowCoordinator()
        self.sidebarScanCacheController = SidebarScanCacheController(
            maxTotalNodeCount: completedScanCacheMaxTotalNodeCount
        )

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        showFreeSpaceInDiskMaps = preferences.scan.showFreeSpaceInDiskMaps
        scanVisualizationMode = preferences.scan.visualizationMode
        useScanExclusions = preferences.scan.useScanExclusions
        exclusionPatterns = preferences.scan.exclusionPatterns
        lastPersistedScanPreferences = preferences.scan
        let shouldShowOnboarding = !preferences.didCompleteOnboarding
        presentationCoordinator = AppPresentationCoordinator(
            initialDestination: shouldShowOnboarding ? .sheet(.onboarding) : nil
        )
        showsOnboarding = shouldShowOnboarding
        usageStats = dependencies.usageStats.loadUsageStats()
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
        presentationCoordinator.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        archiveWorkflow.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        archiveWorkflow.onBecameIdle = { [weak self] in
            self?.resumeReadyDeferredArchiveImportIfPossible()
        }
        trashFlow.onChange = { [weak self] in
            guard let self else { return }
            self.synchronizeTrashConfirmationPresentation()
            self.synchronizeCloudFileConfirmationPresentation()
            self.objectWillChange.send()
        }
        comparisonFlow.onChange = { [weak self] in
            guard let self else { return }
            self.synchronizeComparisonSetupPresentation()
            self.objectWillChange.send()
        }
        observeNavigationModel()
        observeScanCoordinator()
        observeMountedVolumes()
        observePreferences()
        quickLookController.installKeyMonitor()
    }

    isolated deinit {
        cleanup()
    }

    func cleanup() {
        flushPendingScanPreferences()
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredVisualizationModeUpdate()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        cancelConfirmedTrashMove()
        sidebarScanCacheController.resetTransientState()
        fullDiskAccessRefreshTask?.cancel()
        fullDiskAccessRefreshTask = nil
        targetCapacityDescriptionsRefreshTask?.cancel()
        targetCapacityDescriptionsRefreshTask = nil
        cancelDiskFreeSpaceCapacityRefresh(clearCache: true)
        exportPanelTask?.cancel()
        exportPanelTask = nil
        exportPanelRequestID = nil
        comparisonPanelTask?.cancel()
        comparisonPanelTask = nil
        comparisonPanelRequestID = nil
        isExportPanelPresented = false
        readyDeferredArchiveImportURL = nil
        cancelArchiveOperation()
        dismissExportConfirmation()
        presentationCoordinator.reset()
        showsDiscardPileReview = false
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        quickLookController.setWorkspaceWindowNumber(nil)
        scanCoordinator.stopScan()
        quickLookController.removeKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredVisualizationModeUpdate()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        cancelConfirmedTrashMove()
        sidebarScanCacheController.clearActiveScanTracking()
        if scanCoordinator.canStopScan {
            scanCoordinator.stopScan()
        } else {
            scanCoordinator.stopScan(resetState: false)
        }
        quickLookController.closePreview()
    }

    func suspendBackgroundActivity() {
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

    var discardPileSnapshot: DiscardPileSnapshot {
        let nodes = resolvedDiscardPileNodes()
        return DiscardPileSnapshot(
            nodes: nodes,
            summary: DiscardPileSummary(nodes: nodes)
        )
    }

    var workspaceHiddenNodeIDs: Set<FileNodeRecord.ID> {
        hiddenNodeIDs(for: scanCoordinator.snapshot?.id)
    }

    var discardPileRootNodeIDs: Set<FileNodeRecord.ID> {
        guard discardPile.snapshotID == scanCoordinator.snapshot?.id else { return [] }
        return Set(discardPile.nodeIDs)
    }

    var movingToTrashRootNodeIDs: Set<FileNodeRecord.ID> {
        guard optimisticTrashVisibility.snapshotID == scanCoordinator.snapshot?.id else { return [] }
        return optimisticTrashVisibility.nodeIDs
    }

    var canZoomIntoSelection: Bool {
        guard let selectedNodeID = navigationModel.selectedNodeID else { return false }
        return navigationModel.canZoomIntoSelection && isVisibleNavigationNode(selectedNodeID)
    }

    var selectionIncludesHiddenNodes: Bool {
        let selectedNodeIDs = navigationModel.selectedNodeIDs
        return !selectedNodeIDs.isEmpty
            && visibleNavigationNodeIDs(from: selectedNodeIDs) != selectedNodeIDs
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
            return String(localized: "Scan Failed", comment: "Alert title shown when a scan fails.")
        }
        return lastActionErrorTitle ?? String(localized: "Action Failed", comment: "Fallback alert title shown when a file action fails.")
    }

    var canRescanFromErrorAlert: Bool {
        scanCoordinator.phase == .failed && scanCoordinator.canRescan
    }

    var isArchiveOperationInProgress: Bool {
        archiveWorkflow.isRunning
    }

    var archiveOperation: ArchiveOperationState? {
        archiveWorkflow.operation
    }

    func dismissOnboarding() {
        showsOnboarding = false
        dependencies.preferences.markOnboardingComplete()
    }

    func presentOnboarding() {
        showsOnboarding = true
    }

    func presentDiscardPileReview() {
        showsDiscardPileReview = true
    }

    func dismissDiscardPileReview() {
        showsDiscardPileReview = false
    }

    func dismissActiveSheet() {
        switch presentationCoordinator.activeSheet {
        case .onboarding:
            dismissOnboarding()
        case .discardPileReview:
            dismissDiscardPileReview()
        case .importPreview:
            cancelImportPreview()
        case .comparisonSetup:
            cancelComparisonSetup()
        case nil:
            break
        }
    }

    func dismissErrorPresentation() {
        lastErrorMessage = nil
    }

    private func synchronizeOnboardingPresentation() {
        if showsOnboarding {
            presentationCoordinator.present(.sheet(.onboarding))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .onboarding)
            )
        }
    }

    private func synchronizeDiscardPileReviewPresentation() {
        if showsDiscardPileReview {
            presentationCoordinator.present(.sheet(.discardPileReview))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .discardPileReview)
            )
        }
    }

    private func synchronizeImportPreviewPresentation() {
        if let pendingImportPreview {
            presentationCoordinator.present(.sheet(.importPreview(pendingImportPreview.id)))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .importPreview)
            )
        }
    }

    private func synchronizeComparisonSetupPresentation() {
        if let pendingComparisonSetup {
            presentationCoordinator.present(.sheet(.comparisonSetup(pendingComparisonSetup.id)))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .comparisonSetup)
            )
        }
    }

    private func synchronizeErrorPresentation() {
        if lastErrorMessage != nil {
            presentationCoordinator.present(.dialog(.error))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .error)
            )
        }
    }

    private func synchronizeTrashConfirmationPresentation() {
        if pendingTrashSelection != nil {
            presentationCoordinator.present(.dialog(.trashConfirmation))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .trashConfirmation)
            )
        }
    }

    private func synchronizeCloudFileConfirmationPresentation() {
        if pendingCloudFileAction != nil {
            presentationCoordinator.present(.dialog(.cloudFileConfirmation))
        } else {
            resumeDeferredArchiveImport(
                presentationCoordinator.cancel(kind: .cloudFileConfirmation)
            )
        }
    }

    private func resumeDeferredArchiveImport(_ sourceURL: URL?) {
        guard let sourceURL else { return }
        guard !isArchiveOperationInProgress else {
            readyDeferredArchiveImportURL = sourceURL
            return
        }
        beginImportScanSnapshot(from: sourceURL)
    }

    private func resumeReadyDeferredArchiveImportIfPossible() {
        guard !isArchiveOperationInProgress,
              let sourceURL = readyDeferredArchiveImportURL else {
            return
        }
        readyDeferredArchiveImportURL = nil
        beginImportScanSnapshot(from: sourceURL)
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
        showFreeSpaceInDiskMaps = AppScanPreferences.defaults.showFreeSpaceInDiskMaps
        scanVisualizationMode = AppScanPreferences.defaults.visualizationMode
        useScanExclusions = AppScanPreferences.defaults.useScanExclusions
        exclusionPatterns = AppScanPreferences.defaults.exclusionPatterns
    }

    func clearRecentTargets() {
        recentTargets.removeAll()
        dependencies.recentTargets.clear()
    }

    func clearUsageStats() {
        usageStats = .empty
        dependencies.usageStats.clearUsageStats()
    }

    func recordSunburstSegmentClick() {
        updateUsageStats { stats in
            stats.recordSunburstSegmentClick()
        }
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
        guard !scanCoordinator.isScanOperationInProgress else { return }
        if let target = dependencies.systemActions.presentOpenPanel() {
            startScan(target)
        }
    }

    var canExportCurrentScan: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanOperationInProgress &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress
    }

    private var canPresentScanSnapshotPanel: Bool {
        !scanCoordinator.isScanOperationInProgress &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress &&
            pendingComparisonSetup == nil &&
            pendingImportPreview == nil
    }

    var canImportScanSnapshot: Bool {
        canPresentScanSnapshotPanel
    }

    var canCompareScanSnapshots: Bool {
        canPresentScanSnapshotPanel
    }

    var canUseWorkspaceCommands: Bool {
        scanComparison == nil
    }

    var canCompareCurrentScanWithSnapshot: Bool {
        canCompareScanSnapshots &&
            scanCoordinator.snapshot?.isComplete == true &&
            scanCoordinator.snapshotSource.allowsFileMutation
    }

    var canUseCurrentScanInComparisonSetup: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            scanCoordinator.snapshotSource.allowsFileMutation
    }

    private var canConfirmImportPreview: Bool {
        !scanCoordinator.isScanOperationInProgress &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress
    }

    func exportCurrentScan() {
        guard canExportCurrentScan,
              let snapshot = scanCoordinator.snapshot else {
            return
        }

        let defaultFileName = defaultExportFileName(for: snapshot)
        let snapshotID = snapshot.id

        exportPanelTask?.cancel()
        let requestID = UUID()
        exportPanelRequestID = requestID
        isExportPanelPresented = true
        exportPanelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.exportPanelRequestID == requestID {
                    self.isExportPanelPresented = false
                    self.exportPanelTask = nil
                    self.exportPanelRequestID = nil
                }
            }

            guard let destinationURL = await self.dependencies.systemActions.presentExportScanPanel(defaultFileName),
                  !Task.isCancelled,
                  self.exportPanelRequestID == requestID,
                  self.scanCoordinator.snapshot?.id == snapshotID,
                  self.canExportCurrentScanIgnoringPresentedPanel else {
                return
            }

            self.startArchiveExport(snapshot: snapshot, destinationURL: destinationURL)
        }
    }

    private var canExportCurrentScanIgnoringPresentedPanel: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanOperationInProgress &&
            !isArchiveOperationInProgress
    }

    private func startArchiveExport(snapshot: ScanSnapshot, destinationURL: URL) {
        dismissExportConfirmation()
        let progressReporter = ScanArchiveProgressReporter()
        let archiveService = dependencies.scanArchiveService
        let exportOptions = ScanArchiveExportOptions(
            appVersion: Self.currentAppVersion(),
            progressReporter: progressReporter
        )
        archiveWorkflow.start(
            kind: .export,
            title: String(localized: "Exporting Snapshot", comment: "Progress banner title while exporting a scan snapshot."),
            message: String(localized: "Preparing archive", comment: "Progress banner message while preparing an exported snapshot."),
            progressReporter: progressReporter,
            work: {
                try await archiveService.export(
                    snapshot: snapshot,
                    to: destinationURL,
                    options: exportOptions
                )
            },
            onSuccess: { [weak self] result in
                guard let self else { return }
                lastErrorMessage = nil
                presentExportConfirmation(for: result.archiveURL)
            },
            onFailure: { [weak self] error in
                self?.presentError(error, title: String(localized: "Export Failed", comment: "Alert title shown when exporting a snapshot fails."))
            },
            onCleanup: {
                progressReporter.finish()
            }
        )
    }

    func revealExportedSnapshotInFinder() {
        guard let exportConfirmation else { return }
        dependencies.systemActions.reveal(exportConfirmation.archiveURL)
        dismissExportConfirmation()
    }

    func dismissExportConfirmation() {
        exportConfirmationDismissTask?.cancel()
        exportConfirmationDismissTask = nil
        exportConfirmation = nil
    }

    private func presentExportConfirmation(for archiveURL: URL) {
        dismissExportConfirmation()
        let confirmation = ExportConfirmationState(id: UUID(), archiveURL: archiveURL)
        exportConfirmation = confirmation
        exportConfirmationDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard self?.exportConfirmation?.id == confirmation.id else { return }
            self?.exportConfirmation = nil
            self?.exportConfirmationDismissTask = nil
        }
    }

    func importScanSnapshot() {
        guard canImportScanSnapshot else { return }
        guard let sourceURL = dependencies.systemActions.presentImportScanPanel() else {
            return
        }

        importScanSnapshot(from: sourceURL)
    }

    func importScanSnapshot(from sourceURL: URL) {
        beginImportScanSnapshot(from: sourceURL)
    }

    /// Handles a document-open event. Unlike an explicit in-app import command,
    /// macOS can deliver this while another modal flow (notably onboarding) is
    /// active, so document opens are serialized instead of rejected or overlaid.
    func openScanSnapshotArchive(_ sourceURL: URL) {
        guard presentationCoordinator.requestArchiveImport(sourceURL) == .startNow else {
            return
        }
        beginImportScanSnapshot(from: sourceURL)
    }

    private func beginImportScanSnapshot(from sourceURL: URL) {
        guard canImportScanSnapshot else {
            presentErrorMessage(importUnavailableMessage)
            return
        }

        previewImportScanSnapshot(from: sourceURL)
    }

    private var importUnavailableMessage: String {
        if scanCoordinator.isScanOperationInProgress {
            return String(localized: "Stop the current scan before importing a snapshot.", comment: "Error shown when importing is attempted during a scan.")
        }
        if isExportPanelPresented {
            return String(localized: "Finish choosing an export location before importing a snapshot.", comment: "Error shown when importing is attempted while the export panel is open.")
        }
        if isArchiveOperationInProgress {
            return String(localized: "Cancel the current archive operation before importing a snapshot.", comment: "Error shown when importing is attempted during another archive operation.")
        }
        if pendingComparisonSetup != nil {
            return String(localized: "Finish or cancel the current comparison setup before importing a snapshot.", comment: "Error shown when importing is attempted during comparison setup.")
        }
        if pendingImportPreview != nil {
            return String(localized: "Finish or cancel the current import preview before importing another snapshot.", comment: "Error shown when a second import is attempted during import preview.")
        }
        return String(localized: "Radix cannot import a snapshot right now.", comment: "Fallback error shown when importing is unavailable.")
    }

    private var comparisonUnavailableMessage: String {
        if scanCoordinator.isScanOperationInProgress {
            return String(localized: "Stop the current scan before comparing snapshots.", comment: "Error shown when comparison is attempted during a scan.")
        }
        if isExportPanelPresented {
            return String(localized: "Finish choosing an export location before comparing snapshots.", comment: "Error shown when comparison is attempted while the export panel is open.")
        }
        if isArchiveOperationInProgress {
            return String(localized: "Cancel the current archive operation before comparing snapshots.", comment: "Error shown when comparison is attempted during another archive operation.")
        }
        if pendingComparisonSetup != nil {
            return String(localized: "Finish or cancel the current comparison setup before comparing snapshots.", comment: "Error shown when comparison is attempted during comparison setup.")
        }
        if pendingImportPreview != nil {
            return String(localized: "Finish or cancel the current import preview before comparing snapshots.", comment: "Error shown when comparison is attempted during import preview.")
        }
        return String(localized: "Radix cannot compare snapshots right now.", comment: "Fallback error shown when comparison is unavailable.")
    }

    func compareScanSnapshots() {
        guard canCompareScanSnapshots else {
            presentErrorMessage(comparisonUnavailableMessage)
            return
        }
        beginComparisonSetup()
    }

    func compareScanSnapshots(from sourceURLs: [URL]) {
        guard canCompareScanSnapshots else {
            presentErrorMessage(comparisonUnavailableMessage)
            return
        }
        guard sourceURLs.count == 2 else {
            presentErrorMessage(String(localized: "Choose exactly two Radix scan snapshots to compare.", comment: "Error shown when comparison is given the wrong number of snapshots."))
            return
        }

        previewArchiveSnapshotComparison(sourceURLs: sourceURLs)
    }

    func compareCurrentScanWithSnapshot() {
        guard canCompareCurrentScanWithSnapshot,
              let currentSnapshot = scanCoordinator.snapshot else {
            presentErrorMessage(currentScanComparisonUnavailableMessage)
            return
        }
        beginComparisonSetup(after: ScanComparisonCandidate(snapshot: currentSnapshot))
    }

    private var currentScanComparisonUnavailableMessage: String {
        if !canCompareScanSnapshots {
            return comparisonUnavailableMessage
        }
        return String(localized: "Complete a live scan before comparing it with a snapshot.", comment: "Error shown when comparing a live scan before it is complete.")
    }

    func closeScanComparison() {
        scanComparison = nil
    }

    func canRevealComparisonRowInFinder(_ row: ScanComparisonRow) -> Bool {
        canRevealComparisonNodeInFinder(
            beforeNode: row.beforeNode,
            afterNode: row.afterNode
        )
    }

    func revealComparisonRowInFinder(_ row: ScanComparisonRow) {
        revealComparisonNodeInFinder(
            beforeNode: row.beforeNode,
            afterNode: row.afterNode
        )
    }

    func copyComparisonRowPath(_ row: ScanComparisonRow) {
        copyComparisonPath(row.fileURL)
    }

    func canShowComparisonRowInBrowser(_ row: ScanComparisonRow) -> Bool {
        canShowComparisonNodeInBrowser(beforeNode: row.beforeNode, afterNode: row.afterNode)
    }

    func showComparisonRowInBrowser(_ row: ScanComparisonRow) {
        showComparisonNodeInBrowser(beforeNode: row.beforeNode, afterNode: row.afterNode)
    }

    func canRevealComparisonChangeNodeInFinder(_ node: ScanComparisonChangeTreeNode) -> Bool {
        canRevealComparisonNodeInFinder(
            beforeNode: node.beforeNode,
            afterNode: node.afterNode
        )
    }

    func revealComparisonChangeNodeInFinder(_ node: ScanComparisonChangeTreeNode) {
        revealComparisonNodeInFinder(
            beforeNode: node.beforeNode,
            afterNode: node.afterNode
        )
    }

    func copyComparisonChangeNodePath(_ node: ScanComparisonChangeTreeNode) {
        copyComparisonPath(node.fileURL)
    }

    func canShowComparisonChangeNodeInBrowser(_ node: ScanComparisonChangeTreeNode) -> Bool {
        canShowComparisonNodeInBrowser(beforeNode: node.beforeNode, afterNode: node.afterNode)
    }

    func showComparisonChangeNodeInBrowser(_ node: ScanComparisonChangeTreeNode) {
        showComparisonNodeInBrowser(beforeNode: node.beforeNode, afterNode: node.afterNode)
    }

    private func canRevealComparisonNodeInFinder(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> Bool {
        guard let node = currentScanNode(beforeNode: beforeNode, afterNode: afterNode) else {
            return false
        }
        return dependencies.systemActions.fileExists(node.url)
    }

    private func revealComparisonNodeInFinder(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) {
        guard let node = currentScanNode(beforeNode: beforeNode, afterNode: afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        guard dependencies.systemActions.fileExists(node.url) else {
            presentError(FileActionError.unavailable(path: node.url.path))
            return
        }
        dependencies.systemActions.reveal(node.url)
    }

    private func copyComparisonPath(_ url: URL?) {
        guard let url else {
            presentError(FileActionError.unsupported)
            return
        }
        do {
            try dependencies.systemActions.copyPath(url)
        } catch {
            presentError(error)
        }
    }

    private func canShowComparisonNodeInBrowser(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> Bool {
        guard let nodeID = currentScanNodeID(beforeNode: beforeNode, afterNode: afterNode) else {
            return false
        }
        return isVisibleNavigationNode(nodeID)
    }

    private func showComparisonNodeInBrowser(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) {
        guard let nodeID = currentScanNodeID(beforeNode: beforeNode, afterNode: afterNode) else {
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
            return
        }
        // Don't tear down the comparison unless the reveal will actually land — a node that
        // is hidden (e.g. in the discard pile) would be filtered by performNavigationAction,
        // leaving the user on an empty browser with their comparison gone.
        guard isVisibleNavigationNode(nodeID) else { return }
        closeScanComparison()
        revealAfterViewUpdate(nodeID: nodeID)
    }

    /// The node ID for a comparison row within the current live scan, or nil when the row's
    /// side is not the current scan (e.g. comparing two imported archives) or the node is gone.
    private func currentScanNode(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> FileNodeRecord? {
        guard let comparison = scanComparison,
              let currentSnapshotID = scanCoordinator.snapshot?.id else {
            return nil
        }
        if comparison.after.id == currentSnapshotID, let afterNode {
            return afterNode
        }
        if comparison.before.id == currentSnapshotID, let beforeNode {
            return beforeNode
        }
        return nil
    }

    private func currentScanNodeID(
        beforeNode: FileNodeRecord?,
        afterNode: FileNodeRecord?
    ) -> String? {
        currentScanNode(beforeNode: beforeNode, afterNode: afterNode)?.id
    }

    func swapPendingComparisonSetup() {
        comparisonFlow.swapPendingSetup()
    }

    func cancelComparisonSetup() {
        guard comparisonFlow.hasPendingSetup else { return }
        cancelArchiveOperation()
        comparisonFlow.clearPendingSetup()
    }

    func confirmComparisonSetup() {
        switch comparisonFlow.confirmPendingSetup(
            currentLiveSnapshotID: scanCoordinator.snapshot?.id
        ) {
        case .confirmed(let setup):
            startComparison(setup)
        case .staleCurrentSnapshot:
            presentError(FileActionError.currentComparisonSnapshotUnavailable)
        case .validationFailed, .noPendingSetup:
            break
        }
    }

    func chooseComparisonSnapshot(for slot: ScanComparisonSlot) {
        guard pendingComparisonSetup != nil else { return }
        guard pendingComparisonSetup?.loadingSlot == nil else { return }
        let setupID = pendingComparisonSetup?.id

        comparisonPanelTask?.cancel()
        let requestID = UUID()
        comparisonPanelRequestID = requestID
        comparisonPanelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.comparisonPanelRequestID == requestID {
                    self.comparisonPanelTask = nil
                    self.comparisonPanelRequestID = nil
                }
            }
            guard let sourceURL = await self.dependencies.systemActions.presentComparisonSnapshotPanel(),
                  !Task.isCancelled,
                  self.comparisonPanelRequestID == requestID,
                  self.pendingComparisonSetup?.id == setupID,
                  self.pendingComparisonSetup?.loadingSlot == nil else {
                return
            }
            self.previewComparisonSnapshot(from: sourceURL, for: slot)
        }
    }

    func dropComparisonSnapshot(_ sourceURL: URL, for slot: ScanComparisonSlot) {
        guard let info = comparisonFlow.beginPreview(
            from: sourceURL,
            for: slot,
            savedScanExtension: ScanArchiveService.fileExtension
        ) else {
            return
        }
        runComparisonPreview(from: sourceURL, info: info)
    }

    func useCurrentScanForComparisonSlot(_ slot: ScanComparisonSlot) {
        comparisonFlow.assignCurrentSnapshot(
            scanCoordinator.snapshot,
            for: slot,
            isEligible: canUseCurrentScanInComparisonSetup
        )
    }

    func clearComparisonSlot(_ slot: ScanComparisonSlot) {
        comparisonFlow.clearComparisonSlot(slot)
    }

    private func beginComparisonSetup(
        before: ScanComparisonCandidate? = nil,
        after: ScanComparisonCandidate? = nil
    ) {
        cancelArchiveOperation()
        pendingComparisonSetup = ScanComparisonSetup(before: before, after: after)
    }

    private func previewComparisonSnapshot(from sourceURL: URL, for slot: ScanComparisonSlot) {
        guard let info = comparisonFlow.beginPreview(
            from: sourceURL,
            for: slot,
            savedScanExtension: nil
        ) else {
            return
        }
        runComparisonPreview(from: sourceURL, info: info)
    }

    private func runComparisonPreview(from sourceURL: URL, info: ComparisonFlowController.PreviewBeginInfo) {
        let archiveService = dependencies.scanArchiveService
        archiveWorkflow.start(
            work: {
                try await archiveService.previewSnapshot(from: sourceURL)
            },
            onSuccess: { [weak self] preview in
                guard let self,
                      self.comparisonFlow.applyPreview(preview, info: info) else {
                    return
                }
                self.lastErrorMessage = nil
            },
            onFailure: { [weak self] error in
                _ = self?.comparisonFlow.failPreview(
                    info: info,
                    message: error.localizedDescription
                )
            },
            onFinish: { [weak self] in
                self?.comparisonFlow.clearLoadingSlot(info: info)
            }
        )
    }

    private func previewArchiveSnapshotComparison(sourceURLs: [URL]) {
        dismissExportConfirmation()
        pendingComparisonSetup = nil
        let archiveService = dependencies.scanArchiveService
        archiveWorkflow.start(
            kind: .compare,
            title: String(localized: "Preparing Comparison", comment: "Progress banner title while preparing a comparison."),
            message: String(localized: "Reading snapshots", comment: "Progress banner message while loading snapshots for comparison."),
            work: {
                let first = try await archiveService.previewSnapshot(from: sourceURLs[0])
                try Task.checkCancellation()
                let second = try await archiveService.previewSnapshot(from: sourceURLs[1])
                try Task.checkCancellation()
                let candidates = Self.orderedComparisonCandidates(
                    ScanComparisonCandidate(preview: first),
                    ScanComparisonCandidate(preview: second)
                )
                return ScanComparisonSetup(before: candidates.before, after: candidates.after)
            },
            onSuccess: { [weak self] setup in
                self?.pendingComparisonSetup = setup
                self?.lastErrorMessage = nil
            },
            onFailure: { [weak self] error in
                self?.presentError(error, title: String(localized: "Comparison Failed", comment: "Alert title shown when preparing a comparison fails."))
            }
        )
    }

    private func startComparison(_ setup: ScanComparisonSetup) {
        guard let candidates = setup.resolvedCandidates else { return }
        scanComparison = nil
        dismissExportConfirmation()
        let currentSnapshot = scanCoordinator.snapshot
        let archiveService = dependencies.scanArchiveService
        archiveWorkflow.start(
            kind: .compare,
            title: String(localized: "Comparing Snapshots", comment: "Progress banner title while comparing snapshots."),
            message: String(localized: "Reading archives", comment: "Progress banner message while reading archives for comparison."),
            work: {
                let snapshots = try await Self.comparisonSnapshots(
                    candidates: candidates,
                    archiveService: archiveService,
                    currentSnapshot: currentSnapshot
                )
                try Task.checkCancellation()
                return try await ScanComparisonService().compare(
                    before: snapshots.before,
                    after: snapshots.after
                )
            },
            onSuccess: { [weak self] comparison in
                guard let self else { return }
                if let currentSnapshotID = setup.currentSnapshotID,
                   scanCoordinator.snapshot?.id != currentSnapshotID {
                    return
                }
                quickLookController.closePreview()
                scanComparison = comparison
                lastErrorMessage = nil
            },
            onFailure: { [weak self] error in
                self?.presentError(error, title: String(localized: "Comparison Failed", comment: "Alert title shown when comparing snapshots fails."))
            }
        )
    }

    func confirmImportPreview() {
        guard canConfirmImportPreview,
              let preview = pendingImportPreview else {
            return
        }

        importApprovedScanSnapshot(from: preview.archiveURL)
        pendingImportPreview = nil
    }

    func cancelImportPreview() {
        cancelArchiveOperation()
        pendingImportPreview = nil
    }

    func cancelArchiveOperation() {
        archiveWorkflow.cancel()
    }

    private func previewImportScanSnapshot(from sourceURL: URL) {
        pendingImportPreview = nil
        dismissExportConfirmation()
        let archiveService = dependencies.scanArchiveService
        archiveWorkflow.start(
            kind: .importPreview,
            title: String(localized: "Reading Snapshot", comment: "Progress banner title while reading an imported snapshot."),
            message: String(localized: "Reading manifest", comment: "Progress banner message while reading an imported snapshot manifest."),
            work: {
                try await archiveService.previewSnapshot(from: sourceURL)
            },
            onSuccess: { [weak self] preview in
                self?.pendingImportPreview = preview
                self?.lastErrorMessage = nil
            },
            onFailure: { [weak self] error in
                self?.presentError(error)
            }
        )
    }

    private func importApprovedScanSnapshot(from sourceURL: URL) {
        dismissExportConfirmation()
        let progressReporter = ScanArchiveProgressReporter()
        let archiveService = dependencies.scanArchiveService
        archiveWorkflow.start(
            kind: .import,
            title: String(localized: "Importing Snapshot", comment: "Progress banner title while importing a scan snapshot."),
            message: String(localized: "Reading archive", comment: "Progress banner message while reading an imported archive."),
            progressReporter: progressReporter,
            work: {
                try await archiveService.importSnapshot(
                    from: sourceURL,
                    progressReporter: progressReporter
                )
            },
            onSuccess: { [weak self] result in
                guard let self else { return }
                progressReporter.report(ScanArchiveProgress(
                    phase: .openingSnapshot,
                    message: String(localized: "Opening snapshot", comment: "Progress message while opening an imported snapshot." )
                ))
                archiveWorkflow.updateCurrentOperation(
                    message: String(localized: "Opening snapshot", comment: "Progress message while opening an imported snapshot."),
                    progressFraction: nil
                )
                try await Task.sleep(for: .milliseconds(1))
                restoreImportedSnapshot(result.snapshot)
                lastErrorMessage = nil
            },
            onFailure: { [weak self] error in
                self?.presentError(error)
            },
            onCleanup: {
                progressReporter.finish()
            }
        )
    }

    nonisolated private static func orderedComparisonCandidates(
        _ lhs: ScanComparisonCandidate,
        _ rhs: ScanComparisonCandidate
    ) -> (before: ScanComparisonCandidate, after: ScanComparisonCandidate) {
        let lhsDate = lhs.scanDate
        let rhsDate = rhs.scanDate
        if lhsDate == rhsDate {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
                ? (rhs, lhs)
                : (lhs, rhs)
        }
        return lhsDate < rhsDate ? (lhs, rhs) : (rhs, lhs)
    }

    nonisolated private static func snapshot(
        for source: ScanComparisonCandidateSource,
        archiveService: any ScanArchiveServicing,
        currentSnapshot: ScanSnapshot?
    ) async throws -> ScanSnapshot {
        switch source {
        case .archive(let url):
            return try await archiveService.importSnapshot(from: url).snapshot
        case .currentSnapshot(let id):
            guard let currentSnapshot,
                  currentSnapshot.id == id else {
                throw FileActionError.currentComparisonSnapshotUnavailable
            }
            return currentSnapshot
        }
    }

    nonisolated private static func comparisonSnapshots(
        candidates: (before: ScanComparisonCandidate, after: ScanComparisonCandidate),
        archiveService: any ScanArchiveServicing,
        currentSnapshot: ScanSnapshot?
    ) async throws -> (before: ScanSnapshot, after: ScanSnapshot) {
        if shouldLoadComparisonSnapshotsConcurrently(
            before: candidates.before,
            after: candidates.after
        ) {
            async let before = snapshot(
                for: candidates.before.source,
                archiveService: archiveService,
                currentSnapshot: currentSnapshot
            )
            async let after = snapshot(
                for: candidates.after.source,
                archiveService: archiveService,
                currentSnapshot: currentSnapshot
            )
            return try await (before, after)
        }

        let before = try await snapshot(
            for: candidates.before.source,
            archiveService: archiveService,
            currentSnapshot: currentSnapshot
        )
        try Task.checkCancellation()
        let after = try await snapshot(
            for: candidates.after.source,
            archiveService: archiveService,
            currentSnapshot: currentSnapshot
        )
        return (before, after)
    }

    /// Real Macintosh HD archive imports use about 2.1 KB of peak working set
    /// per node when decoded concurrently. A 2.3 KB estimate plus a quarter-RAM
    /// ceiling leaves room for the app, archive buffers, and comparison output.
    nonisolated static func shouldLoadComparisonSnapshotsConcurrently(
        before: ScanComparisonCandidate,
        after: ScanComparisonCandidate,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Bool {
        guard case .archive = before.source,
              case .archive = after.source else {
            return false
        }

        func nodeCount(_ candidate: ScanComparisonCandidate) -> UInt64 {
            let files = UInt64(max(candidate.fileCount, 0))
            let directories = UInt64(max(candidate.directoryCount, 0))
            let (subtotal, overflow) = files.addingReportingOverflow(directories)
            guard !overflow else { return .max }
            let (total, rootOverflow) = subtotal.addingReportingOverflow(1)
            return rootOverflow ? .max : total
        }

        let (totalNodeCount, nodeCountOverflow) = nodeCount(before)
            .addingReportingOverflow(nodeCount(after))
        guard !nodeCountOverflow else { return false }
        let (estimatedWorkingSet, sizeOverflow) = totalNodeCount
            .multipliedReportingOverflow(by: 2_300)
        guard !sizeOverflow else { return false }
        return estimatedWorkingSet <= physicalMemory / 4
    }

    private enum ScanStartIntent: Sendable {
        case scan
        case rescan
    }

    func startScan(_ target: ScanTarget) {
        scheduleScanStart(target, intent: .scan)
    }

    private func scheduleScanStart(_ target: ScanTarget, intent: ScanStartIntent) {
        // Defer state mutations to the next runloop to avoid
        // "Publishing changes from within view updates is not allowed."
        cancelArchiveOperation()
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationContextUpdate()
        cancelDeferredDiscardPileAdd()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()

        scheduleDeferredViewUpdate(
            .scanStart
        ) { model in
            model.startScanNow(target, intent: intent)
        }
    }

    private func cancelDeferrals(_ kinds: DeferredWorkKind...) {
        for kind in kinds {
            deferredWorkBoxes[kind]?.cancel()
            deferredWorkBoxes[kind] = nil
        }
        if kinds.contains(.navigationContext) {
            deferredNavigationContextSnapshotID = nil
        }
    }

    private func cancelDeferredScanStart() {
        cancelDeferrals(.scanStart)
    }

    private func cancelDeferredSidebarSelection() {
        cancelDeferrals(.sidebarSelection)
    }

    private func cancelDeferredNavigationAction() {
        cancelDeferrals(.navigationAction)
    }

    private func cancelDeferredVisualizationModeUpdate() {
        cancelDeferrals(.visualizationMode)
    }

    private func cancelDeferredDiscardPileAdd() {
        cancelDeferrals(.discardPileAdd)
    }

    private func cancelDeferredNavigationContextUpdate() {
        cancelDeferrals(.navigationContext)
    }

    private func scheduleDeferredNavigationContextUpdate(for snapshotID: UUID) {
        scheduleDeferredViewUpdate(
            .navigationContext
        ) { model in
            guard model.deferredNavigationContextSnapshotID == snapshotID,
                  model.scanCoordinator.snapshot?.id == snapshotID else {
                if model.deferredNavigationContextSnapshotID == snapshotID {
                    model.deferredNavigationContextSnapshotID = nil
                }
                return
            }

            model.deferredNavigationContextSnapshotID = nil
            model.navigationModel.refreshTableNodesForCurrentContext()
        }
    }

    private func cancelPostTrashSnapshotRemoval() {
        trashFlow.cancelPostTrashSnapshotRemoval()
    }

    private func cancelConfirmedTrashMove() {
        trashFlow.cancelConfirmedTrashMove()
    }

    private func clearOptimisticTrashVisibility() {
        trashFlow.clearOptimisticTrashVisibility()
    }

    private func scheduleDeferredViewUpdate(
        _ kind: DeferredWorkKind,
        perform: @MainActor @Sendable @escaping (AppModel) -> Void
    ) {
        let actionID = UUID()
        deferredWorkBoxes[kind] = DeferredWorkBox(id: actionID, task: nil)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.viewUpdateDeferralDelay)
            guard let self,
                  self.deferredWorkBoxes[kind]?.id == actionID,
                  !Task.isCancelled else {
                return
            }

            self.deferredWorkBoxes[kind] = nil
            perform(self)
        }
        deferredWorkBoxes[kind]?.task = task
    }

    func setScanVisualizationModeAfterViewUpdate(_ mode: ScanVisualizationMode) {
        cancelDeferredVisualizationModeUpdate()
        guard scanVisualizationMode != mode else { return }

        scheduleDeferredViewUpdate(
            .visualizationMode
        ) { model in
            model.scanVisualizationMode = mode
        }
    }

    private func startScanNow(_ target: ScanTarget, intent: ScanStartIntent) {
        cancelArchiveOperation()
        let options = scanOptions(for: target)
        let baseline: ScanSnapshot?
        switch intent {
        case .scan:
            baseline = incrementalRescanBaseline(
                for: target,
                options: options,
                currentSnapshot: scanCoordinator.snapshot
            )
        case .rescan:
            baseline = scanCoordinator.snapshot
        }
        sidebarScanCacheController.prepareForScanStart(target: target, options: options)
        scanCoordinator.startScan(
            target,
            options: options,
            baseline: baseline,
            isRescan: intent == .rescan || baseline != nil
        ) {
            prepareForScan(target)
        }
    }

    private func incrementalRescanBaseline(
        for target: ScanTarget,
        options: ScanOptions,
        currentSnapshot: ScanSnapshot?
    ) -> ScanSnapshot? {
        guard let currentSnapshot,
              currentSnapshot.isComplete,
              currentSnapshot.source.allowsFileMutation,
              currentSnapshot.target.kind == target.kind,
              Self.normalizedTargetPath(currentSnapshot.target) == Self.normalizedTargetPath(target),
              currentSnapshot.scanOptions == options else {
            return nil
        }
        return currentSnapshot
    }

    nonisolated private static func normalizedTargetPath(_ target: ScanTarget) -> String {
        URL(filePath: target.url.path, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
    }

    var canRescanEntireScan: Bool {
        guard scanCoordinator.canRescan,
              !isArchiveOperationInProgress else {
            return false
        }
        if let snapshot = scanCoordinator.snapshot {
            return snapshot.source.allowsFileMutation
        }
        return scanCoordinator.phase == .failed
    }

    var canRescanCurrentFolder: Bool {
        guard let snapshot = scanCoordinator.snapshot,
              snapshot.source.allowsFileMutation,
              let focusedNodeID = navigationModel.focusedNodeID else {
            return canRescanEntireScan
        }
        if focusedNodeID == snapshot.root.id {
            return canRescanEntireScan
        }
        return !isArchiveOperationInProgress
            && scanCoordinator.canRescanFolder(id: focusedNodeID)
    }

    func rescan() {
        guard let snapshot = scanCoordinator.snapshot,
              let focusedNodeID = navigationModel.focusedNodeID,
              focusedNodeID != snapshot.root.id else {
            rescanEntireScan()
            return
        }
        rescanFolder(id: focusedNodeID)
    }

    func rescanEntireScan() {
        guard canRescanEntireScan,
              let selectedTarget = scanCoordinator.selectedTarget else { return }
        scheduleScanStart(selectedTarget, intent: .rescan)
    }

    func rescanFolder(id nodeID: FileNodeRecord.ID) {
        guard !isArchiveOperationInProgress else { return }
        scanCoordinator.rescanFolder(id: nodeID)
    }

    func cachedFreeSpaceAvailableCapacity(for snapshot: ScanSnapshot, focusNode: FileNodeRecord) -> Int64? {
        guard showFreeSpaceInDiskMaps,
              snapshot.target.kind == .volume,
              snapshot.overlappingAllocatedBytes == nil,
              focusNode.id == snapshot.root.id,
              diskFreeSpaceCapacityCache?.key == diskFreeSpaceCapacityKey(for: snapshot) else {
            return nil
        }

        return diskFreeSpaceCapacityCache?.availableCapacity
    }

    func stopScan(resetState: Bool = true) {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        clearOptimisticTrashVisibility()
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

    func revealAfterViewUpdate(nodeID: String) {
        scheduleDeferredNavigationAction(.reveal(nodeID))
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
            let node = try validatedSelection(requiresDirectory: true, requiresLivePath: false)
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
            .navigationAction
        ) { model in
            model.performNavigationAction(action)
        }
    }

    private func performNavigationAction(_ action: NavigationAction) {
        switch action {
        case .select(let nodeID):
            guard let nodeID else {
                navigationModel.select(nodeID: nil)
                return
            }
            navigationModel.select(nodeID: nodeID)
        case .selectMultiple(let nodeIDs, let primary):
            let visibleNodeIDs = visibleNavigationNodeIDs(from: nodeIDs)
            guard !visibleNodeIDs.isEmpty || nodeIDs.isEmpty else { return }
            let visiblePrimary = primary.flatMap { visibleNodeIDs.contains($0) ? $0 : nil }
            navigationModel.select(nodeIDs: visibleNodeIDs, primaryNodeID: visiblePrimary)
        case .focus(let nodeID):
            guard let nodeID else {
                navigationModel.focus(nodeID: nil)
                return
            }
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.focus(nodeID: nodeID)
        case .selectAndFocus(let nodeID):
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.selectAndFocus(nodeID: nodeID)
        case .reveal(let nodeID):
            guard isVisibleNavigationNode(nodeID) else { return }
            navigationModel.reveal(nodeID: nodeID)
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

    private func visibleNavigationNodeIDs(from nodeIDs: Set<FileNodeRecord.ID>) -> Set<FileNodeRecord.ID> {
        guard let snapshotID = scanCoordinator.snapshot?.id,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            return nodeIDs
        }

        let hiddenIDs = hiddenNodeIDs(for: snapshotID)
        guard !hiddenIDs.isEmpty else { return nodeIDs }
        let hiddenNodes = fileTreeStore.preparedNodeSet(for: hiddenIDs)
        return nodeIDs.filter { !fileTreeStore.isNodeOrDescendant($0, of: hiddenNodes) }
    }

    private func isVisibleNavigationNode(_ nodeID: FileNodeRecord.ID) -> Bool {
        visibleNavigationNodeIDs(from: [nodeID]).contains(nodeID)
    }

    func selectSidebarTarget(id: String?) {
        cancelDeferredSidebarSelection()
        selectSidebarTargetNow(id: id)
    }

    func selectSidebarTargetAfterViewUpdate(id: String?) {
        cancelDeferredSidebarSelection()

        scheduleDeferredViewUpdate(
            .sidebarSelection
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
            let nodes = try validatedSelectedNodes(requiresLivePath: true)
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
            let node = try validatedSelection(requiresLivePath: true)
            dependencies.systemActions.reveal(node.url)
        } catch {
            presentError(error)
        }
    }

    func revealNodesInFinder(_ nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodes(nodes, requiresLivePath: true)
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
            let node = try validatedSelection(requiresLivePath: true)
            try dependencies.systemActions.open(node.url)
        } catch {
            presentError(error)
        }
    }

    func openSelectedInTerminal() async {
        do {
            let node = try validatedSelection(requiresLivePath: true)
            try await dependencies.systemActions.openInTerminal(node.terminalDirectoryURL)
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
            let nodes = try validatedSelectedNodesForPathCopy()
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
            let node = try validatedSelectionForPathCopy()
            try dependencies.systemActions.copyPath(node.url)
        } catch {
            presentError(error)
        }
    }

    func copyPaths(for nodes: [FileNodeRecord]) {
        do {
            let nodes = try validatedNodesForPathCopy(nodes)
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
        do {
            try requestTrashMove(for: validatedSelectedNodesForMutation())
        } catch {
            presentError(error)
        }
    }

    func requestMovePrimarySelectionToTrash() {
        do {
            let node = try validatedSelectionForMutation()
            guard node.supportsMoveToTrash(
                activeTarget: scanCoordinator.selectedTarget,
                trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
            ) else {
                throw FileActionError.unsupported
            }

            pendingTrashSelection = PendingTrashSelection(nodes: [node])
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func requestMoveNodesToTrash(_ nodes: [FileNodeRecord]) -> Bool {
        requestMoveNodesToTrash(nodes, allowingHiddenNodes: false)
    }

    @discardableResult
    private func requestMoveNodesToTrash(
        _ nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool
    ) -> Bool {
        do {
            let nodes = try validatedNodesForMutation(
                nodes,
                allowingHiddenNodes: allowingHiddenNodes
            )
            try requestTrashMove(
                for: nodes,
                allowingHiddenNodes: allowingHiddenNodes
            )
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func requestTrashMove(
        for nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool = false
    ) throws {
        try trashFlow.stageTrashRequest(
            for: nodes,
            activeTarget: scanCoordinator.selectedTarget,
            trashSafetyPolicy: scanCoordinator.trashSafetyPolicy,
            fileTreeStore: scanCoordinator.fileTreeStore,
            allowingHiddenNodes: allowingHiddenNodes
        )
    }

    @discardableResult
    func addSelectedNodesToDiscardPile() -> Bool {
        addNodesToDiscardPile(navigationModel.selectedNodes)
    }

    @discardableResult
    func addPrimarySelectionToDiscardPile() -> Bool {
        guard let node = navigationModel.selectedNode else {
            presentError(FileActionError.noSelection)
            return false
        }

        return addNodesToDiscardPile([node])
    }

    func addPrimarySelectionToDiscardPileAfterViewUpdate() {
        guard let node = navigationModel.selectedNode else {
            presentError(FileActionError.noSelection)
            return
        }

        scheduleDeferredDiscardPileAdd([node])
    }

    @discardableResult
    func addNodeIDsToDiscardPile(
        _ nodeIDs: [FileNodeRecord.ID],
        snapshotID: UUID
    ) -> Bool {
        guard scanCoordinator.snapshot?.id == snapshotID else {
            presentError(FileActionError.unsupported)
            return false
        }
        guard let fileTreeStore = scanCoordinator.fileTreeStore else {
            presentError(FileActionError.unsupported)
            return false
        }

        guard !nodeIDs.isEmpty else {
            presentError(FileActionError.unsupported)
            return false
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(nodeIDs.count)
        for nodeID in nodeIDs {
            guard let node = fileTreeStore.node(id: nodeID) else {
                presentError(FileActionError.unsupported)
                return false
            }
            nodes.append(node)
        }

        return addNodesToDiscardPile(nodes)
    }

    @discardableResult
    func addNodesToDiscardPile(_ nodes: [FileNodeRecord]) -> Bool {
        do {
            let nodes = try validatedNodesForDiscardPile(nodes)
            guard nodes.allSatisfy({ node in
                node.supportsMoveToTrash(
                    activeTarget: scanCoordinator.selectedTarget,
                    trashSafetyPolicy: scanCoordinator.trashSafetyPolicy
                )
            }) else {
                throw FileActionError.unsupported
            }
            let discardNodes = topLevelTrashNodes(from: nodes)
            if let cloudImpact = cloudStorageImpact(of: discardNodes) {
                pendingCloudFileAction = PendingCloudFileAction(
                    kind: .addToDiscardPile,
                    nodes: discardNodes,
                    cloudImpact: cloudImpact
                )
                return true
            }
            try commitDiscardPileAddition(discardNodes)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func scheduleDeferredDiscardPileAdd(_ nodes: [FileNodeRecord]) {
        cancelDeferredDiscardPileAdd()

        scheduleDeferredViewUpdate(
            .discardPileAdd
        ) { model in
            model.addNodesToDiscardPile(nodes)
        }
    }

    func removeDiscardPileNode(id nodeID: FileNodeRecord.ID) {
        removeDiscardPileNodes(ids: [nodeID])
    }

    func removeDiscardPileNodes(ids nodeIDs: Set<FileNodeRecord.ID>) {
        trashFlow.removeDiscardPileNodes(ids: nodeIDs)
    }

    func clearDiscardPile() {
        trashFlow.clearDiscardPile()
    }

    @discardableResult
    func requestMoveDiscardPileToTrash() -> Bool {
        reconcileDiscardPile()
        return requestMoveNodesToTrash(
            topLevelTrashNodes(from: resolvedDiscardPileNodes()),
            allowingHiddenNodes: true
        )
    }

    func confirmMovePendingSelectionToTrash() {
        let allowsHiddenNodes = pendingTrashSelection?.allowsHiddenNodes == true
        let nodes = pendingTrashSelection?.nodes ?? []
        guard !nodes.isEmpty else { return }
        pendingTrashSelection = nil

        if !allowsHiddenNodes {
            do {
                try validateMutationDoesNotIncludeHiddenNodes(nodes)
            } catch {
                presentError(error)
                return
            }
        }

        if let cloudImpact = cloudStorageImpact(of: nodes) {
            pendingCloudFileAction = PendingCloudFileAction(
                kind: .moveToTrash(allowsHiddenNodes: allowsHiddenNodes),
                nodes: nodes,
                cloudImpact: cloudImpact
            )
            return
        }

        performConfirmedTrashMove(nodes)
    }

    func confirmPendingCloudFileAction() {
        guard let action = pendingCloudFileAction else { return }
        pendingCloudFileAction = nil

        do {
            switch action.kind {
            case .addToDiscardPile:
                let nodes = try validatedNodesForDiscardPile(action.nodes)
                try commitDiscardPileAddition(topLevelTrashNodes(from: nodes))
            case .moveToTrash(let allowsHiddenNodes):
                let nodes = try validatedNodesForMutation(
                    action.nodes,
                    allowingHiddenNodes: allowsHiddenNodes
                )
                performConfirmedTrashMove(nodes)
            }
        } catch {
            presentError(error)
        }
    }

    func cancelPendingCloudFileAction() {
        pendingCloudFileAction = nil
    }

    private func commitDiscardPileAddition(_ nodes: [FileNodeRecord]) throws {
        guard let snapshot = scanCoordinator.snapshot,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            throw FileActionError.unsupported
        }
        addDiscardPileNodes(
            nodes,
            snapshot: snapshot,
            fileTreeStore: fileTreeStore
        )
    }

    private func cloudStorageImpact(
        of nodes: [FileNodeRecord]
    ) -> CloudStorageLocation.Impact? {
        var containsCloudStorage = false
        var existenceByRootPath: [String: Bool] = [:]
        let cloudRootExists = { (root: URL) -> Bool in
            if let cachedExistence = existenceByRootPath[root.path] {
                return cachedExistence
            }
            let rootExists = self.dependencies.systemActions.fileExists(root)
            existenceByRootPath[root.path] = rootExists
            return rootExists
        }
        for node in nodes {
            switch CloudStorageLocation.impact(
                of: node.url,
                cloudRootExists: cloudRootExists
            ) {
            case .storedInCloud:
                return .storedInCloud
            case .containsCloudStorage:
                containsCloudStorage = true
            case nil:
                continue
            }
        }
        return containsCloudStorage ? .containsCloudStorage : nil
    }

    private func performConfirmedTrashMove(_ nodes: [FileNodeRecord]) {
        let originalSnapshotID = scanCoordinator.snapshot?.id
        let statsFileTreeStore = scanCoordinator.fileTreeStore
        let actions = dependencies.systemActions

        if usesAsyncTrashActions {
            confirmedTrashMoveTask = Task { @MainActor [weak self] in
                await self?.trashFlow.runConfirmedMoveAsynchronously(
                    nodes,
                    originalSnapshotID: originalSnapshotID,
                    statsFileTreeStore: statsFileTreeStore,
                    actions: actions,
                    beginMove: { snapshotID, _ in
                        guard let self else { return }
                        let activeFileTreeStore = self.scanCoordinator.fileTreeStore
                        let didHide = self.trashFlow.hideTrashNodesDuringMove(
                            nodes,
                            snapshotID: snapshotID,
                            activeSnapshotID: self.scanCoordinator.snapshot?.id,
                            activeFileTreeStore: activeFileTreeStore
                        )
                        if didHide, let activeFileTreeStore {
                            self.reconcileNavigationForHiddenNodes(
                                hiddenNodeIDs: self.hiddenNodeIDs(for: snapshotID),
                                fileTreeStore: activeFileTreeStore
                            )
                        }
                    },
                    onFinish: { requested, moved, actionError, wasCancelled in
                        self?.finishConfirmedTrashMove(
                            requestedNodes: requested,
                            movedNodes: moved,
                            actionError: actionError,
                            originalSnapshotID: originalSnapshotID,
                            statsFileTreeStore: statsFileTreeStore,
                            wasCancelled: wasCancelled
                        )
                    }
                )
            }
        } else {
            trashFlow.runConfirmedMoveSynchronously(
                nodes,
                originalSnapshotID: originalSnapshotID,
                statsFileTreeStore: statsFileTreeStore,
                actions: actions,
                beginMove: { snapshotID, _ in
                    let activeFileTreeStore = scanCoordinator.fileTreeStore
                    let didHide = trashFlow.hideTrashNodesDuringMove(
                        nodes,
                        snapshotID: snapshotID,
                        activeSnapshotID: scanCoordinator.snapshot?.id,
                        activeFileTreeStore: activeFileTreeStore
                    )
                    if didHide, let activeFileTreeStore {
                        reconcileNavigationForHiddenNodes(
                            hiddenNodeIDs: hiddenNodeIDs(for: snapshotID),
                            fileTreeStore: activeFileTreeStore
                        )
                    }
                },
                onFinish: { requested, moved, actionError in
                    finishConfirmedTrashMove(
                        requestedNodes: requested,
                        movedNodes: moved,
                        actionError: actionError,
                        originalSnapshotID: originalSnapshotID,
                        statsFileTreeStore: statsFileTreeStore,
                        wasCancelled: false
                    )
                }
            )
        }
    }

    private var usesAsyncTrashActions: Bool {
        dependencies.systemActions.asyncMoveToTrash != nil
    }

    private func finishConfirmedTrashMove(
        requestedNodes: [FileNodeRecord],
        movedNodes: [FileNodeRecord],
        actionError: Error?,
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?,
        wasCancelled: Bool = false
    ) {
        if !movedNodes.isEmpty {
            if discardPile.snapshotID == originalSnapshotID {
                removeMovedNodesFromDiscardPile(movedNodes, fileTreeStore: statsFileTreeStore)
            }
            recordTrashMove(movedNodes, fileTreeStore: statsFileTreeStore)
            sidebarScanCacheController.clearCache()
            if shouldApplyPostTrashSnapshotUpdate(originalSnapshotID: originalSnapshotID) {
                handleMovedToTrash(movedNodes)
            }
            refreshAvailableTargets()
        }

        if let actionError {
            trashFlow.unhideTrashNodesAfterFailedMove(
                requestedNodes: requestedNodes,
                movedNodes: movedNodes,
                snapshotID: originalSnapshotID
            )
            presentError(actionError)
        } else if wasCancelled {
            trashFlow.unhideTrashNodesAfterFailedMove(
                requestedNodes: requestedNodes,
                movedNodes: movedNodes,
                snapshotID: originalSnapshotID
            )
        }
    }

    private func shouldApplyPostTrashSnapshotUpdate(originalSnapshotID: UUID?) -> Bool {
        guard let originalSnapshotID else { return true }
        return scanCoordinator.snapshot?.id == originalSnapshotID
    }

    private func handleMovedToTrash(_ nodes: [FileNodeRecord]) {
        var shouldClearActiveScan = false
        var removalNodeIDs: [FileNodeRecord.ID] = []
        var fallbackFocusID: FileNodeRecord.ID?

        for node in nodes {
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: scanCoordinator.selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                shouldClearActiveScan = true
            case .removeFromActiveScan:
                removalNodeIDs.append(node.id)
                fallbackFocusID = fallbackFocusID ?? postTrashFocusFallbackID(for: node)
            case .none:
                break
            }
        }

        if shouldClearActiveScan {
            cancelPostTrashSnapshotRemoval()
            scanCoordinator.clearScan()
            navigationModel.reset()
            sidebarModel.setActiveTargetID(nil)
            sidebarScanCacheController.clearDisplayedSnapshot()
        } else if !removalNodeIDs.isEmpty {
            enqueuePostTrashSnapshotRemoval(
                nodeIDs: removalNodeIDs,
                fallbackFocusID: fallbackFocusID
            )
        }
    }

    func cancelPendingTrash() {
        pendingTrashSelection = nil
    }

    func reconcileDiscardPile() {
        guard !discardPile.isEmpty else { return }
        guard let snapshot = scanCoordinator.snapshot,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            discardPile = DiscardPileState()
            return
        }
        guard discardPile.snapshotID == snapshot.id else {
            discardPile = DiscardPileState()
            return
        }

        reconcileDiscardPile(snapshotID: snapshot.id, fileTreeStore: fileTreeStore)
    }

    private func postTrashFocusFallbackID(for node: FileNodeRecord) -> FileNodeRecord.ID? {
        guard let treeStore = scanCoordinator.fileTreeStore,
              treeStore.isAncestor(node.id, of: navigationModel.focusedNodeID) else {
            return nil
        }

        return treeStore.parent(of: node.id)?.id ?? treeStore.root.id
    }

    private func enqueuePostTrashSnapshotRemoval(
        nodeIDs: [FileNodeRecord.ID],
        fallbackFocusID: FileNodeRecord.ID?
    ) {
        postTrashRemovalRequests.append(PostTrashRemovalRequest(
            nodeIDs: nodeIDs,
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
                let didRemove = await self.scanCoordinator.removeNodesFromCurrentSnapshot(ids: request.nodeIDs)
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

    private func presentError(_ error: Error, title: String? = nil) {
        if let title {
            lastActionErrorTitle = title
        } else if let fileActionError = error as? FileActionError {
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
        try validatedSelection(requiresDirectory: requiresDirectory, requiresLivePath: true)
    }

    private func validatedSelection(
        requiresDirectory: Bool = false,
        requiresLivePath: Bool
    ) throws -> FileNodeRecord {
        guard let selectedNode = navigationModel.selectedNode else {
            throw FileActionError.noSelection
        }
        guard selectedNode.supportsFileActions else {
            throw FileActionError.unsupported
        }
        if requiresDirectory, !selectedNode.isDirectory {
            throw FileActionError.directoryRequired
        }
        if requiresLivePath {
            try validateLivePathAction(selectedNode)
        }
        return selectedNode
    }

    private func validatedSelectedNodes(requiresLivePath: Bool) throws -> [FileNodeRecord] {
        try validatedNodes(
            navigationModel.selectedNodes,
            requiresLivePath: requiresLivePath
        )
    }

    private func validatedNodes(
        _ nodes: [FileNodeRecord],
        requiresLivePath: Bool
    ) throws -> [FileNodeRecord] {
        guard !nodes.isEmpty else {
            throw FileActionError.noSelection
        }

        for node in nodes {
            guard node.supportsFileActions else {
                throw FileActionError.unsupported
            }
            if requiresLivePath {
                try validateLivePathAction(node)
            }
        }

        return nodes
    }

    private func validatedSelectionForPathCopy() throws -> FileNodeRecord {
        try validatePathCopyAllowed()
        return try validatedSelection(requiresLivePath: false)
    }

    private func validatedSelectedNodesForPathCopy() throws -> [FileNodeRecord] {
        try validatePathCopyAllowed()
        return try validatedSelectedNodes(requiresLivePath: false)
    }

    private func validatedNodesForPathCopy(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validatePathCopyAllowed()
        return try validatedNodes(nodes, requiresLivePath: false)
    }

    private func validatedSelectionForMutation() throws -> FileNodeRecord {
        try validateSnapshotAllowsMutation()
        let node = try validatedSelection(requiresLivePath: true)
        try validateMutationDoesNotIncludeHiddenNodes([node])
        return node
    }

    private func validatedNodesForMutation(
        _ nodes: [FileNodeRecord],
        allowingHiddenNodes: Bool = false
    ) throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        let nodes = try validatedNodes(nodes, requiresLivePath: true)
        if !allowingHiddenNodes {
            try validateMutationDoesNotIncludeHiddenNodes(nodes)
        }
        return nodes
    }

    private func validatedSelectedNodesForMutation() throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        let visibleNodeIDs = visibleNavigationNodeIDs(from: navigationModel.selectedNodeIDs)
        let visibleNodes = navigationModel.selectedNodes.filter {
            visibleNodeIDs.contains($0.id)
        }
        return try validatedNodes(visibleNodes, requiresLivePath: true)
    }

    private func validatedNodesForDiscardPile(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        return try validatedNodes(nodes, requiresLivePath: false)
    }

    private func validateLivePathAction(_ node: FileNodeRecord) throws {
        guard scanCoordinator.snapshotSource.allowsLivePathActions else {
            throw FileActionError.unsupported
        }
        guard dependencies.systemActions.fileExists(node.url) else {
            clearSelection()
            throw FileActionError.unavailable(path: node.url.path)
        }
        try validateImportedIdentityIfAvailable(node)
    }

    private func validateImportedIdentityIfAvailable(_ node: FileNodeRecord) throws {
        guard scanCoordinator.snapshotSource.isImported,
              node.fileIdentity != nil else {
            return
        }

        switch dependencies.systemActions.verifyTrashIdentity(node) {
        case .matches, .missingScannedIdentity:
            return
        case .missingCurrentItem:
            clearSelection()
            throw FileActionError.unavailable(path: node.url.path)
        case .mismatch:
            throw FileActionError.changedSinceScan(path: node.url.path)
        case .metadataUnavailable(let reason):
            throw FileActionError.currentIdentityUnavailable(path: node.url.path, reason: reason)
        }
    }

    private func validatePathCopyAllowed() throws {
        guard scanCoordinator.snapshotSource.allowsArchivedPathCopy else {
            throw FileActionError.unsupported
        }
    }

    private func validateSnapshotAllowsMutation() throws {
        guard scanCoordinator.snapshotSource.allowsFileMutation else {
            throw FileActionError.readOnlySnapshot
        }
    }

    private func validateMutationDoesNotIncludeHiddenNodes(_ nodes: [FileNodeRecord]) throws {
        guard let snapshotID = scanCoordinator.snapshot?.id,
              let fileTreeStore = scanCoordinator.fileTreeStore else {
            return
        }

        let hiddenIDs = hiddenNodeIDs(for: snapshotID)
        guard !hiddenIDs.isEmpty else { return }

        let requestedIDs = Set(nodes.map(\.id))
        let hiddenNodes = fileTreeStore.preparedNodeSet(for: hiddenIDs)
        let requestedNodes = fileTreeStore.preparedNodeSet(for: requestedIDs)
        let requestedNodeIsHidden = requestedIDs.contains(where: { requestedID in
            fileTreeStore.isNodeOrDescendant(requestedID, of: hiddenNodes)
        })
        let requestedNodeContainsHiddenNode = hiddenIDs.contains(where: { hiddenID in
            fileTreeStore.isNodeOrDescendant(hiddenID, of: requestedNodes)
        })

        guard !requestedNodeIsHidden && !requestedNodeContainsHiddenNode else {
            throw FileActionError.unsupported
        }
    }

    private func topLevelTrashNodes(from nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        TrashFlowController.topLevelTrashNodes(
            from: nodes,
            fileTreeStore: scanCoordinator.fileTreeStore
        )
    }

    private func hiddenNodeIDs(for snapshotID: UUID?) -> Set<FileNodeRecord.ID> {
        guard let snapshotID else { return [] }

        var nodeIDs = Set<FileNodeRecord.ID>()
        if discardPile.snapshotID == snapshotID {
            nodeIDs.formUnion(discardPile.nodeIDs)
        }
        if optimisticTrashVisibility.snapshotID == snapshotID {
            nodeIDs.formUnion(optimisticTrashVisibility.nodeIDs)
        }
        return nodeIDs
    }

    private func addDiscardPileNodes(
        _ nodes: [FileNodeRecord],
        snapshot: ScanSnapshot,
        fileTreeStore: FileTreeStore
    ) {
        guard !nodes.isEmpty else { return }

        let queuedIDs = (discardPile.snapshotID == snapshot.id ? discardPile.nodeIDs : []) + nodes.map(\.id)
        let deduplicatedIDs = deduplicatedDiscardPileIDs(queuedIDs, fileTreeStore: fileTreeStore)
        reconcileNavigationForHiddenNodes(
            hiddenNodeIDs: hiddenNodeIDs(for: snapshot.id).union(deduplicatedIDs),
            fileTreeStore: fileTreeStore,
            preservingSelection: navigationModel.selectedNodeIDs.count == 1
        )
        discardPile = DiscardPileState(nodeIDs: deduplicatedIDs, snapshotID: snapshot.id)
    }

    private func deduplicatedDiscardPileIDs(
        _ nodeIDs: [FileNodeRecord.ID],
        fileTreeStore: FileTreeStore
    ) -> [FileNodeRecord.ID] {
        fileTreeStore.topLevelNodeIDs(from: nodeIDs)
    }

    private func resolvedDiscardPileNodes() -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return [] }
        return discardPile.nodeIDs.compactMap { fileTreeStore.node(id: $0) }
    }

    private func reconcileNavigationForHiddenNodes(
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore,
        preservingSelection: Bool = false
    ) {
        guard !hiddenNodeIDs.isEmpty else { return }
        let hiddenNodes = fileTreeStore.preparedNodeSet(for: hiddenNodeIDs)

        if let focusedNodeID = navigationModel.focusedNodeID,
           fileTreeStore.isNodeOrDescendant(focusedNodeID, of: hiddenNodes) {
            navigationModel.setFocusedNodeID(
                hiddenNodeFocusFallbackID(
                    for: focusedNodeID,
                    hiddenNodes: hiddenNodes,
                    fileTreeStore: fileTreeStore
                )
            )
        }

        if !preservingSelection,
           navigationModel.selectedNodeIDs.contains(where: { selectedNodeID in
               fileTreeStore.isNodeOrDescendant(selectedNodeID, of: hiddenNodes)
           }) {
            navigationModel.clearSelection()
        }

        navigationModel.reconcileFocusHistory(excluding: hiddenNodeIDs)
    }

    private func hiddenNodeFocusFallbackID(
        for nodeID: FileNodeRecord.ID,
        hiddenNodes: PreparedFileTreeNodeSet,
        fileTreeStore: FileTreeStore
    ) -> FileNodeRecord.ID? {
        var parentID = fileTreeStore.parent(of: nodeID)?.id
        while let candidateID = parentID {
            if !fileTreeStore.isNodeOrDescendant(candidateID, of: hiddenNodes) {
                return candidateID
            }
            parentID = fileTreeStore.parent(of: candidateID)?.id
        }
        return fileTreeStore.rootID
    }

    private func removeMovedNodesFromDiscardPile(
        _ movedNodes: [FileNodeRecord],
        fileTreeStore: FileTreeStore?
    ) {
        guard !discardPile.isEmpty, !movedNodes.isEmpty else { return }

        let movedIDs = Set(movedNodes.map(\.id))
        let movedNodeSet = fileTreeStore?.preparedNodeSet(for: movedIDs)
        let remainingIDs = discardPile.nodeIDs.filter { queuedID in
            guard !movedIDs.contains(queuedID) else { return false }
            guard let fileTreeStore, let movedNodeSet else { return true }
            return !fileTreeStore.isNodeOrDescendant(queuedID, of: movedNodeSet)
        }
        guard remainingIDs != discardPile.nodeIDs else { return }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    private func syncDiscardPile(with snapshot: ScanSnapshot?) {
        guard !discardPile.isEmpty else { return }
        guard let snapshot else {
            discardPile = DiscardPileState()
            return
        }
        guard discardPile.snapshotID == snapshot.id else {
            discardPile = DiscardPileState()
            return
        }
        reconcileDiscardPile(snapshotID: snapshot.id, fileTreeStore: snapshot.treeStore)
    }

    private func syncOptimisticTrashVisibility(with snapshot: ScanSnapshot?) {
        guard optimisticTrashVisibility.snapshotID != nil else { return }
        guard let snapshot,
              optimisticTrashVisibility.snapshotID == snapshot.id else {
            trashFlow.clearOptimisticTrashVisibility()
            return
        }

        let nodeIDs = optimisticTrashVisibility.nodeIDs.filter { snapshot.treeStore.node(id: $0) != nil }
        guard nodeIDs != optimisticTrashVisibility.nodeIDs else { return }
        trashFlow.replaceOptimisticTrashVisibility(
            nodeIDs: nodeIDs,
            snapshotID: snapshot.id
        )
    }

    private func reconcileDiscardPile(
        snapshotID: UUID,
        fileTreeStore: FileTreeStore
    ) {
        let reconciledIDs = deduplicatedDiscardPileIDs(
            discardPile.nodeIDs.filter { fileTreeStore.node(id: $0) != nil },
            fileTreeStore: fileTreeStore
        )
        guard reconciledIDs != discardPile.nodeIDs else { return }
        discardPile = DiscardPileState(
            nodeIDs: reconciledIDs,
            snapshotID: snapshotID
        )
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        dependencies.systemActions.isExistingDirectory(url)
    }

    private func prepareForScan(_ target: ScanTarget) {
        lastErrorMessage = nil
        scanComparison = nil
        navigationModel.reset()
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        pendingTrashSelection = nil
        pendingCloudFileAction = nil
        discardPile = DiscardPileState()
        clearOptimisticTrashVisibility()
        sidebarModel.setActiveTargetID(target.id)

        registerRecentTarget(target)
        refreshAvailableTargets()
    }

    private func restoreImportedSnapshot(_ snapshot: ScanSnapshot) {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.cancelPendingSidebarTargetRestore()
        sidebarScanCacheController.clearActiveScanTracking()
        sidebarScanCacheController.clearDisplayedSnapshot()
        deferredNavigationContextSnapshotID = snapshot.id
        scanCoordinator.restoreCompletedSnapshot(snapshot) {
            prepareForImportedSnapshot()
        }
        navigationModel.updateScanContext(snapshot: snapshot, loadTableNodesImmediately: false)
        scheduleDeferredNavigationContextUpdate(for: snapshot.id)
    }

    private func prepareForImportedSnapshot() {
        lastErrorMessage = nil
        scanComparison = nil
        navigationModel.reset()
        pendingComparisonSetup = nil
        pendingImportPreview = nil
        pendingTrashSelection = nil
        pendingCloudFileAction = nil
        discardPile = DiscardPileState()
        clearOptimisticTrashVisibility()
        sidebarModel.setActiveTargetID(nil)
        quickLookController.closePreview()
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
        scanCoordinator.onScanFinished = { [weak self] snapshot in
            self?.recordCompletedScan(snapshot)
        }

        scanCoordinator.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                refreshDiskFreeSpaceCapacity(for: snapshot)
                syncOptimisticTrashVisibility(with: snapshot)
                syncDiscardPile(with: snapshot)
                if let snapshotID = snapshot?.id,
                   snapshotID == deferredNavigationContextSnapshotID {
                    return
                }

                cancelDeferredNavigationContextUpdate()
                navigationModel.updateScanContext(snapshot: snapshot)
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

    private func recordCompletedScan(_ snapshot: ScanSnapshot) {
        updateUsageStats { stats in
            stats.recordCompletedScan(snapshot)
        }
    }

    private func recordTrashMove(_ nodes: [FileNodeRecord]) {
        recordTrashMove(nodes, fileTreeStore: scanCoordinator.fileTreeStore)
    }

    private func recordTrashMove(_ nodes: [FileNodeRecord], fileTreeStore: FileTreeStore?) {
        updateUsageStats { stats in
            stats.recordTrashMove(nodes: nodes, fileTreeStore: fileTreeStore)
        }
    }

    private func updateUsageStats(_ update: (inout AppUsageStats) -> Void) {
        var updatedStats = usageStats
        update(&updatedStats)
        guard updatedStats != usageStats else { return }
        usageStats = updatedStats
        dependencies.usageStats.saveUsageStats(updatedStats)
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
                guard let self else { return }
                refreshAvailableTargets()
                refreshDiskFreeSpaceCapacity(for: scanCoordinator.snapshot, force: true)
            }
            .store(in: &cancellables)
    }

    private func refreshDiskFreeSpaceCapacity(
        for snapshot: ScanSnapshot?,
        force: Bool = false
    ) {
        guard showFreeSpaceInDiskMaps,
              let snapshot,
              snapshot.target.kind == .volume,
              snapshot.overlappingAllocatedBytes == nil else {
            cancelDiskFreeSpaceCapacityRefresh(clearCache: true)
            return
        }

        let key = diskFreeSpaceCapacityKey(for: snapshot)
        if !force,
           diskFreeSpaceCapacityCache?.key == key {
            return
        }

        diskFreeSpaceCapacityRefreshGeneration += 1
        let generation = diskFreeSpaceCapacityRefreshGeneration
        diskFreeSpaceCapacityRefreshTask?.cancel()
        if let availableCapacity = snapshot.volumeCapacity?.availableCapacity {
            diskFreeSpaceCapacityCache = DiskFreeSpaceCapacityCache(
                key: key,
                availableCapacity: availableCapacity
            )
            diskFreeSpaceCapacityRefreshTask = nil
            return
        }
        diskFreeSpaceCapacityCache = DiskFreeSpaceCapacityCache(
            key: key,
            availableCapacity: nil
        )

        let systemActions = dependencies.systemActions
        diskFreeSpaceCapacityRefreshTask = Task { [weak self] in
            let availableCapacity = await systemActions.loadVolumeAvailableCapacity(for: snapshot.target.url)
            guard let self,
                  !Task.isCancelled,
                  diskFreeSpaceCapacityRefreshGeneration == generation,
                  diskFreeSpaceCapacityCache?.key == key else {
                return
            }

            diskFreeSpaceCapacityCache = DiskFreeSpaceCapacityCache(
                key: key,
                availableCapacity: availableCapacity
            )
            diskFreeSpaceCapacityRefreshTask = nil
        }
    }

    private func cancelDiskFreeSpaceCapacityRefresh(clearCache: Bool) {
        diskFreeSpaceCapacityRefreshGeneration += 1
        diskFreeSpaceCapacityRefreshTask?.cancel()
        diskFreeSpaceCapacityRefreshTask = nil
        if clearCache {
            diskFreeSpaceCapacityCache = nil
        }
    }

    private func diskFreeSpaceCapacityKey(for snapshot: ScanSnapshot) -> DiskFreeSpaceCapacityKey {
        DiskFreeSpaceCapacityKey(
            snapshotID: snapshot.id,
            volumePath: snapshot.target.url.standardizedFileURL.path
        )
    }

    private func observePreferences() {
        Publishers.CombineLatest3(
            $showHiddenFiles,
            $treatPackagesAsDirectories,
            $maxRenderedDepth
        )
            .combineLatest(Publishers.CombineLatest4(
                $autoSummarizeDirectories,
                $showFreeSpaceInDiskMaps,
                $useScanExclusions,
                $exclusionPatterns
            ))
            .combineLatest($scanVisualizationMode)
            .map { preferences, visualizationMode in
                Self.scanPreferences(preferences.0, preferences.1, visualizationMode)
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
            showFreeSpaceInDiskMaps: showFreeSpaceInDiskMaps,
            visualizationMode: scanVisualizationMode,
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
        _ scanBasics: (Bool, Bool, Int),
        _ scanFilters: (Bool, Bool, Bool, [String]),
        _ visualizationMode: ScanVisualizationMode
    ) -> AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: scanBasics.0,
            treatPackagesAsDirectories: scanBasics.1,
            maxRenderedDepth: scanBasics.2,
            autoSummarizeDirectories: scanFilters.0,
            showFreeSpaceInDiskMaps: scanFilters.1,
            visualizationMode: visualizationMode,
            useScanExclusions: scanFilters.2,
            exclusionPatterns: scanFilters.3
        )
    }

    private func defaultExportFileName(for snapshot: ScanSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dateText = formatter.string(from: snapshot.finishedAt ?? Date())
        let targetName = sanitizedFileName(snapshot.target.displayName)
        return "\(targetName) \(dateText)"
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = name.components(separatedBy: invalidCharacters)
        let sanitizedName = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedName.isEmpty ? "Radix Scan" : sanitizedName
    }

    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

extension AppModel: AppQuickLookControllerDelegate {
    var quickLookSelectionContext: AppQuickLookSelectionContext {
        AppQuickLookSelectionContext(
            selectedNode: navigationModel.selectedNode,
            activeTarget: scanCoordinator.selectedTarget,
            trashSafetyPolicy: scanCoordinator.trashSafetyPolicy,
            snapshotSource: scanCoordinator.snapshotSource
        )
    }

    var isQuickLookKeyboardShortcutBlocked: Bool {
        showsOnboarding ||
            !canUseWorkspaceCommands ||
            pendingTrashSelection != nil ||
            pendingCloudFileAction != nil ||
            navigationModel.selectedNodeIDs.count > 1
    }

    func validatedSelectionForQuickLook() throws -> FileNodeRecord {
        try validatedSelection(requiresLivePath: true)
    }

    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error) {
        presentError(error)
    }
}
