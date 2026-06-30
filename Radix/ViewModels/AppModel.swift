//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Combine
import Foundation

enum ArchiveOperationKind: String, Equatable, Sendable {
    case export
    case importPreview
    case `import`
}

struct ArchiveOperationState: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ArchiveOperationKind
    let title: String
    var message: String
    var progressFraction: Double?

    var isDeterminate: Bool {
        progressFraction != nil
    }
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

    var isEmpty: Bool {
        itemCount == 0
    }
}

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
        case changedSinceScan(path: String)
        case missingScannedIdentity(path: String)
        case currentIdentityUnavailable(path: String, reason: String)
        case unsupported
        case directoryRequired
        case packageContentsHidden(settingEnabled: Bool)
        case folderRequiredForDrop
        case fullDiskAccessSettingsUnavailable
        case readOnlySnapshot

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
            case .changedSinceScan(let path):
                return "The item at \(path) changed since this scan. Rescan before moving it to Trash."
            case .missingScannedIdentity(let path):
                return "Radix could not verify the scanned identity for \(path). Rescan before moving it to Trash."
            case .currentIdentityUnavailable(let path, let reason):
                return "Radix could not verify the current identity for \(path): \(reason)"
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
            case .readOnlySnapshot:
                return "Imported snapshots are read-only."
            }
        }
    }

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published var showFreeSpaceInSunburst = false
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
    @Published private(set) var isExportPanelPresented = false
    @Published var lastErrorMessage: String? {
        didSet {
            if lastErrorMessage == nil {
                lastActionErrorTitle = nil
            }
        }
    }
    @Published private(set) var archiveOperation: ArchiveOperationState?
    @Published private(set) var exportConfirmation: ExportConfirmationState?
    @Published var pendingImportPreview: ScanArchivePreview?
    @Published var pendingTrashNode: FileNodeRecord?
    @Published var pendingTrashSelection: PendingTrashSelection?
    @Published private(set) var discardPile = DiscardPileState()
    @Published private(set) var usageStats = AppUsageStats.empty

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
    private var cancellables = Set<AnyCancellable>()
    private var deferredScanStartTask: Task<Void, Never>?
    private var deferredScanStartID: UUID?
    private var deferredSidebarSelectionTask: Task<Void, Never>?
    private var deferredSidebarSelectionID: UUID?
    private var deferredNavigationActionTask: Task<Void, Never>?
    private var deferredNavigationActionID: UUID?
    private var deferredDiscardPileAddTask: Task<Void, Never>?
    private var deferredDiscardPileAddID: UUID?
    private var deferredNavigationContextTask: Task<Void, Never>?
    private var deferredNavigationContextID: UUID?
    private var deferredNavigationContextSnapshotID: UUID?
    private var postTrashRemovalTask: Task<Void, Never>?
    private var exportPanelTask: Task<Void, Never>?
    private var snapshotArchiveTask: Task<Void, Never>?
    private var snapshotArchiveProgressTask: Task<Void, Never>?
    private var exportConfirmationDismissTask: Task<Void, Never>?
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
        showFreeSpaceInSunburst = preferences.scan.showFreeSpaceInSunburst
        scanCloudStorageFolders = preferences.scan.scanCloudStorageFolders
        useScanExclusions = preferences.scan.useScanExclusions
        exclusionPatterns = preferences.scan.exclusionPatterns
        lastPersistedScanPreferences = preferences.scan
        showsOnboarding = !preferences.didCompleteOnboarding
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
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
        sidebarScanCacheController.resetTransientState()
        fullDiskAccessRefreshTask?.cancel()
        fullDiskAccessRefreshTask = nil
        targetCapacityDescriptionsRefreshTask?.cancel()
        targetCapacityDescriptionsRefreshTask = nil
        exportPanelTask?.cancel()
        exportPanelTask = nil
        isExportPanelPresented = false
        cancelArchiveOperation()
        dismissExportConfirmation()
        pendingImportPreview = nil
        quickLookController.setWorkspaceWindowNumber(nil)
        scanCoordinator.stopScan()
        quickLookController.removeKeyMonitor()
    }

    func suspendMainWindowActivity() {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
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

    var discardPileNodes: [FileNodeRecord] {
        resolvedDiscardPileNodes()
    }

    var discardPileSummary: DiscardPileSummary {
        let nodes = resolvedDiscardPileNodes()
        return DiscardPileSummary(
            itemCount: nodes.count,
            totalAllocatedSize: nodes.reduce(into: Int64(0)) { total, node in
                total += node.allocatedSize
            }
        )
    }

    var discardPileHiddenNodeIDs: Set<FileNodeRecord.ID> {
        guard discardPile.snapshotID == scanCoordinator.snapshot?.id else { return [] }
        return Set(discardPile.nodeIDs)
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

    var isArchiveOperationInProgress: Bool {
        archiveOperation != nil
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
        showFreeSpaceInSunburst = AppScanPreferences.defaults.showFreeSpaceInSunburst
        scanCloudStorageFolders = AppScanPreferences.defaults.scanCloudStorageFolders
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
        guard !scanCoordinator.isScanning else { return }
        if let target = dependencies.systemActions.presentOpenPanel() {
            startScan(target)
        }
    }

    var canExportCurrentScan: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanning &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress
    }

    var canImportScanSnapshot: Bool {
        !scanCoordinator.isScanning &&
            !isExportPanelPresented &&
            !isArchiveOperationInProgress &&
            pendingImportPreview == nil
    }

    private var canConfirmImportPreview: Bool {
        !scanCoordinator.isScanning &&
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
        isExportPanelPresented = true
        exportPanelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isExportPanelPresented = false
                self.exportPanelTask = nil
            }

            guard let destinationURL = await self.dependencies.systemActions.presentExportScanPanel(defaultFileName),
                  !Task.isCancelled,
                  self.scanCoordinator.snapshot?.id == snapshotID,
                  self.canExportCurrentScanIgnoringPresentedPanel else {
                return
            }

            self.startArchiveExport(snapshot: snapshot, destinationURL: destinationURL)
        }
    }

    private var canExportCurrentScanIgnoringPresentedPanel: Bool {
        scanCoordinator.snapshot?.isComplete == true &&
            !scanCoordinator.isScanning &&
            !isArchiveOperationInProgress
    }

    private func startArchiveExport(snapshot: ScanSnapshot, destinationURL: URL) {
        cancelArchiveOperation()
        let progressReporter = ScanArchiveProgressReporter()
        let operationID = beginArchiveOperation(
            kind: .export,
            title: "Exporting Snapshot",
            message: "Preparing archive",
            progressReporter: progressReporter
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                progressReporter.finish()
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let exportOptions = ScanArchiveExportOptions(
                    appVersion: Self.currentAppVersion(),
                    progressReporter: progressReporter
                )
                let exportTask = Task.detached(priority: .utility) {
                    try await archiveService.export(
                        snapshot: snapshot,
                        to: destinationURL,
                        options: exportOptions
                    )
                }
                let result = try await Self.value(cancelling: exportTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                self.lastErrorMessage = nil
                self.presentExportConfirmation(for: result.archiveURL)
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error, title: "Export Failed")
            }
        }
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
        guard canImportScanSnapshot else {
            presentErrorMessage(importUnavailableMessage)
            return
        }

        previewImportScanSnapshot(from: sourceURL)
    }

    private var importUnavailableMessage: String {
        if scanCoordinator.isScanning {
            return "Stop the current scan before importing a snapshot."
        }
        if isExportPanelPresented {
            return "Finish choosing an export location before importing a snapshot."
        }
        if isArchiveOperationInProgress {
            return "Cancel the current archive operation before importing a snapshot."
        }
        if pendingImportPreview != nil {
            return "Finish or cancel the current import preview before importing another snapshot."
        }
        return "Radix cannot import a snapshot right now."
    }

    func confirmImportPreview() {
        guard canConfirmImportPreview,
              let preview = pendingImportPreview else {
            return
        }

        pendingImportPreview = nil
        importApprovedScanSnapshot(from: preview.archiveURL)
    }

    func cancelImportPreview() {
        cancelArchiveOperation()
        pendingImportPreview = nil
    }

    func cancelArchiveOperation() {
        snapshotArchiveTask?.cancel()
        snapshotArchiveTask = nil
        snapshotArchiveProgressTask?.cancel()
        snapshotArchiveProgressTask = nil
        archiveOperation = nil
    }

    private func previewImportScanSnapshot(from sourceURL: URL) {
        pendingImportPreview = nil
        cancelArchiveOperation()
        let operationID = beginArchiveOperation(
            kind: .importPreview,
            title: "Reading Snapshot",
            message: "Reading manifest",
            progressReporter: nil
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let previewTask = Task.detached(priority: .utility) {
                    try await archiveService.previewSnapshot(from: sourceURL)
                }
                let preview = try await Self.value(cancelling: previewTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                self.pendingImportPreview = preview
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error)
            }
        }
    }

    private func importApprovedScanSnapshot(from sourceURL: URL) {
        cancelArchiveOperation()
        let progressReporter = ScanArchiveProgressReporter()
        let operationID = beginArchiveOperation(
            kind: .import,
            title: "Importing Snapshot",
            message: "Reading archive",
            progressReporter: progressReporter
        )
        snapshotArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                progressReporter.finish()
                self.finishArchiveOperation(id: operationID)
            }

            do {
                let archiveService = self.dependencies.scanArchiveService
                let importTask = Task.detached(priority: .utility) {
                    try await archiveService.importSnapshot(
                        from: sourceURL,
                        progressReporter: progressReporter
                    )
                }
                let result = try await Self.value(cancelling: importTask)
                guard !Task.isCancelled,
                      self.isCurrentArchiveOperation(id: operationID) else { return }
                progressReporter.report(ScanArchiveProgress(
                    phase: .openingSnapshot,
                    message: "Opening snapshot"
                ))
                self.updateArchiveOperation(id: operationID, message: "Opening snapshot", progressFraction: nil)
                try await Task.sleep(for: .milliseconds(1))
                self.restoreImportedSnapshot(result.snapshot)
                self.lastErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self.presentError(error)
            }
        }
    }

    private func beginArchiveOperation(
        kind: ArchiveOperationKind,
        title: String,
        message: String,
        progressReporter: ScanArchiveProgressReporter?
    ) -> UUID {
        dismissExportConfirmation()
        let operationID = UUID()
        archiveOperation = ArchiveOperationState(
            id: operationID,
            kind: kind,
            title: title,
            message: message,
            progressFraction: nil
        )

        if let progressReporter {
            snapshotArchiveProgressTask = Task { @MainActor [weak self] in
                for await progress in progressReporter.updates {
                    guard let self else { return }
                    updateArchiveOperation(
                        id: operationID,
                        message: progress.message,
                        progressFraction: progress.fractionCompleted
                    )
                }
            }
        }

        return operationID
    }

    private func updateArchiveOperation(
        id operationID: UUID,
        message: String,
        progressFraction: Double?
    ) {
        guard var operation = archiveOperation,
              operation.id == operationID else {
            return
        }
        operation.message = message
        operation.progressFraction = progressFraction
        archiveOperation = operation
    }

    private func finishArchiveOperation(id operationID: UUID) {
        guard archiveOperation?.id == operationID || archiveOperation == nil else {
            return
        }
        snapshotArchiveTask = nil
        if archiveOperation?.id == operationID {
            archiveOperation = nil
        }
        snapshotArchiveProgressTask?.cancel()
        snapshotArchiveProgressTask = nil
    }

    private func isCurrentArchiveOperation(id operationID: UUID) -> Bool {
        archiveOperation?.id == operationID
    }

    nonisolated private static func value<T: Sendable>(cancelling task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func startScan(_ target: ScanTarget) {
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

    private func cancelDeferredDiscardPileAdd() {
        deferredDiscardPileAddID = nil
        deferredDiscardPileAddTask?.cancel()
        deferredDiscardPileAddTask = nil
    }

    private func cancelDeferredNavigationContextUpdate() {
        deferredNavigationContextSnapshotID = nil
        deferredNavigationContextID = nil
        deferredNavigationContextTask?.cancel()
        deferredNavigationContextTask = nil
    }

    private func scheduleDeferredNavigationContextUpdate(for snapshotID: UUID) {
        scheduleDeferredViewUpdate(
            id: \.deferredNavigationContextID,
            task: \.deferredNavigationContextTask
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
        postTrashRemovalRequests.removeAll()
        postTrashRemovalTask?.cancel()
        postTrashRemovalTask = nil
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
        cancelArchiveOperation()
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

    func sunburstFreeSpaceAvailableCapacity(for snapshot: ScanSnapshot, focusNode: FileNodeRecord) -> Int64? {
        guard showFreeSpaceInSunburst,
              snapshot.target.kind == .volume,
              focusNode.id == snapshot.root.id else {
            return nil
        }

        return dependencies.systemActions.volumeAvailableCapacityForImportantUsage(snapshot.target.url)
    }

    func stopScan(resetState: Bool = true) {
        cancelDeferredScanStart()
        cancelDeferredSidebarSelection()
        cancelDeferredNavigationAction()
        cancelDeferredDiscardPileAdd()
        cancelDeferredNavigationContextUpdate()
        cancelPostTrashSnapshotRemoval()
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
        requestMoveNodesToTrash(navigationModel.selectedNodes)
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

            pendingTrashNode = node
            pendingTrashSelection = PendingTrashSelection(nodes: [node])
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func requestMoveNodesToTrash(_ nodes: [FileNodeRecord]) -> Bool {
        do {
            let nodes = try validatedNodesForMutation(nodes)
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
            return true
        } catch {
            presentError(error)
            return false
        }
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
    func addNodeToDiscardPile(_ node: FileNodeRecord) -> Bool {
        addNodesToDiscardPile([node])
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
            guard let snapshot = scanCoordinator.snapshot,
                  let fileTreeStore = scanCoordinator.fileTreeStore else {
                throw FileActionError.unsupported
            }

            addDiscardPileNodes(
                topLevelTrashNodes(from: nodes),
                snapshot: snapshot,
                fileTreeStore: fileTreeStore
            )
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func scheduleDeferredDiscardPileAdd(_ nodes: [FileNodeRecord]) {
        cancelDeferredDiscardPileAdd()

        scheduleDeferredViewUpdate(
            id: \.deferredDiscardPileAddID,
            task: \.deferredDiscardPileAddTask
        ) { model in
            model.addNodesToDiscardPile(nodes)
        }
    }

    func removeDiscardPileNode(id nodeID: FileNodeRecord.ID) {
        guard discardPile.nodeIDs.contains(nodeID) else { return }
        let remainingIDs = discardPile.nodeIDs.filter { $0 != nodeID }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    func clearDiscardPile() {
        guard !discardPile.isEmpty else { return }
        discardPile = DiscardPileState()
    }

    @discardableResult
    func requestMoveDiscardPileToTrash() -> Bool {
        reconcileDiscardPile()
        return requestMoveNodesToTrash(topLevelTrashNodes(from: resolvedDiscardPileNodes()))
    }

    func confirmMovePendingNodeToTrash() {
        confirmMovePendingSelectionToTrash()
    }

    func confirmMovePendingSelectionToTrash() {
        let nodes = pendingTrashSelection?.nodes ?? pendingTrashNode.map { [$0] }
        guard let nodes, !nodes.isEmpty else { return }
        pendingTrashNode = nil
        self.pendingTrashSelection = nil

        let originalSnapshotID = scanCoordinator.snapshot?.id
        let statsFileTreeStore = scanCoordinator.fileTreeStore

        if usesAsyncTrashActions {
            Task { @MainActor [weak self] in
                await self?.performConfirmedTrashMove(
                    nodes,
                    originalSnapshotID: originalSnapshotID,
                    statsFileTreeStore: statsFileTreeStore
                )
            }
        } else {
            performConfirmedTrashMoveSynchronously(
                nodes,
                originalSnapshotID: originalSnapshotID,
                statsFileTreeStore: statsFileTreeStore
            )
        }
    }

    private var usesAsyncTrashActions: Bool {
        dependencies.systemActions.asyncMoveToTrash != nil ||
            dependencies.systemActions.asyncVerifyTrashIdentity != nil
    }

    private func performConfirmedTrashMoveSynchronously(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
    ) {
        var movedNodes: [FileNodeRecord] = []

        if let actionError = trashIdentityError(for: nodes) {
            presentError(actionError)
            return
        }

        var actionError: Error?
        for node in nodes {
            do {
                try dependencies.systemActions.moveToTrash(node.url)
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        finishConfirmedTrashMove(
            movedNodes,
            actionError: actionError,
            originalSnapshotID: originalSnapshotID,
            statsFileTreeStore: statsFileTreeStore
        )
    }

    private func performConfirmedTrashMove(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
    ) async {
        var movedNodes: [FileNodeRecord] = []

        if let actionError = await asyncTrashIdentityError(for: nodes) {
            presentError(actionError)
            return
        }

        var actionError: Error?
        for node in nodes {
            do {
                try await moveToTrash(node.url)
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        finishConfirmedTrashMove(
            movedNodes,
            actionError: actionError,
            originalSnapshotID: originalSnapshotID,
            statsFileTreeStore: statsFileTreeStore
        )
    }

    private func trashIdentityError(for nodes: [FileNodeRecord]) -> Error? {
        for node in nodes {
            if let error = fileActionError(
                for: dependencies.systemActions.verifyTrashIdentity(node),
                node: node
            ) {
                return error
            }
        }
        return nil
    }

    private func asyncTrashIdentityError(for nodes: [FileNodeRecord]) async -> Error? {
        for node in nodes {
            let result: TrashIdentityVerificationResult
            if let asyncVerifyTrashIdentity = dependencies.systemActions.asyncVerifyTrashIdentity {
                result = await asyncVerifyTrashIdentity(node)
            } else {
                result = dependencies.systemActions.verifyTrashIdentity(node)
            }

            if let error = fileActionError(for: result, node: node) {
                return error
            }
        }
        return nil
    }

    private func fileActionError(
        for result: TrashIdentityVerificationResult,
        node: FileNodeRecord
    ) -> Error? {
        switch result {
        case .matches:
            return nil
        case .missingCurrentItem:
            return FileActionError.unavailable(path: node.url.path)
        case .missingScannedIdentity:
            return FileActionError.missingScannedIdentity(path: node.url.path)
        case .mismatch:
            return FileActionError.changedSinceScan(path: node.url.path)
        case .metadataUnavailable(let reason):
            return FileActionError.currentIdentityUnavailable(path: node.url.path, reason: reason)
        }
    }

    private func moveToTrash(_ url: URL) async throws {
        if let asyncMoveToTrash = dependencies.systemActions.asyncMoveToTrash {
            try await asyncMoveToTrash(url)
        } else {
            try dependencies.systemActions.moveToTrash(url)
        }
    }

    private func finishConfirmedTrashMove(
        _ movedNodes: [FileNodeRecord],
        actionError: Error?,
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?
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
            presentError(actionError)
        }
    }

    private func shouldApplyPostTrashSnapshotUpdate(originalSnapshotID: UUID?) -> Bool {
        guard let originalSnapshotID else { return true }
        return scanCoordinator.snapshot?.id == originalSnapshotID
    }

    private func handleMovedToTrash(_ nodes: [FileNodeRecord]) {
        var shouldClearActiveScan = false

        for node in nodes {
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: scanCoordinator.selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                shouldClearActiveScan = true
            case .removeFromActiveScan:
                enqueuePostTrashSnapshotRemoval(
                    nodeID: node.id,
                    fallbackFocusID: postTrashFocusFallbackID(for: node)
                )
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
        }
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
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
        try validatedNodes(navigationModel.selectedNodes, requiresLivePath: requiresLivePath)
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
        return try validatedNodes(navigationModel.selectedNodes, requiresLivePath: false)
    }

    private func validatedNodesForPathCopy(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validatePathCopyAllowed()
        return try validatedNodes(nodes, requiresLivePath: false)
    }

    private func validatedSelectionForMutation() throws -> FileNodeRecord {
        try validateSnapshotAllowsMutation()
        return try validatedSelection(requiresLivePath: true)
    }

    private func validatedNodesForMutation(_ nodes: [FileNodeRecord]) throws -> [FileNodeRecord] {
        try validateSnapshotAllowsMutation()
        return try validatedNodes(nodes, requiresLivePath: true)
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

    private func topLevelTrashNodes(from nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return nodes }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return topLevelNodeIDs(
            from: nodes.map(\.id),
            fileTreeStore: fileTreeStore
        ).compactMap { nodesByID[$0] }
    }

    private func topLevelNodeIDs(
        from nodeIDs: [FileNodeRecord.ID],
        fileTreeStore: FileTreeStore
    ) -> [FileNodeRecord.ID] {
        let candidateIDs = Set(nodeIDs)
        var emittedIDs = Set<FileNodeRecord.ID>()
        var result: [FileNodeRecord.ID] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateIDs, of: nodeID, fileTreeStore: fileTreeStore) else {
                continue
            }
            emittedIDs.insert(nodeID)
            result.append(nodeID)
        }

        return result
    }

    private func hasAncestor(
        in ancestorIDs: Set<FileNodeRecord.ID>,
        of nodeID: FileNodeRecord.ID,
        fileTreeStore: FileTreeStore
    ) -> Bool {
        var parentID = fileTreeStore.parent(of: nodeID)?.id
        while let currentParentID = parentID {
            if ancestorIDs.contains(currentParentID) {
                return true
            }
            parentID = fileTreeStore.parent(of: currentParentID)?.id
        }
        return false
    }

    private func isNodeOrDescendant(
        _ nodeID: FileNodeRecord.ID,
        of ancestorIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore
    ) -> Bool {
        ancestorIDs.contains(nodeID) ||
            hasAncestor(in: ancestorIDs, of: nodeID, fileTreeStore: fileTreeStore)
    }

    private func addDiscardPileNodes(
        _ nodes: [FileNodeRecord],
        snapshot: ScanSnapshot,
        fileTreeStore: FileTreeStore
    ) {
        guard !nodes.isEmpty else { return }

        let queuedIDs = (discardPile.snapshotID == snapshot.id ? discardPile.nodeIDs : []) + nodes.map(\.id)
        let deduplicatedIDs = deduplicatedDiscardPileIDs(queuedIDs, fileTreeStore: fileTreeStore)
        discardPile = DiscardPileState(nodeIDs: deduplicatedIDs, snapshotID: snapshot.id)
        reconcileNavigationForDiscardPileHiddenNodes(
            hiddenNodeIDs: Set(deduplicatedIDs),
            fileTreeStore: fileTreeStore
        )
    }

    private func deduplicatedDiscardPileIDs(
        _ nodeIDs: [FileNodeRecord.ID],
        fileTreeStore: FileTreeStore
    ) -> [FileNodeRecord.ID] {
        topLevelNodeIDs(
            from: nodeIDs.filter { fileTreeStore.node(id: $0) != nil },
            fileTreeStore: fileTreeStore
        )
    }

    private func resolvedDiscardPileNodes() -> [FileNodeRecord] {
        guard let fileTreeStore = scanCoordinator.fileTreeStore else { return [] }
        return discardPile.nodeIDs.compactMap { fileTreeStore.node(id: $0) }
    }

    private func reconcileNavigationForDiscardPileHiddenNodes(
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore
    ) {
        guard !hiddenNodeIDs.isEmpty else { return }

        if let focusedNodeID = navigationModel.focusedNodeID,
           fileTreeStore.isNodeOrDescendant(focusedNodeID, of: hiddenNodeIDs) {
            navigationModel.setFocusedNodeID(
                discardPileFocusFallbackID(
                    for: focusedNodeID,
                    hiddenNodeIDs: hiddenNodeIDs,
                    fileTreeStore: fileTreeStore
                )
            )
        }

        if navigationModel.selectedNodeIDs.contains(where: { selectedNodeID in
            fileTreeStore.isNodeOrDescendant(selectedNodeID, of: hiddenNodeIDs)
        }) {
            navigationModel.clearSelection()
        }
    }

    private func discardPileFocusFallbackID(
        for nodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore
    ) -> FileNodeRecord.ID? {
        var parentID = fileTreeStore.parent(of: nodeID)?.id
        while let candidateID = parentID {
            if !fileTreeStore.isNodeOrDescendant(candidateID, of: hiddenNodeIDs) {
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
        let remainingIDs = discardPile.nodeIDs.filter { queuedID in
            guard !movedIDs.contains(queuedID) else { return false }
            guard let fileTreeStore else { return true }
            return !isNodeOrDescendant(queuedID, of: movedIDs, fileTreeStore: fileTreeStore)
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
        navigationModel.reset()
        pendingImportPreview = nil
        pendingTrashNode = nil
        pendingTrashSelection = nil
        discardPile = DiscardPileState()
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
        navigationModel.reset()
        pendingImportPreview = nil
        pendingTrashNode = nil
        pendingTrashSelection = nil
        discardPile = DiscardPileState()
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
        scanCoordinator.onScanFinished = { [weak self] snapshot in
            self?.recordCompletedScan(snapshot)
        }

        scanCoordinator.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
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
            .combineLatest(Publishers.CombineLatest4(
                $autoSummarizeDirectories,
                $showFreeSpaceInSunburst,
                $useScanExclusions,
                $exclusionPatterns
            ))
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
            showFreeSpaceInSunburst: showFreeSpaceInSunburst,
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
        _ scanFilters: (Bool, Bool, Bool, [String])
    ) -> AppScanPreferences {
        AppScanPreferences(
            showHiddenFiles: scanBasics.0,
            treatPackagesAsDirectories: scanBasics.1,
            maxRenderedDepth: scanBasics.2,
            autoSummarizeDirectories: scanFilters.0,
            showFreeSpaceInSunburst: scanFilters.1,
            scanCloudStorageFolders: scanBasics.3,
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
            pendingTrashNode != nil ||
            pendingTrashSelection != nil ||
            navigationModel.selectedNodeIDs.count > 1
    }

    func validatedSelectionForQuickLook() throws -> FileNodeRecord {
        try validatedSelection(requiresLivePath: true)
    }

    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error) {
        presentError(error)
    }
}
