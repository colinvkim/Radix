//
//  TrashFlowController.swift
//  Radix
//

import Combine
import Foundation

/// Owns the state machines behind trash moves and the discard pile: pending
/// confirmations, optimistic visibility during moves, post-trash snapshot
/// removal bookkeeping, and the in-flight confirmed-move task. AppModel wires
/// `onChange` to refresh dependent presentations and publish object changes.
@MainActor
final class TrashFlowController {
    struct PostTrashRemovalRequest: Sendable {
        let nodeIDs: [FileNodeRecord.ID]
        let fallbackFocusID: FileNodeRecord.ID?
    }

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

    @Published var discardPile: DiscardPileState {
        didSet { notifyChanged() }
    }

    private(set) var optimisticTrashVisibility = OptimisticTrashVisibilityState()

    var confirmedTrashMoveTask: Task<Void, Never>?
    var postTrashRemovalTask: Task<Void, Never>?
    var postTrashRemovalRequests: [PostTrashRemovalRequest] = []

    init(
        pendingTrashSelection: PendingTrashSelection? = nil,
        pendingCloudFileAction: PendingCloudFileAction? = nil,
        discardPile: DiscardPileState = DiscardPileState()
    ) {
        self.pendingTrashSelection = pendingTrashSelection
        self.pendingCloudFileAction = pendingCloudFileAction
        self.discardPile = discardPile
    }

    func cancelConfirmedTrashMove() {
        confirmedTrashMoveTask?.cancel()
        confirmedTrashMoveTask = nil
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

    func removeDiscardPileNodes(ids nodeIDs: Set<FileNodeRecord.ID>) {
        guard !nodeIDs.isEmpty else { return }
        let remainingIDs = discardPile.nodeIDs.filter { !nodeIDs.contains($0) }
        guard remainingIDs.count != discardPile.nodeIDs.count else { return }
        discardPile = DiscardPileState(
            nodeIDs: remainingIDs,
            snapshotID: discardPile.snapshotID
        )
    }

    func clearDiscardPile() {
        guard !discardPile.isEmpty else { return }
        discardPile = DiscardPileState()
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

    /// Runs one confirmed trash move synchronously and reports the outcome.
    /// `beginMove` applies optimistic hiding using the caller's live snapshot
    /// state; `onFinish` applies cross-model side effects on the caller.
    func runConfirmedMoveSynchronously(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?,
        actions: AppSystemActions,
        beginMove: (UUID?, FileTreeStore?) -> Void,
        onFinish: (_ requested: [FileNodeRecord], _ moved: [FileNodeRecord], _ actionError: Error?) -> Void
    ) {
        beginMove(originalSnapshotID, statsFileTreeStore)

        var movedNodes: [FileNodeRecord] = []
        var actionError: Error?
        for node in nodes {
            do {
                let verificationResult = try actions.moveToTrash(node)
                if let identityError = Self.fileActionError(for: verificationResult, node: node) {
                    actionError = identityError
                    break
                }
                movedNodes.append(node)
            } catch {
                actionError = error
                break
            }
        }

        onFinish(nodes, movedNodes, actionError)
    }

    /// Async counterpart of runConfirmedMoveSynchronously; cancellation stops
    /// the loop and is reported through the returned flag so unmoved items can
    /// be restored without presenting a spurious error.
    func runConfirmedMoveAsynchronously(
        _ nodes: [FileNodeRecord],
        originalSnapshotID: UUID?,
        statsFileTreeStore: FileTreeStore?,
        actions: AppSystemActions,
        beginMove: (UUID?, FileTreeStore?) -> Void,
        onFinish: (_ requested: [FileNodeRecord], _ moved: [FileNodeRecord], _ actionError: Error?, _ wasCancelled: Bool) -> Void
    ) async {
        beginMove(originalSnapshotID, statsFileTreeStore)

        var movedNodes: [FileNodeRecord] = []
        var actionError: Error?
        var wasCancelled = false
        for node in nodes {
            do {
                let verificationResult: TrashIdentityVerificationResult
                if let asyncMoveToTrash = actions.asyncMoveToTrash {
                    verificationResult = try await asyncMoveToTrash(node)
                } else {
                    verificationResult = try actions.moveToTrash(node)
                }
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

        onFinish(nodes, movedNodes, actionError, wasCancelled)
    }

    private func notifyChanged() {
        onChange?()
    }
}
