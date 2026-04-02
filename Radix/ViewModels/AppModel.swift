//
//  AppModel.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case displaying
        case failed
    }

    @Published var showHiddenFiles = false
    @Published var treatPackagesAsDirectories = false
    @Published var maxRenderedDepth = 6
    @Published var phase: Phase = .idle
    @Published var snapshot: ScanSnapshot?
    @Published var scanMetrics = ScanMetrics()
    @Published var selectedTarget: ScanTarget?
    @Published var selectedNodeID: String?
    @Published var focusedNodeID: String?
    @Published var fileTreeIndex = FileTreeIndex.empty
    @Published var recentTargets: [ScanTarget] = SystemIntegration.defaultTargets()
    @Published var showsOnboarding: Bool
    @Published var lastErrorMessage: String?

    private let scanEngine = ScanEngine()

    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    init() {
        showsOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var currentFocusNode: FileNode? {
        fileTreeIndex.node(id: focusedNodeID) ?? snapshot?.root
    }

    var selectedNode: FileNode? {
        fileTreeIndex.node(id: selectedNodeID) ?? currentFocusNode
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

    var statusTitle: String {
        if let selectedTarget {
            return selectedTarget.displayName
        }
        return "Choose a folder or disk to begin"
    }

    var shouldSuggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(for: snapshot)
    }

    var isFinalizingScan: Bool {
        isScanning && scanMetrics.progressFraction >= 0.98
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
            return "Finishing"
        }
        if isScanning {
            return scanMetrics.progressPercentage.formatted(.number) + "%"
        }
        if snapshot != nil {
            return "100%"
        }
        return "\(Int((scanProgressFraction * 100).rounded(.down)))%"
    }

    func dismissOnboarding() {
        showsOnboarding = false
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
    }

    func presentOpenPanelAndScan() {
        if let target = SystemIntegration.presentScanPanel() {
            startScan(target)
        }
    }

    func startScan(_ target: ScanTarget) {
        stopScan(resetState: false)

        selectedTarget = target
        phase = .scanning
        lastErrorMessage = nil
        scanMetrics = ScanMetrics(startedAt: Date())
        selectedNodeID = nil
        focusedNodeID = nil
        fileTreeIndex = .empty

        registerRecentTarget(target)
        let scanID = UUID()
        activeScanID = scanID

        let options = ScanOptions(
            includeHiddenFiles: showHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            maxRenderedDepth: maxRenderedDepth
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

    func rescan() {
        guard let selectedTarget else { return }
        startScan(selectedTarget)
    }

    func stopScan(resetState: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
    }

    func select(nodeID: String?) {
        guard let nodeID else { return }
        selectedNodeID = nodeID
    }

    func focus(nodeID: String?) {
        guard let nodeID, fileTreeIndex.node(id: nodeID) != nil else { return }
        focusedNodeID = nodeID
        selectedNodeID = nodeID
    }

    func zoomIntoSelection() {
        guard let selectedNode,
              selectedNode.isDirectory,
              selectedNode.containsChildren else { return }
        focus(nodeID: selectedNode.id)
    }

    func zoomOut() {
        guard let focusedNodeID,
              let parentID = fileTreeIndex.parentByID[focusedNodeID] else {
            return
        }
        focus(nodeID: parentID)
    }

    func resetFocusToRoot() {
        guard let rootID = snapshot?.root.id else { return }
        focusedNodeID = rootID
        if selectedNodeID == nil {
            selectedNodeID = rootID
        }
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        startScan(ScanTarget(url: first))
        return true
    }

    func revealSelectedInFinder() {
        guard let url = selectedNode?.url else { return }
        SystemIntegration.reveal(url)
    }

    func openSelected() {
        guard let url = selectedNode?.url else { return }
        SystemIntegration.open(url)
    }

    func copySelectedPath() {
        guard let url = selectedNode?.url else { return }
        SystemIntegration.copyPath(url)
    }

    func openFullDiskAccessSettings() {
        _ = SystemIntegration.openFullDiskAccessSettings()
    }

    func prepareAndOpenFullDiskAccessSettings() {
        _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
    }

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .progress(let metrics):
            scanMetrics = metrics
        case .warning:
            break
        case .snapshot(let snapshot):
            apply(snapshot: snapshot)
            phase = .scanning
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

        if focusedNodeID == nil || fileTreeIndex.node(id: focusedNodeID) == nil {
            focusedNodeID = snapshot.root.id
        }

        if selectedNodeID == nil || fileTreeIndex.node(id: selectedNodeID) == nil {
            selectedNodeID = focusedNodeID
        }
    }

    private func registerRecentTarget(_ target: ScanTarget) {
        recentTargets.removeAll { $0.id == target.id }
        recentTargets.insert(target, at: 0)
        if recentTargets.count > 10 {
            recentTargets = Array(recentTargets.prefix(10))
        }
    }
}
