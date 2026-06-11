//
//  WorkspaceNavigationModel.swift
//  Radix
//

import Combine
import Foundation

struct WorkspaceNavigationState: Equatable {
    static let emptyTableContentID = "no-snapshot|no-focus"

    var snapshotID: UUID?
    var fileTreeStore: FileTreeStore?
    var selectedNodeID: FileNodeRecord.ID?
    var focusedNodeID: FileNodeRecord.ID?
    var focusBackStack: [FileNodeRecord.ID]
    var focusForwardStack: [FileNodeRecord.ID]
    var tableNodes: [FileNodeRecord]
    var tableContentID: String
    var selectedAncestorIDs: Set<FileNodeRecord.ID>

    static let empty = WorkspaceNavigationState(
        snapshotID: nil,
        fileTreeStore: nil,
        selectedNodeID: nil,
        focusedNodeID: nil,
        focusBackStack: [],
        focusForwardStack: [],
        tableNodes: [],
        tableContentID: Self.emptyTableContentID,
        selectedAncestorIDs: []
    )

    static func == (lhs: WorkspaceNavigationState, rhs: WorkspaceNavigationState) -> Bool {
        lhs.snapshotID == rhs.snapshotID &&
            lhs.fileTreeStore?.rootID == rhs.fileTreeStore?.rootID &&
            lhs.fileTreeStore?.nodeCount == rhs.fileTreeStore?.nodeCount &&
            lhs.selectedNodeID == rhs.selectedNodeID &&
            lhs.focusedNodeID == rhs.focusedNodeID &&
            lhs.focusBackStack == rhs.focusBackStack &&
            lhs.focusForwardStack == rhs.focusForwardStack &&
            lhs.tableContentID == rhs.tableContentID &&
            lhs.tableNodes.map(\.id) == rhs.tableNodes.map(\.id) &&
            lhs.selectedAncestorIDs == rhs.selectedAncestorIDs
    }
}

private extension WorkspaceNavigationState {
    var resolvedFocusNode: FileNodeRecord? {
        fileTreeStore?.node(id: focusedNodeID) ?? fileTreeStore?.root
    }

    func applyingScanContext(_ snapshot: ScanSnapshot?) -> WorkspaceNavigationState {
        var next = self
        next.snapshotID = snapshot?.id
        next.fileTreeStore = snapshot?.treeStore

        guard next.fileTreeStore != nil else {
            next.selectedNodeID = nil
            next.focusedNodeID = nil
            next.focusBackStack = []
            next.focusForwardStack = []
            return next.refreshedDerivedState()
        }

        next.clearMissingNavigationReferences()
        return next.refreshedDerivedState()
    }

    func reconcilingAfterSnapshotApplied(_ snapshot: ScanSnapshot?) -> WorkspaceNavigationState {
        var next = self
        next.snapshotID = snapshot?.id
        next.fileTreeStore = snapshot?.treeStore
        next.focusBackStack = []
        next.focusForwardStack = []

        guard let snapshot else {
            next.selectedNodeID = nil
            next.focusedNodeID = nil
            return next.refreshedDerivedState()
        }

        if next.focusedNodeID == nil || next.fileTreeStore?.node(id: next.focusedNodeID) == nil {
            next.focusedNodeID = snapshot.root.id
        }

        if let selectedNodeID = next.selectedNodeID,
           next.fileTreeStore?.node(id: selectedNodeID) == nil {
            next.selectedNodeID = nil
        }

        return next.refreshedDerivedState()
    }

    func selecting(_ nodeID: FileNodeRecord.ID?) -> WorkspaceNavigationState {
        var next = self

        guard let nodeID,
              fileTreeStore?.node(id: nodeID) != nil else {
            next.selectedNodeID = nil
            return next.refreshedSelectionState()
        }

        next.selectedNodeID = nodeID
        return next.refreshedSelectionState()
    }

