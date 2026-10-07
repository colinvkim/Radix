//
//  TrashFlowController.swift
//  Radix
//

import Combine
import Foundation

/// Owns the state machines behind trash moves and the discard pile: pending
/// confirmations, optimistic visibility during moves, post-trash snapshot
/// removal bookkeeping, and the in-flight confirmed-move tasks. AppModel wires
/// `onChange` to refresh dependent presentations and publish object changes.
@MainActor
final class TrashFlowController {
    struct OptimisticTrashVisibilityState: Equatable, Sendable {
        let nodeIDs: Set<FileNodeRecord.ID>
        let snapshotID: UUID?

        init(
            nodeIDs: Set<FileNodeRecord.ID> = [],
            snapshotID: UUID? = nil
        ) {
            self.nodeIDs = nodeIDs.isEmpty ? [] : nodeIDs
            self.snapshotID = nodeIDs.isEmpty ? nil : snapshotID
        }
    }

    struct PendingTrashSelection {
        let nodes: [FileNodeRecord]
        let allowsHiddenNodes: Bool

        init(
            nodes: [FileNodeRecord],
            allowsHiddenNodes: Bool = false
        ) {
            self.nodes = nodes
            self.allowsHiddenNodes = allowsHiddenNodes
        }
    }

    struct PendingCloudFileAction {
        enum Kind: Equatable {
            case addToDiscardPile
            case moveToTrash(allowsHiddenNodes: Bool)
        }

        let kind: Kind
        let nodes: [FileNodeRecord]
        let cloudImpact: CloudStorageLocation.Impact
    }

    /// Invoked on the main actor after every mutating assignment below.
    var onChange: (() -> Void)?

    var pendingTrashSelection: PendingTrashSelection? {
        didSet { notifyChanged() }
    }

    var pendingCloudFileAction: PendingCloudFileAction? {
        didSet { notifyChanged() }
    }

    @Published private(set) var discardPile: DiscardPileState {
        didSet { notifyChanged() }
    }

    let discardPileUndoManager = UndoManager()
    var onDiscardPileHistoryReplay: ((DiscardPileState) -> Void)?

    private var discardPileHistorySnapshotID: UUID?
    private var discardPileHistoryTreeContentID: UUID?
    private var historyNotifications = Set<AnyCancellable>()

    private(set) var optimisticTrashVisibility = OptimisticTrashVisibilityState()

    private var confirmedTrashMoveTasks: [UUID: Task<Void, Never>] = [:]
    private var postTrashRemovalTask: Task<Void, Never>?
    private var postTrashRemovalRequests: [@MainActor () async -> Void] = []

    var isMovingFiles: Bool { !confirmedTrashMoveTasks.isEmpty || postTrashRemovalTask != nil }

    init(
        pendingTrashSelection: PendingTrashSelection? = nil,
        pendingCloudFileAction: PendingCloudFileAction? = nil,
        discardPile: DiscardPileState = DiscardPileState()
    ) {
        self.pendingTrashSelection = pendingTrashSelection
        self.pendingCloudFileAction = pendingCloudFileAction
        self.discardPile = discardPile
        discardPileHistorySnapshotID = discardPile.snapshotID
        discardPileUndoManager.groupsByEvent = false
        discardPileUndoManager.levelsOfUndo = 50
        NotificationCenter.default.publisher(
            for: .NSUndoManagerDidUndoChange,
            object: discardPileUndoManager
        )
        .merge(with: NotificationCenter.default.publisher(
            for: .NSUndoManagerDidRedoChange,
            object: discardPileUndoManager
        ))
        .sink { [weak self] _ in self?.notifyChanged() }
        .store(in: &historyNotifications)
    }

    isolated deinit {
        cancelConfirmedTrashMoves()
        cancelPostTrashSnapshotRemoval()
    }

    func cancelConfirmedTrashMoves() {
        for task in confirmedTrashMoveTasks.values { task.cancel() }
        confirmedTrashMoveTasks.removeAll()
    }

    func cancelPostTrashSnapshotRemoval() {
        postTrashRemovalRequests.removeAll()
        postTrashRemovalTask?.cancel()
        postTrashRemovalTask = nil
    }

