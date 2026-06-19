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
    var selectedNodeIDs: Set<FileNodeRecord.ID>
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
        selectedNodeIDs: [],
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
            lhs.selectedNodeIDs == rhs.selectedNodeIDs &&
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

        guard let snapshot else {
            next.selectedNodeID = nil
            next.selectedNodeIDs = []
            next.focusedNodeID = nil
            next.focusBackStack = []
            next.focusForwardStack = []
            return next.refreshedDerivedState()
        }

        next.clearMissingNavigationReferences()
        if next.focusedNodeID == nil {
            next.focusedNodeID = snapshot.root.id
        }
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
            next.selectedNodeIDs = []
            next.focusedNodeID = nil
            return next.refreshedDerivedState()
        }

        if next.focusedNodeID == nil || next.fileTreeStore?.node(id: next.focusedNodeID) == nil {
            next.focusedNodeID = snapshot.root.id
        }

        next.clearMissingSelectionReferences()

        return next.refreshedDerivedState()
    }

    func selecting(_ nodeID: FileNodeRecord.ID?) -> WorkspaceNavigationState {
        var next = self

        guard let nodeID,
              fileTreeStore?.node(id: nodeID) != nil else {
            next.selectedNodeID = nil
            next.selectedNodeIDs = []
            return next.refreshedSelectionState()
        }

        next.selectedNodeID = nodeID
        next.selectedNodeIDs = [nodeID]
        return next.refreshedSelectionState()
    }

    func selecting(
        _ nodeIDs: Set<FileNodeRecord.ID>,
        primaryNodeID: FileNodeRecord.ID?
    ) -> WorkspaceNavigationState {
        guard let fileTreeStore else {
            return selecting(nil)
        }

        let validIDs = Set(nodeIDs.filter { fileTreeStore.node(id: $0) != nil })
        guard !validIDs.isEmpty else {
            return selecting(nil)
        }

        var next = self
        next.selectedNodeIDs = validIDs

        if let primaryNodeID,
           validIDs.contains(primaryNodeID) {
            next.selectedNodeID = primaryNodeID
        } else if let selectedNodeID,
                  validIDs.contains(selectedNodeID) {
            next.selectedNodeID = selectedNodeID
        } else {
            next.selectedNodeID = next.firstSelectedID(in: validIDs)
        }

        return next.refreshedSelectionState()
    }

    func selectingAndFocusing(_ nodeID: FileNodeRecord.ID) -> WorkspaceNavigationState {
        guard fileTreeStore?.node(id: nodeID) != nil else {
            return selecting(nil)
        }

        var next = self
        next.selectedNodeID = nodeID
        next.selectedNodeIDs = [nodeID]

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

    func navigatingToParent() -> WorkspaceNavigationState {
        guard let focusNode = resolvedFocusNode,
              let parent = fileTreeStore?.parent(of: focusNode.id) else {
            return self
        }

        return focusing(parent.id, recordHistory: true)
    }

    func resettingFocusToRoot() -> WorkspaceNavigationState {
        guard let rootID = fileTreeStore?.root.id else { return self }

        var next = focusing(rootID, recordHistory: true)
        next.selectedNodeID = nil
        next.selectedNodeIDs = []
        return next.refreshedSelectionState()
    }

    mutating func clearMissingNavigationReferences() {
        guard let fileTreeStore else { return }

        clearMissingSelectionReferences()

        if let focusedNodeID,
           fileTreeStore.node(id: focusedNodeID) == nil {
            self.focusedNodeID = nil
        }

        focusBackStack = focusBackStack.filter { fileTreeStore.node(id: $0) != nil }
        focusForwardStack = focusForwardStack.filter { fileTreeStore.node(id: $0) != nil }
    }

    mutating func clearMissingSelectionReferences() {
        guard let fileTreeStore else {
            selectedNodeID = nil
            selectedNodeIDs = []
            return
        }

        selectedNodeIDs = selectedNodeIDs.filter { fileTreeStore.node(id: $0) != nil }

        if let selectedNodeID,
           fileTreeStore.node(id: selectedNodeID) != nil {
            selectedNodeIDs.insert(selectedNodeID)
        } else {
            selectedNodeID = nil
        }

        if let selectedNodeID,
           !selectedNodeIDs.contains(selectedNodeID) {
            self.selectedNodeID = nil
        }

        if selectedNodeID == nil {
            selectedNodeID = firstSelectedID(in: selectedNodeIDs)
        }
    }

    mutating func clearSelectionIfNeeded(forFocus nodeID: FileNodeRecord.ID) {
        guard let selectedNodeID,
              selectedNodeID != nodeID,
              fileTreeStore?.isAncestor(nodeID, of: selectedNodeID) != true else {
            return
        }

        self.selectedNodeID = nil
        self.selectedNodeIDs = []
    }

    func refreshedDerivedState() -> WorkspaceNavigationState {
        refreshedSelectionState().refreshedTableState()
    }

    func refreshedSelectionState() -> WorkspaceNavigationState {
        var next = self

        guard let fileTreeStore else {
            next.selectedNodeID = nil
            next.selectedNodeIDs = []
            next.selectedAncestorIDs = []
            return next
        }

        next.clearMissingSelectionReferences()

        guard let selectedNodeID = next.selectedNodeID else {
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

    func firstSelectedID(in nodeIDs: Set<FileNodeRecord.ID>) -> FileNodeRecord.ID? {
        tableNodes.first(where: { nodeIDs.contains($0.id) })?.id ?? nodeIDs.sorted().first
    }
}

@MainActor
final class WorkspaceNavigationModel: ObservableObject {
    nonisolated static let emptyTableContentID = "no-snapshot|no-focus"

    @Published private(set) var state = WorkspaceNavigationState.empty

    var selectedNodeID: String? {
        state.selectedNodeID
    }

    var selectedNodeIDs: Set<String> {
        state.selectedNodeIDs
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

    var currentFocusNodeParent: FileNodeRecord? {
        guard let focusNode = currentFocusNode else { return nil }
        return state.fileTreeStore?.parent(of: focusNode.id)
    }

    var selectedNode: FileNodeRecord? {
        state.fileTreeStore?.node(id: selectedNodeID)
    }

    var selectedNodes: [FileNodeRecord] {
        guard let fileTreeStore = state.fileTreeStore else { return [] }

        var emittedIDs = Set<FileNodeRecord.ID>()
        var nodes: [FileNodeRecord] = []

        for node in state.tableNodes where state.selectedNodeIDs.contains(node.id) {
            nodes.append(node)
            emittedIDs.insert(node.id)
        }

        for id in state.selectedNodeIDs.sorted() where !emittedIDs.contains(id) {
            if let node = fileTreeStore.node(id: id) {
                nodes.append(node)
            }
        }

        return nodes
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

    var canNavigateToParent: Bool {
        currentFocusNodeParent != nil
    }

    var canClearSelection: Bool {
        !selectedNodeIDs.isEmpty
    }

    var isFocusedAtRoot: Bool {
        guard let rootID = state.fileTreeStore?.root.id else { return true }
        return (focusedNodeID ?? rootID) == rootID
    }

    func updateScanContext(snapshot: ScanSnapshot?) {
        publish(state.applyingScanContext(snapshot))
    }

    func reset() {
        publish(.empty)
    }

    func select(nodeID: String?) {
        publish(state.selecting(nodeID))
    }

    func select(nodeIDs: Set<String>, primaryNodeID: String?) {
        publish(state.selecting(nodeIDs, primaryNodeID: primaryNodeID))
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

    func navigateToParent() {
        publish(state.navigatingToParent())
    }

    func resetFocusToRoot() {
        publish(state.resettingFocusToRoot())
    }

    func reconcileAfterSnapshotApplied(_ snapshot: ScanSnapshot?) {
        publish(state.reconcilingAfterSnapshotApplied(snapshot))
    }

    private func publish(_ nextState: WorkspaceNavigationState) {
        guard nextState != state else { return }

        let oldSelectionID = state.selectedNodeID
        let oldSelectionIDs = state.selectedNodeIDs
        state = nextState

        if oldSelectionID != nextState.selectedNodeID || oldSelectionIDs != nextState.selectedNodeIDs {
            onSelectionChanged?()
        }
    }
}