    func selectingAndFocusing(_ nodeID: FileNodeRecord.ID) -> WorkspaceNavigationState {
        guard fileTreeStore?.node(id: nodeID) != nil else {
            return selecting(nil)
        }

        var next = self
        next.selectedNodeID = nodeID

        if next.focusedNodeID != nodeID {
            if let currentFocusID = next.focusedNodeID {
                next.focusBackStack.append(currentFocusID)
            }
            next.focusForwardStack.removeAll()
            next.focusedNodeID = nodeID
        }

        return next.refreshedDerivedState()
    }

    func settingFocusedNodeID(_ nodeID: FileNodeRecord.ID?) -> WorkspaceNavigationState {
        guard let nodeID else {
            var next = self
            next.focusedNodeID = nil
            return next.refreshedDerivedState()
        }

        return focusing(nodeID, recordHistory: false)
    }

    func focusing(_ nodeID: FileNodeRecord.ID?, recordHistory: Bool) -> WorkspaceNavigationState {
        guard let nodeID,
              fileTreeStore?.node(id: nodeID) != nil,
              focusedNodeID != nodeID else {
            return self
        }

        var next = self
        if recordHistory, let currentFocusID = next.focusedNodeID {
            next.focusBackStack.append(currentFocusID)
            next.focusForwardStack.removeAll()
        }

        next.focusedNodeID = nodeID
        next.clearSelectionIfNeeded(forFocus: nodeID)
        return next.refreshedDerivedState()
    }

    func navigatingBack() -> WorkspaceNavigationState {
        var next = self
        guard let previousFocusID = next.focusBackStack.popLast(),
              next.fileTreeStore?.node(id: previousFocusID) != nil else {
            return self
        }

        if let currentFocusID = next.focusedNodeID {
            next.focusForwardStack.append(currentFocusID)
        }

        next.focusedNodeID = previousFocusID
        next.clearSelectionIfNeeded(forFocus: previousFocusID)
        return next.refreshedDerivedState()
    }

    func navigatingForward() -> WorkspaceNavigationState {
        var next = self
        guard let nextFocusID = next.focusForwardStack.popLast(),
              next.fileTreeStore?.node(id: nextFocusID) != nil else {
            return self
        }

        if let currentFocusID = next.focusedNodeID {
            next.focusBackStack.append(currentFocusID)
        }

        next.focusedNodeID = nextFocusID
        next.clearSelectionIfNeeded(forFocus: nextFocusID)
        return next.refreshedDerivedState()
    }

    func resettingFocusToRoot() -> WorkspaceNavigationState {
        guard let rootID = fileTreeStore?.root.id else { return self }

        var next = focusing(rootID, recordHistory: true)
        next.selectedNodeID = nil
        return next.refreshedSelectionState()
    }

    mutating func clearMissingNavigationReferences() {
        guard let fileTreeStore else { return }

        if let selectedNodeID,
           fileTreeStore.node(id: selectedNodeID) == nil {
            self.selectedNodeID = nil
        }

        if let focusedNodeID,
           fileTreeStore.node(id: focusedNodeID) == nil {
            self.focusedNodeID = nil
        }

        focusBackStack = focusBackStack.filter { fileTreeStore.node(id: $0) != nil }
        focusForwardStack = focusForwardStack.filter { fileTreeStore.node(id: $0) != nil }
    }

    mutating func clearSelectionIfNeeded(forFocus nodeID: FileNodeRecord.ID) {
        guard let selectedNodeID,
              selectedNodeID != nodeID,
              fileTreeStore?.isAncestor(nodeID, of: selectedNodeID) != true else {
            return
        }

        self.selectedNodeID = nil
    }

    func refreshedDerivedState() -> WorkspaceNavigationState {
        refreshedSelectionState().refreshedTableState()
    }

    func refreshedSelectionState() -> WorkspaceNavigationState {
        var next = self

        guard let fileTreeStore,
              let selectedNodeID,
              fileTreeStore.node(id: selectedNodeID) != nil else {
            next.selectedNodeID = nil
            next.selectedAncestorIDs = []
            return next
        }

        next.selectedAncestorIDs = Set(fileTreeStore.path(to: selectedNodeID).map(\.id))
        return next
    }