    @discardableResult
    func replaceOptimisticTrashVisibility(
        nodeIDs: Set<FileNodeRecord.ID>,
        snapshotID: UUID?
    ) -> Bool {
        let updatedState = OptimisticTrashVisibilityState(
            nodeIDs: nodeIDs,
            snapshotID: snapshotID
        )
        guard updatedState != optimisticTrashVisibility else { return false }
        optimisticTrashVisibility = updatedState
        notifyChanged()
        return true
    }

    @discardableResult
    func clearOptimisticTrashVisibility() -> Bool {
        replaceOptimisticTrashVisibility(nodeIDs: [], snapshotID: nil)
    }

    /// Validates trash support, reduces nodes to top-level items, and stages
    /// the pending confirmation. Throws when any node cannot be trashed.
    func stageTrashRequest(
        for nodes: [FileNodeRecord],
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        fileTreeStore: FileTreeStore?,
        allowingHiddenNodes: Bool = false
    ) throws {
        guard nodes.allSatisfy({ node in
            node.supportsMoveToTrash(
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy
            )
        }) else {
            throw FileActionError.unsupported
        }

        let trashNodes = Self.topLevelTrashNodes(from: nodes, fileTreeStore: fileTreeStore)
        pendingTrashSelection = PendingTrashSelection(
            nodes: trashNodes,
            allowsHiddenNodes: allowingHiddenNodes
        )
    }

    /// Context is independent of the pile, which loses its snapshot ID when empty.
    func synchronizeDiscardPileContext(snapshotID: UUID?, treeContentID: UUID?) {
        guard discardPileHistorySnapshotID != snapshotID ||
                discardPileHistoryTreeContentID != treeContentID else { return }
        discardPileHistorySnapshotID = snapshotID
        discardPileHistoryTreeContentID = treeContentID
        invalidateDiscardPileHistory()
    }

    func invalidateDiscardPileHistory() {
        guard discardPileUndoManager.canUndo || discardPileUndoManager.canRedo else { return }
        discardPileUndoManager.removeAllActions()
        notifyChanged()
    }

    /// Reconciliation and filesystem changes replace state without becoming undoable.
    func replaceDiscardPile(_ state: DiscardPileState) {
        invalidateDiscardPileHistory()
        guard state != discardPile else { return }
        discardPile = state
    }

    /// One user edit stores the complete ordered state, including ancestor collapse.
    func changeDiscardPile(_ state: DiscardPileState, actionName: String) {
        guard state != discardPile else { return }
        if discardPileHistorySnapshotID == nil {
            discardPileHistorySnapshotID = state.snapshotID ?? discardPile.snapshotID
        }
        guard let snapshotID = discardPileHistorySnapshotID,
              state.isEmpty || state.snapshotID == snapshotID else { return }
        let previous = discardPile
        let isReplaying = discardPileUndoManager.isUndoing || discardPileUndoManager.isRedoing
        if !isReplaying { discardPileUndoManager.beginUndoGrouping() }
        discardPileUndoManager.registerUndo(withTarget: self) { controller in
            guard controller.discardPileHistorySnapshotID == snapshotID else { return }
            controller.changeDiscardPile(previous, actionName: actionName)
        }
        discardPileUndoManager.setActionName(actionName)
        if !isReplaying { discardPileUndoManager.endUndoGrouping() }
        discardPile = state
        if isReplaying { onDiscardPileHistoryReplay?(state) }
    }

    func removeDiscardPileNodes(ids nodeIDs: Set<FileNodeRecord.ID>) {
        guard !nodeIDs.isEmpty else { return }
        let remainingIDs = discardPile.nodeIDs.filter { !nodeIDs.contains($0) }
        changeDiscardPile(
            DiscardPileState(nodeIDs: remainingIDs, snapshotID: discardPile.snapshotID),
            actionName: String(localized: "Remove from Discard Pile", comment: "Action for unmarking items that will no longer be included in the Discard Pile.")
        )
    }

    func clearDiscardPile() {
        changeDiscardPile(
            DiscardPileState(),
            actionName: String(localized: "Clear Discard Pile", comment: "Undo action name for removing every mark from the Discard Pile.")
        )
    }

