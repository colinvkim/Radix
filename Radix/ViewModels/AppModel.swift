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
    private enum FileActionError: LocalizedError {
        case noSelection
        case unavailable(path: String)
        case unsupported
        case directoryRequired
        case folderRequiredForDrop
        case fullDiskAccessSettingsUnavailable

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
            case .folderRequiredForDrop:
                return "Drop a folder or mounted volume to start a scan."
            case .fullDiskAccessSettingsUnavailable:
                return "Radix could not open Full Disk Access settings."
            }
        }
    }

    typealias Phase = AppModelPhase

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published private(set) var availableTargets: [ScanTarget] = []
    @Published var recentTargets: [ScanTarget] = []
    @Published var showsOnboarding: Bool
    @Published var lastErrorMessage: String?
    @Published var pendingTrashNode: FileNodeRecord?

    private let dependencies: AppDependencies
    private let scanCoordinator: ScanCoordinator
    private let navigationModel = WorkspaceNavigationModel()

    private var cancellables = Set<AnyCancellable>()
    private var quickLookEventMonitor: Any?

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
        self.scanCoordinator = ScanCoordinator(scanService: dependencies.scanService)

        let preferences = dependencies.preferences.loadPreferences()
        showHiddenFiles = preferences.scan.showHiddenFiles
        treatPackagesAsDirectories = preferences.scan.treatPackagesAsDirectories
        maxRenderedDepth = preferences.scan.maxRenderedDepth
        autoSummarizeDirectories = preferences.scan.autoSummarizeDirectories
        showsOnboarding = !preferences.didCompleteOnboarding
        recentTargets = dependencies.recentTargets.loadAvailableTargets()

        refreshAvailableTargets()
        observeNavigationModel()
        observeScanCoordinator()
        observeMountedVolumes()
        observePreferences()
        installQuickLookKeyMonitor()
    }

    var phase: Phase {
        get { scanCoordinator.phase }
        set { scanCoordinator.phase = newValue }
    }

    var snapshot: ScanSnapshot? {
        get { scanCoordinator.snapshot }
        set {
            scanCoordinator.replaceCurrentSnapshot(newValue)
            navigationModel.reconcileAfterSnapshotApplied(newValue)
        }
    }

    var scanMetrics: ScanMetrics {
        get { scanCoordinator.scanMetrics }
        set { scanCoordinator.scanMetrics = newValue }
    }

    var selectedTarget: ScanTarget? {
        get { scanCoordinator.selectedTarget }
        set { scanCoordinator.selectedTarget = newValue }
    }

    var fileTreeStore: FileTreeStore? {
        get { scanCoordinator.fileTreeStore }
        set {
            scanCoordinator.fileTreeStore = newValue
            navigationModel.updateFileTreeStore(newValue, snapshotID: snapshot?.id)
        }
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var selectedNodeID: String? {
        get { navigationModel.selectedNodeID }
        set { navigationModel.select(nodeID: newValue) }
    }

    var focusedNodeID: String? {
        get { navigationModel.focusedNodeID }
        set { navigationModel.setFocusedNodeID(newValue) }
    }

    var currentFocusNode: FileNodeRecord? {
        navigationModel.currentFocusNode
    }

    var selectedNode: FileNodeRecord? {
        navigationModel.selectedNode
    }

    var selectedNodeParent: FileNodeRecord? {
        navigationModel.selectedNodeParent
    }

    var breadcrumbNodes: [FileNodeRecord] {
        navigationModel.breadcrumbNodes
    }

    var tableNodes: [FileNodeRecord] {
        navigationModel.tableNodes
    }

    var tableContentID: String {
        navigationModel.tableContentID
    }

    var displayedFileCount: Int {
        if isScanning {
            return scanMetrics.filesVisited
        }
        return snapshot?.aggregateStats.fileCount ?? 0
    }

    var displayedDirectoryCount: Int {
        if isScanning {
            return scanMetrics.directoriesVisited
        }
        return snapshot?.aggregateStats.directoryCount ?? 0
    }

    var displayedAllocatedSize: Int64 {
        if isScanning {
            return scanMetrics.bytesDiscovered
        }
        return snapshot?.aggregateStats.totalAllocatedSize ?? 0
    }

    var warningCount: Int {
        snapshot?.scanWarnings.count ?? 0
    }

    var scanWarningsPreview: [ScanWarning] {
        Array((snapshot?.scanWarnings ?? []).prefix(5))
    }

    var largestSelectedChildren: [FileNodeRecord] {
        guard let fileTreeStore, let selectedNode, selectedNode.isDirectory else { return [] }
        return Array(fileTreeStore.children(of: selectedNode.id).prefix(8))
    }

    var canZoomIntoSelection: Bool {
        navigationModel.canZoomIntoSelection
    }

    var canNavigateBack: Bool {
        navigationModel.canNavigateBack
    }

    var canNavigateForward: Bool {
        navigationModel.canNavigateForward
    }

    var canChooseFolder: Bool {
        !isScanning
    }

    var canRescan: Bool {
        selectedTarget != nil && !isScanning
    }

    var canStopScan: Bool {
        isScanning
    }

    var canClearSelection: Bool {
        navigationModel.canClearSelection
    }

    var canOpenSelected: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canQuickLookSelected: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canRevealSelected: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canCopySelectedPath: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canMoveSelectedToTrash: Bool {
        selectedNode?.supportsMoveToTrash(activeTarget: selectedTarget) == true
    }

    var isFocusedAtRoot: Bool {
        navigationModel.isFocusedAtRoot
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

    var statusSubtitle: String {
        if let selectedTarget {
            return selectedTarget.url.path
        }
        return "Choose a folder or disk to begin"
    }

    var shouldSuggestFullDiskAccess: Bool {
        guard snapshot?.isComplete == true else { return false }
        return PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot)
    }

    var isFinalizingScan: Bool {
        isScanning && scanMetrics.isFinalizing
    }

    var scanProgressFraction: Double {
        if isScanning {
            return scanMetrics.progressFraction
        }
        if snapshot != nil {
            return 1
        }
        return 0
    }

    var scanProgressLabel: String {
        if isFinalizingScan {
            return "Finishing \(scanMetrics.progressPercentage.formatted(.number))%"
        }
        if isScanning {
            return scanMetrics.progressPercentage.formatted(.number) + "%"
        }
        if snapshot != nil {
            return "100%"
        }
        return "\(scanMetrics.progressPercentage)%"
    }

    var errorAlertTitle: String {
        phase == .failed ? "Scan Failed" : "Action Failed"
    }

    var canRescanFromErrorAlert: Bool {
        phase == .failed && canRescan
    }

    var selectedNodePercentOfParentText: String? {
        guard let selectedNode,
              let parent = selectedNodeParent else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    var selectedNodePercentOfScanText: String? {
        guard let selectedNode,
              let root = snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }

    func dismissOnboarding() {
        showsOnboarding = false
        dependencies.preferences.markOnboardingComplete()
    }

    func presentOnboarding() {
        showsOnboarding = true
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
                lastErrorMessage = message
            }

            completion()
        }
    }

    func presentOpenPanelAndScan() {
        guard canChooseFolder else { return }
        if let target = dependencies.systemActions.presentOpenPanel() {
            startScan(target)
        }
    }

    func startScan(_ target: ScanTarget) {
        // Defer state mutations to the next runloop to avoid
        // "Publishing changes from within view updates is not allowed."
        Task { @MainActor in
            let options = scanOptions(for: target)
            scanCoordinator.startScan(target, options: options) {
                prepareForScan(target)
            }
        }
    }

    func rescan() {
        guard let selectedTarget else { return }
        startScan(selectedTarget)
    }

    func stopScan(resetState: Bool = true) {
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
            guard canZoomIntoSelection else {
                throw FileActionError.directoryRequired
            }
            focus(nodeID: node.id)
        } catch {
            lastErrorMessage = error.localizedDescription
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
              let target = (availableTargets + recentScanTargets).first(where: { $0.id == id }) else {
            return
        }

        guard selectedTarget?.id != target.id else { return }
        startScan(target)
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        guard isDirectoryURL(first) else {
            lastErrorMessage = FileActionError.folderRequiredForDrop.localizedDescription
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
            lastErrorMessage = error.localizedDescription
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
            lastErrorMessage = error.localizedDescription
        }
    }

    func previewSelectedWithQuickLook() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.quickLook.present(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func toggleQuickLookForSelected() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.quickLook.toggle(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func copySelectedPath() {
        do {
            let node = try validatedSelection()
            try dependencies.systemActions.copyPath(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func requestMoveSelectedToTrash() {
        do {
            let node = try validatedSelection()
            guard node.supportsMoveToTrash(activeTarget: selectedTarget) else {
                throw FileActionError.unsupported
            }
            pendingTrashNode = node
        } catch {
            lastErrorMessage = error.localizedDescription
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
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                scanCoordinator.clearScan()
                navigationModel.reset()
            case .rescanActiveScan:
                rescan()
            case .none:
                break
            }
            refreshAvailableTargets()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
    }

    func prepareAndOpenFullDiskAccessSettings() {
        guard dependencies.systemActions.prepareAndOpenFullDiskAccessSettings() else {
            lastErrorMessage = FileActionError.fullDiskAccessSettingsUnavailable.localizedDescription
            return
        }
    }

    private func validatedSelection(requiresDirectory: Bool = false) throws -> FileNodeRecord {
        guard let selectedNode else {
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

        guard let selectedNode, selectedNode.supportsFileActions else {
            dependencies.systemActions.quickLook.close()
            return
        }

        dependencies.systemActions.quickLook.updateVisiblePreview(selectedNode.url)
    }

    private func installQuickLookKeyMonitor() {
        quickLookEventMonitor = dependencies.systemActions.installQuickLookKeyMonitor { [weak self] event in
            let didHandleEvent = MainActor.assumeIsolated {
                self?.handleQuickLookKeyDown(event) == true
            }
            return didHandleEvent
        }
    }

    private func handleQuickLookKeyDown(_ event: NSEvent) -> Bool {
        guard Self.isPlainSpaceKey(event) else { return false }
        guard !showsOnboarding, pendingTrashNode == nil else { return false }
        guard !dependencies.systemActions.quickLook.isPreviewPanelKeyWindow() else { return false }
        guard !Self.shouldPreserveSpaceKey(for: event.window?.firstResponder) else { return false }
        guard canQuickLookSelected else { return false }

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

        navigationModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func observeScanCoordinator() {
        scanCoordinator.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        scanCoordinator.$snapshot
            .sink { [weak self] snapshot in
                self?.navigationModel.updateScanContext(snapshot: snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$completedScanSnapshot
            .compactMap { $0 }
            .sink { [weak self] snapshot in
                self?.navigationModel.reconcileAfterSnapshotApplied(snapshot)
            }
            .store(in: &cancellables)

        scanCoordinator.$scanErrorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.lastErrorMessage = message
            }
            .store(in: &cancellables)
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