    func refreshedTableState() -> WorkspaceNavigationState {
        var next = self
        let focusNode = next.resolvedFocusNode
        next.tableContentID = [
            next.snapshotID?.uuidString ?? "no-snapshot",
            focusNode?.id ?? "no-focus"
        ].joined(separator: "|")

        guard let fileTreeStore,
              let focusNode else {
            next.tableNodes = []
            return next
        }

        if focusNode.isDirectory {
            next.tableNodes = fileTreeStore.children(of: focusNode.id)
        } else if let parent = fileTreeStore.parent(of: focusNode.id) {
            next.tableNodes = fileTreeStore.children(of: parent.id)
        } else {
            next.tableNodes = []
        }

        return next
    }
}

@MainActor
final class WorkspaceNavigationModel: ObservableObject {
    nonisolated static let emptyTableContentID = "no-snapshot|no-focus"

    @Published private(set) var state = WorkspaceNavigationState.empty

    var selectedNodeID: String? {
        state.selectedNodeID
    }

    var focusedNodeID: String? {
        state.focusedNodeID
    }

    var onSelectionChanged: (() -> Void)?

    var tableNodes: [FileNodeRecord] {
        state.tableNodes
    }

    var tableContentID: String {
        state.tableContentID
    }

    var selectedAncestorIDs: Set<String> {
        state.selectedAncestorIDs
    }

    var currentFocusNode: FileNodeRecord? {
        state.resolvedFocusNode
    }

    var selectedNode: FileNodeRecord? {
        state.fileTreeStore?.node(id: selectedNodeID)
    }

    var selectedNodeParent: FileNodeRecord? {
        state.fileTreeStore?.parent(of: selectedNode?.id)
    }

    var breadcrumbNodes: [FileNodeRecord] {
        guard let fileTreeStore = state.fileTreeStore else { return [] }
        return fileTreeStore.path(to: focusedNodeID)
    }

    var canZoomIntoSelection: Bool {
        guard let fileTreeStore = state.fileTreeStore, let selectedNode else { return false }
        return selectedNode.isDirectory && fileTreeStore.containsChildren(id: selectedNode.id)
    }

    var canNavigateBack: Bool {
        !state.focusBackStack.isEmpty
    }

    var canNavigateForward: Bool {
        !state.focusForwardStack.isEmpty
    }

    var canClearSelection: Bool {
        selectedNodeID != nil
    }

    var isFocusedAtRoot: Bool {
        guard let rootID = state.fileTreeStore?.root.id else { return true }
        return (focusedNodeID ?? rootID) == rootID
    }

    func updateScanContext(snapshot: ScanSnapshot?) {
        publish(state.applyingScanContext(snapshot), force: true)
    }

    func reset() {
        publish(.empty)
    }

    func select(nodeID: String?) {
        publish(state.selecting(nodeID))
    }

    func selectAndFocus(nodeID: String) {
        publish(state.selectingAndFocusing(nodeID))
    }

    func setFocusedNodeID(_ nodeID: String?) {
        publish(state.settingFocusedNodeID(nodeID))
    }

    func focus(nodeID: String?) {
        publish(state.focusing(nodeID, recordHistory: true))
    }

    func clearSelection() {
        publish(state.selecting(nil))
    }

    func navigateBack() {
        publish(state.navigatingBack())
    }

    func navigateForward() {
        publish(state.navigatingForward())
    }

    func resetFocusToRoot() {
        publish(state.resettingFocusToRoot())
    }

    func reconcileAfterSnapshotApplied(_ snapshot: ScanSnapshot?) {
        publish(state.reconcilingAfterSnapshotApplied(snapshot), force: true)
    }

    private func publish(_ nextState: WorkspaceNavigationState, force: Bool = false) {
        guard force || nextState != state else { return }

        let oldSelectionID = state.selectedNodeID
        state = nextState

        if oldSelectionID != nextState.selectedNodeID {
            onSelectionChanged?()
        }
    }
}