    static func topLevelTrashNodes(
        from nodes: [FileNodeRecord],
        fileTreeStore: FileTreeStore?
    ) -> [FileNodeRecord] {
        guard let fileTreeStore else { return nodes }
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fileTreeStore.topLevelNodeIDs(from: nodes.map(\.id)).compactMap { nodesByID[$0] }
    }

    static func fileActionError(
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

    /// Applies optimistic visibility for the duration of a move. Returns
    /// whether any state changed so callers can run follow-up reconciliation.
    @discardableResult
    func hideTrashNodesDuringMove(
        _ nodes: [FileNodeRecord],
        snapshotID: UUID?,
        activeSnapshotID: UUID?,
        activeFileTreeStore: FileTreeStore?
    ) -> Bool {
        guard let snapshotID,
              activeSnapshotID == snapshotID,
              let activeFileTreeStore else {
            return false
        }

        let nodeIDs = Set(activeFileTreeStore.topLevelNodeIDs(from: nodes.map(\.id)))
        guard !nodeIDs.isEmpty else { return false }

        let existingIDs = optimisticTrashVisibility.snapshotID == snapshotID
            ? optimisticTrashVisibility.nodeIDs
            : []
        let hiddenIDs = existingIDs.union(nodeIDs)
        replaceOptimisticTrashVisibility(
            nodeIDs: hiddenIDs,
            snapshotID: snapshotID
        )
        return true
    }

    func unhideTrashNodesAfterFailedMove(
        requestedNodes: [FileNodeRecord],
        movedNodes: [FileNodeRecord],
        snapshotID: UUID?
    ) {
        guard let snapshotID,
              optimisticTrashVisibility.snapshotID == snapshotID else {
            return
        }

        let movedNodeIDs = Set(movedNodes.map(\.id))
        let unmovedNodeIDs = Set(
            requestedNodes
                .map(\.id)
                .filter { !movedNodeIDs.contains($0) }
        )
        guard !unmovedNodeIDs.isEmpty else { return }

        let hiddenIDs = optimisticTrashVisibility.nodeIDs.subtracting(unmovedNodeIDs)
        replaceOptimisticTrashVisibility(
            nodeIDs: hiddenIDs,
            snapshotID: snapshotID
        )
    }

    /// Tracks every confirmed batch so cancelling also stops overlapping moves.
    /// Completed filesystem moves are reported even if cancellation follows.
    func startConfirmedMove(
        _ nodes: [FileNodeRecord],
        moveToTrash: @escaping @MainActor (FileNodeRecord) async throws -> TrashIdentityVerificationResult,
        beginMove: () -> Void,
        onFinish: @escaping @MainActor (_ requested: [FileNodeRecord], _ moved: [FileNodeRecord], _ actionError: Error?, _ wasCancelled: Bool) -> Void
    ) {
        let requestID = UUID()
        confirmedTrashMoveTasks[requestID] = Task { [weak self] in
            var movedNodes: [FileNodeRecord] = []
            var actionError: Error?
            var wasCancelled = false
            for node in nodes {
                do {
                    try Task.checkCancellation()
                    let verificationResult = try await moveToTrash(node)
                    if let identityError = Self.fileActionError(for: verificationResult, node: node) {
                        actionError = identityError
                        break
                    }
                    movedNodes.append(node)
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    actionError = error
                    break
                }
            }

            self?.confirmedTrashMoveTasks.removeValue(forKey: requestID)
            onFinish(nodes, movedNodes, actionError, wasCancelled)
        }
        beginMove()
    }

    func enqueuePostTrashSnapshotRemoval(_ removal: @escaping @MainActor () async -> Void) {
        postTrashRemovalRequests.append(removal)
        guard postTrashRemovalTask == nil else { return }

        postTrashRemovalTask = Task { [weak self] in
            while !Task.isCancelled, let removal = self?.postTrashRemovalRequests.first {
                self?.postTrashRemovalRequests.removeFirst()
                await removal()
            }
            // A cancelled worker must not clear the handle of its replacement.
            guard !Task.isCancelled else { return }
            self?.postTrashRemovalTask = nil
        }
    }

    private func notifyChanged() {
        onChange?()
    }
}
