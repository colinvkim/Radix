//
//  WorkspaceNavigationModel.swift
//  Radix
//

import Combine
import Foundation

@MainActor
final class WorkspaceNavigationModel: ObservableObject {
    private static let emptyTableContentID = "no-snapshot|no-focus"

    @Published private(set) var selectedNodeID: String? {
        didSet {
            guard oldValue != selectedNodeID else { return }
            refreshSelectedAncestorIDs()
            onSelectionChanged?()
        }
    }

    @Published private(set) var focusedNodeID: String?

    var onSelectionChanged: (() -> Void)?

    @Published private var snapshotID: UUID?
    @Published private var fileTreeStore: FileTreeStore?
    @Published private var focusBackStack: [String] = []
    @Published private var focusForwardStack: [String] = []

    private(set) var tableNodes: [FileNodeRecord] = []
    private(set) var tableContentID = WorkspaceNavigationModel.emptyTableContentID
    private(set) var selectedAncestorIDs: Set<String> = []

    var currentFocusNode: FileNodeRecord? {
        resolvedFocusNode
    }

    var selectedNode: FileNodeRecord? {
        fileTreeStore?.node(id: selectedNodeID)
    }

    var selectedNodeParent: FileNodeRecord? {
        fileTreeStore?.parent(of: selectedNode?.id)
    }

    var breadcrumbNodes: [FileNodeRecord] {
        guard let fileTreeStore else { return [] }
        return fileTreeStore.path(to: focusedNodeID)
    }

    var canZoomIntoSelection: Bool {
        guard let fileTreeStore, let selectedNode else { return false }
        return selectedNode.isDirectory && fileTreeStore.containsChildren(id: selectedNode.id)
    }

    var canNavigateBack: Bool {
        !focusBackStack.isEmpty
    }

    var canNavigateForward: Bool {
        !focusForwardStack.isEmpty
    }

    var canClearSelection: Bool {
        selectedNodeID != nil
    }

    var isFocusedAtRoot: Bool {
        guard let rootID = fileTreeStore?.root.id else { return true }
        return (focusedNodeID ?? rootID) == rootID
    }

    func updateScanContext(snapshot: ScanSnapshot?) {
        snapshotID = snapshot?.id
        fileTreeStore = snapshot?.treeStore
        refreshSelectedAncestorIDs()
        refreshTableState()
    }

    func updateFileTreeStore(_ fileTreeStore: FileTreeStore?, snapshotID: UUID?) {
        self.fileTreeStore = fileTreeStore
        self.snapshotID = snapshotID
        refreshSelectedAncestorIDs()
        refreshTableState()
    }

    func reset() {
        selectedNodeID = nil
        focusedNodeID = nil
        snapshotID = nil
        fileTreeStore = nil
        focusBackStack.removeAll()
        focusForwardStack.removeAll()
        selectedAncestorIDs = []
        tableNodes = []
        tableContentID = Self.emptyTableContentID
    }

    func select(nodeID: String?) {
        guard let nodeID else {
            selectedNodeID = nil
            return
        }

        guard fileTreeStore?.node(id: nodeID) != nil else {
            selectedNodeID = nil
            return
        }

        selectedNodeID = nodeID
    }

    func setFocusedNodeID(_ nodeID: String?) {
        guard let nodeID else {
            focusedNodeID = nil
            refreshTableState()
            return
        }

        applyFocus(nodeID)
    }

    func focus(nodeID: String?) {
        guard let nodeID, fileTreeStore?.node(id: nodeID) != nil else { return }
        setFocus(nodeID, recordHistory: true)
    }

    func clearSelection() {
        selectedNodeID = nil
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
        guard let rootID = fileTreeStore?.root.id else { return }
        setFocus(rootID, recordHistory: true)
        selectedNodeID = nil
    }

    func reconcileAfterSnapshotApplied(_ snapshot: ScanSnapshot?) {
        focusBackStack.removeAll()
        focusForwardStack.removeAll()
        updateScanContext(snapshot: snapshot)

        guard let snapshot else {
            selectedNodeID = nil
            focusedNodeID = nil
            return
        }

        if focusedNodeID == nil || fileTreeStore?.node(id: focusedNodeID) == nil {
            focusedNodeID = snapshot.root.id
        }

        if let selectedNodeID,
           fileTreeStore?.node(id: selectedNodeID) == nil {
            self.selectedNodeID = nil
        }
    }

    private func setFocus(_ nodeID: String, recordHistory: Bool) {
        guard fileTreeStore?.node(id: nodeID) != nil else { return }
        guard focusedNodeID != nodeID else { return }

        if recordHistory, let currentFocusID = focusedNodeID {
            focusBackStack.append(currentFocusID)
            focusForwardStack.removeAll()
        }

        applyFocus(nodeID)
    }

    private func applyFocus(_ nodeID: String) {
        guard fileTreeStore?.node(id: nodeID) != nil else { return }

        focusedNodeID = nodeID
        if let selectedNodeID,
           selectedNodeID != nodeID,
           fileTreeStore?.isAncestor(nodeID, of: selectedNodeID) != true {
            self.selectedNodeID = nil
        }
        refreshTableState()
    }

    private var resolvedFocusNode: FileNodeRecord? {
        fileTreeStore?.node(id: focusedNodeID) ?? fileTreeStore?.root
    }

    private func refreshSelectedAncestorIDs() {
        guard let fileTreeStore, let selectedNodeID else {
            selectedAncestorIDs = []
            return
        }

        selectedAncestorIDs = Set(fileTreeStore.path(to: selectedNodeID).map(\.id))
    }

    private func refreshTableState() {
        tableContentID = [
            snapshotID?.uuidString ?? "no-snapshot",
            resolvedFocusNode?.id ?? "no-focus"
        ].joined(separator: "|")

        guard let fileTreeStore, let focusNode = resolvedFocusNode else {
            tableNodes = []
            return
        }

        if focusNode.isDirectory {
            tableNodes = fileTreeStore.children(of: focusNode.id)
            return
        }

        guard let parent = fileTreeStore.parent(of: focusNode.id) else {
            tableNodes = []
            return
        }

        tableNodes = fileTreeStore.children(of: parent.id)
    }
}
