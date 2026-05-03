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
    private enum DefaultsKey {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let showHiddenFiles = "showHiddenFiles"
        static let treatPackagesAsDirectories = "treatPackagesAsDirectories"
        static let maxRenderedDepth = "maxRenderedDepth"
        static let autoSummarizeDirectories = "autoSummarizeDirectories"
    }

    private enum FileActionError: LocalizedError {
        case noSelection
        case unavailable(path: String)
        case unsupported
        case directoryRequired
        case folderRequiredForDrop

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
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case displaying
        case failed
    }

    @Published var showHiddenFiles = true
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var autoSummarizeDirectories = true
    @Published var phase: Phase = .idle
    @Published var snapshot: ScanSnapshot?
    @Published var scanMetrics = ScanMetrics()
    @Published var selectedTarget: ScanTarget?
    @Published var selectedNodeID: String?
    @Published var focusedNodeID: String?
    @Published var fileTreeIndex = FileTreeIndex.empty
    @Published private(set) var availableTargets: [ScanTarget] = []
    @Published var recentTargets: [ScanTarget] = []
    @Published var showsOnboarding: Bool
    @Published var lastErrorMessage: String?
    @Published var pendingTrashNode: FileNode?

    private let scanEngine = ScanEngine()

    private var scanTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var focusBackStack: [String] = []
    private var focusForwardStack: [String] = []

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.showHiddenFiles) == nil {
            showHiddenFiles = true
        } else {
            showHiddenFiles = defaults.bool(forKey: DefaultsKey.showHiddenFiles)
        }
        treatPackagesAsDirectories = defaults.bool(forKey: DefaultsKey.treatPackagesAsDirectories)

        let storedDepth = defaults.integer(forKey: DefaultsKey.maxRenderedDepth)
        maxRenderedDepth = (3...10).contains(storedDepth) ? storedDepth : 6

        if defaults.object(forKey: DefaultsKey.autoSummarizeDirectories) == nil {
            autoSummarizeDirectories = true
        } else {
            autoSummarizeDirectories = defaults.bool(forKey: DefaultsKey.autoSummarizeDirectories)
        }

        showsOnboarding = !defaults.bool(forKey: DefaultsKey.didCompleteOnboarding)

        refreshAvailableTargets()
        observeMountedVolumes()
        observePreferences()
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var currentFocusNode: FileNode? {
        fileTreeIndex.node(id: focusedNodeID) ?? snapshot?.root
    }

    var selectedNode: FileNode? {
        fileTreeIndex.node(id: selectedNodeID)
    }

    var selectedNodeParent: FileNode? {
        fileTreeIndex.parent(of: selectedNode?.id)
    }

    var breadcrumbNodes: [FileNode] {
        guard snapshot != nil else { return [] }
        return fileTreeIndex.path(to: focusedNodeID)
    }

    var tableNodes: [FileNode] {
        guard let focusNode = currentFocusNode else { return [] }
        if focusNode.isDirectory {
            return focusNode.children
        }
        return fileTreeIndex.parent(of: focusNode.id)?.children ?? []
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

    var largestSelectedChildren: [FileNode] {
        guard let selectedNode, selectedNode.isDirectory else { return [] }
        return Array(selectedNode.children.prefix(8))
    }

    var canZoomIntoSelection: Bool {
        guard let selectedNode else { return false }
        return selectedNode.isDirectory && selectedNode.containsChildren
    }

    var canNavigateBack: Bool {
        !focusBackStack.isEmpty
    }

    var canNavigateForward: Bool {
        !focusForwardStack.isEmpty
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
        selectedNodeID != nil
    }

    var canOpenSelected: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canRevealSelected: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canCopySelectedPath: Bool {
        selectedNode?.supportsFileActions == true
    }

    var canMoveSelectedToTrash: Bool {
        selectedNode?.supportsMoveToTrash == true
    }

    var isFocusedAtRoot: Bool {
        guard let rootID = snapshot?.root.id else { return true }
        return (focusedNodeID ?? rootID) == rootID
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
        return recentTargets.filter { !excluded.contains($0.id) }
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

    var selectedNodePercentOfParentText: String? {
        guard let selectedNode,
              let parent = selectedNodeParent else { return nil }
        return percentageText(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    var selectedNodePercentOfScanText: String? {
        guard let selectedNode,
              let root = snapshot?.root else { return nil }
        return percentageText(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }

    func dismissOnboarding() {
        showsOnboarding = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.didCompleteOnboarding)
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

    /// Expands an auto-summarized directory by scanning it fully and replacing the node in the tree.
    func expandSummarizedNode(_ node: FileNode, completion: @escaping () -> Void) {
        guard node.isAutoSummarized else {
            completion()
            return
        }

        // Cancel any in-progress expansion
        expandTask?.cancel()

        let target = ScanTarget(url: node.url)
        let options = ScanOptions(
            includeHiddenFiles: showHiddenFiles || target.kind == .volume,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            maxRenderedDepth: maxRenderedDepth,
            autoSummarizeDirectories: false  // Force full expansion
        )

        expandTask = Task(priority: .userInitiated) {
            do {
                var expandedSnapshot: ScanSnapshot?
                for try await event in scanEngine.scan(target: target, options: options) {
                    if case .finished(let snapshot) = event {
                        expandedSnapshot = snapshot
                    }
                }

                try Task.checkCancellation()

                guard let expandedSnapshot else {
                    await MainActor.run { completion() }
                    return
                }

                await MainActor.run {
                    self.replaceNodeInTree(node, with: expandedSnapshot)
                    completion()
                }
            } catch {
                await MainActor.run {
                    if !(error is CancellationError) {
                        self.lastErrorMessage = "Failed to expand '\(node.name)': \(error.localizedDescription)"
                    }
                    completion()
                }
            }
        }
    }

    /// Replaces a node in the current snapshot tree with an expanded version.
    private func replaceNodeInTree(_ oldNode: FileNode, with expandedSnapshot: ScanSnapshot) {
        guard let currentSnapshot = snapshot else { return }
        guard let updatedSnapshot = currentSnapshot.replacingNode(
            id: oldNode.id,
            with: expandedSnapshot.root,
            additionalWarnings: expandedSnapshot.scanWarnings
        ) else { return }

        self.snapshot = updatedSnapshot
        fileTreeIndex = FileTreeIndex(root: updatedSnapshot.root)
        selectedNodeID = expandedSnapshot.root.id
    }

    func presentOpenPanelAndScan() {
        guard canChooseFolder else { return }
        if let target = SystemIntegration.presentScanPanel() {
            startScan(target)
        }
    }

    func startScan(_ target: ScanTarget) {
        // Defer state mutations to the next runloop to avoid
        // "Publishing changes from within view updates is not allowed."
        Task { @MainActor in
            stopScan(resetState: false)

            selectedTarget = target
            phase = .scanning
            lastErrorMessage = nil
            scanMetrics = ScanMetrics(startedAt: Date())
            selectedNodeID = nil
            focusedNodeID = nil
            pendingTrashNode = nil
            fileTreeIndex = .empty
            focusBackStack.removeAll()
            focusForwardStack.removeAll()

            registerRecentTarget(target)
            refreshAvailableTargets()

            let scanID = UUID()
            activeScanID = scanID

            let options = ScanOptions(
                includeHiddenFiles: showHiddenFiles || target.kind == .volume,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                maxRenderedDepth: maxRenderedDepth,
                autoSummarizeDirectories: autoSummarizeDirectories
            )

            snapshot = nil
            let stream = scanEngine.scan(target: target, options: options)
            scanTask = Task {
                do {
                    for try await event in stream {
                        guard activeScanID == scanID else {
                            break
                        }
                        handle(event, scanID: scanID)
                    }
                } catch is CancellationError {
                    if activeScanID == scanID && snapshot == nil {
                        phase = .idle
                    }
                } catch {
                    if activeScanID == scanID {
                        phase = .failed
                        lastErrorMessage = error.localizedDescription
                    }
                }

                if activeScanID == scanID && phase != .displaying && phase != .failed {
                    scanTask = nil
                }
            }
        }
    }

    func rescan() {
        guard let selectedTarget else { return }
        startScan(selectedTarget)
    }

    func stopScan(resetState: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        expandTask?.cancel()
        expandTask = nil
        scanMetrics.isFinalizing = false

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
    }

    func select(nodeID: String?) {
        guard let nodeID else {
            selectedNodeID = nil
            return
        }

        guard fileTreeIndex.node(id: nodeID) != nil else {
            selectedNodeID = nil
            return
        }

        selectedNodeID = nodeID
    }

    func focus(nodeID: String?) {
        guard let nodeID, fileTreeIndex.node(id: nodeID) != nil else { return }
        setFocus(nodeID, recordHistory: true)
    }

    func clearSelection() {
        selectedNodeID = nil
    }

    func zoomIntoSelection() {
        do {
            let node = try validatedSelection(requiresDirectory: true)
            guard node.containsChildren else {
                throw FileActionError.directoryRequired
            }
            focus(nodeID: node.id)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func navigateBack() {
        guard let previousFocusID = focusBackStack.popLast() else {
            return
        }

        if let currentFocusID = focusedNodeID {
            focusForwardStack.append(currentFocusID)
        }

        applyFocus(previousFocusID)
    }

    func navigateForward() {
        guard let nextFocusID = focusForwardStack.popLast() else {
            return
        }

        if let currentFocusID = focusedNodeID {
            focusBackStack.append(currentFocusID)
        }

        applyFocus(nextFocusID)
    }

    func resetFocusToRoot() {
        guard let rootID = snapshot?.root.id else { return }
        setFocus(rootID, recordHistory: true)
        selectedNodeID = nil
    }

    func selectSidebarTarget(id: String?) {
        guard let id,
              let target = (availableTargets + recentTargets).first(where: { $0.id == id }) else {
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
            SystemIntegration.reveal(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func openSelected() {
        do {
            let node = try validatedSelection()
            try SystemIntegration.open(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func copySelectedPath() {
        do {
            let node = try validatedSelection()
            try SystemIntegration.copyPath(node.url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func requestMoveSelectedToTrash() {
        do {
            let node = try validatedSelection()
            guard node.supportsMoveToTrash else {
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
            guard FileManager.default.fileExists(atPath: node.url.path) else {
                throw FileActionError.unavailable(path: node.url.path)
            }
            try SystemIntegration.moveToTrash(node.url)
            switch ScanPostTrashAction.afterRemovingNode(activeTargetID: selectedTarget?.id, removedNodeID: node.id) {
            case .clearActiveScan:
                selectedTarget = nil
                snapshot = nil
                phase = .idle
                selectedNodeID = nil
                focusedNodeID = nil
                fileTreeIndex = .empty
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
        guard SystemIntegration.prepareAndOpenFullDiskAccessSettings() else {
            lastErrorMessage = SystemIntegration.SystemIntegrationError
                .fullDiskAccessSettingsUnavailable
                .localizedDescription
            return
        }
    }

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .progress(let metrics):
            scanMetrics = metrics
        case .warning:
            break
        case .finished(let snapshot):
            apply(snapshot: snapshot)
            scanMetrics.recalculateProgress(isComplete: true)
            activeScanID = nil
            phase = .displaying
            scanTask = nil
        }
    }

    private func apply(snapshot: ScanSnapshot) {
        self.snapshot = snapshot
        fileTreeIndex = FileTreeIndex(root: snapshot.root)
        focusBackStack.removeAll()
        focusForwardStack.removeAll()

        if focusedNodeID == nil || fileTreeIndex.node(id: focusedNodeID) == nil {
            focusedNodeID = snapshot.root.id
        }

        if let selectedNodeID,
           fileTreeIndex.node(id: selectedNodeID) == nil {
            self.selectedNodeID = nil
        }
    }

    private func validatedSelection(requiresDirectory: Bool = false) throws -> FileNode {
        guard let selectedNode else {
            throw FileActionError.noSelection
        }
        guard selectedNode.supportsFileActions else {
            throw FileActionError.unsupported
        }
        if requiresDirectory, !selectedNode.isDirectory {
            throw FileActionError.directoryRequired
        }
        guard FileManager.default.fileExists(atPath: selectedNode.url.path) else {
            clearSelection()
            throw FileActionError.unavailable(path: selectedNode.url.path)
        }
        return selectedNode
    }

    private func setFocus(_ nodeID: String, recordHistory: Bool) {
        guard fileTreeIndex.node(id: nodeID) != nil else { return }
        guard focusedNodeID != nodeID else { return }

        if recordHistory, let currentFocusID = focusedNodeID {
            focusBackStack.append(currentFocusID)
            focusForwardStack.removeAll()
        }

        applyFocus(nodeID)
    }

    private func applyFocus(_ nodeID: String) {
        guard fileTreeIndex.node(id: nodeID) != nil else { return }

        focusedNodeID = nodeID
        if let selectedNodeID,
           selectedNodeID != nodeID,
           !fileTreeIndex.isAncestor(nodeID, of: selectedNodeID) {
            self.selectedNodeID = nil
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || url.hasDirectoryPath
    }

    private func registerRecentTarget(_ target: ScanTarget) {
        recentTargets.removeAll { $0.id == target.id }
        recentTargets.insert(target, at: 0)
        if recentTargets.count > 10 {
            recentTargets = Array(recentTargets.prefix(10))
        }
    }

    private var preferredSmartTargetPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            "/",
            home,
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
            home + "/Library",
            "/Applications"
        ]
    }

    private func percentageText(part: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        return (Double(part) / Double(total))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private func refreshAvailableTargets() {
        availableTargets = SystemIntegration.defaultTargets()
    }

    private func observeMountedVolumes() {
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: workspaceNotifications.publisher(for: NSWorkspace.didUnmountNotification))
            .merge(with: workspaceNotifications.publisher(for: NSWorkspace.didRenameVolumeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableTargets()
            }
            .store(in: &cancellables)
    }

    private func observePreferences() {
        $showHiddenFiles
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: DefaultsKey.showHiddenFiles) }
            .store(in: &cancellables)

        $treatPackagesAsDirectories
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: DefaultsKey.treatPackagesAsDirectories) }
            .store(in: &cancellables)

        $maxRenderedDepth
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: DefaultsKey.maxRenderedDepth) }
            .store(in: &cancellables)

        $autoSummarizeDirectories
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: DefaultsKey.autoSummarizeDirectories) }
            .store(in: &cancellables)
    }
}
