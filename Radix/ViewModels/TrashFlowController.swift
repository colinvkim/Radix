import Combine
import Foundation

struct DiscardPileState: Equatable, Sendable {
    struct Mark: Equatable, Sendable {
        let node: FileNodeRecord
        let unidentifiedTreeID: UUID?

        init(node: FileNodeRecord, treeID: UUID? = nil) {
            self.node = node
            unidentifiedTreeID = node.fileIdentity == nil ? treeID : nil
        }

        func matches(_ current: FileNodeRecord, treeID: UUID) -> Bool {
            guard node.id == current.id else { return false }
            if node.fileIdentity == nil {
                return unidentifiedTreeID == treeID && current.fileIdentity == nil
            }
            return Self.matchesIdentity(of: node, with: current)
        }

        static func matchesIdentity(of original: FileNodeRecord, with current: FileNodeRecord) -> Bool {
            guard original.id == current.id else { return false }
            if original.fileIdentity == current.fileIdentity { return true }
            guard !original.isSymbolicLink, !current.isSymbolicLink,
                  let first = original.fileIdentity, let second = current.fileIdentity,
                  first.isFileSystemIdentity != second.isFileSystemIdentity else { return false }
            return SystemIntegration.verifyTrashIdentity(original) == .matches
                && SystemIntegration.verifyTrashIdentity(current) == .matches
                && SystemIntegration.verifyTrashIdentity(original) == .matches
        }
    }

    let marks: [Mark]

    init(marks: [Mark] = []) {
        self.marks = marks
    }

    var nodes: [FileNodeRecord] { marks.map(\.node) }
    var nodeIDs: [FileNodeRecord.ID] { marks.map(\.node.id) }
    var isEmpty: Bool { marks.isEmpty }

    func matchingNodeIDs(in snapshot: ScanSnapshot?) -> Set<FileNodeRecord.ID> {
        guard let snapshot, snapshot.isComplete, snapshot.source.allowsFileMutation else { return [] }
        let tree = snapshot.treeStore
        return Set(marks.compactMap { mark in
            guard let current = tree.node(id: mark.node.id),
                  mark.matches(current, treeID: tree.contentID) else { return nil }
            return current.id
        })
    }
}

@MainActor
final class TrashFlowController {
    struct OptimisticTrashVisibilityState: Equatable, Sendable {
        let nodes: [FileNodeRecord.ID: FileNodeRecord]
        let snapshotID: UUID?

        init(nodes: [FileNodeRecord.ID: FileNodeRecord] = [:], snapshotID: UUID? = nil) {
            self.nodes = nodes
            self.snapshotID = nodes.isEmpty ? nil : snapshotID
        }

        var nodeIDs: Set<FileNodeRecord.ID> { Set(nodes.keys) }
    }

    nonisolated struct DiscardPileTrashBatch: Sendable {
        struct Unavailable: Sendable {
            let node: FileNodeRecord
            let message: String
        }

        let unavailable: [Unavailable]
        let coveredMarks: [FileNodeRecord.ID: [FileNodeRecord]]
    }

    nonisolated struct PendingTrashSelection: Sendable {
        let nodes: [FileNodeRecord]
        var discardPileBatch: DiscardPileTrashBatch? = nil
    }

    struct PendingCloudFileAction {
        enum Kind: Equatable {
            case addToDiscardPile
            case moveToTrash
        }

        let kind: Kind
        let nodes: [FileNodeRecord]
        let cloudImpact: CloudStorageLocation.Impact
        var discardPileBatch: DiscardPileTrashBatch? = nil
    }

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

    private var historyNotifications = Set<AnyCancellable>()

    private(set) var optimisticTrashVisibility = OptimisticTrashVisibilityState()

    private var confirmedTrashMoveTasks: [UUID: Task<Void, Never>] = [:]
    private var postTrashRemovalTask: Task<Void, Never>?
    private var postTrashRemovalRequests: [@MainActor () async -> Void] = []

    private(set) var isReadOnlyMode = false

    @discardableResult
    func setReadOnlyMode(_ isEnabled: Bool) -> Bool {
        guard isEnabled != isReadOnlyMode else { return true }
        guard !isMovingFiles else { return false }
        isReadOnlyMode = isEnabled
        if isEnabled {
            pendingTrashSelection = nil
            pendingCloudFileAction = nil
        }
        notifyChanged()
        return true
    }

    var isMovingFiles: Bool { !confirmedTrashMoveTasks.isEmpty || postTrashRemovalTask != nil }

    init(
        pendingTrashSelection: PendingTrashSelection? = nil,
        pendingCloudFileAction: PendingCloudFileAction? = nil,
        discardPile: DiscardPileState = DiscardPileState()
    ) {
        self.pendingTrashSelection = pendingTrashSelection
        self.pendingCloudFileAction = pendingCloudFileAction
        self.discardPile = discardPile
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
        nodes: [FileNodeRecord.ID: FileNodeRecord],
        snapshotID: UUID?
    ) -> Bool {
        let updatedState = OptimisticTrashVisibilityState(nodes: nodes, snapshotID: snapshotID)
        guard updatedState != optimisticTrashVisibility else { return false }
        optimisticTrashVisibility = updatedState
        notifyChanged()
        return true
    }

    @discardableResult
    func clearOptimisticTrashVisibility() -> Bool {
        replaceOptimisticTrashVisibility(nodes: [:], snapshotID: nil)
    }

    func stageTrashRequest(
        for nodes: [FileNodeRecord],
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        fileTreeStore: FileTreeStore?
    ) throws {
        guard !isReadOnlyMode else { throw FileActionError.readOnlyMode }
        guard nodes.allSatisfy({
            $0.supportsMoveToTrash(activeTarget: activeTarget, trashSafetyPolicy: trashSafetyPolicy)
        }) else {
            throw FileActionError.unsupported
        }

        let trashNodes = Self.topLevelTrashNodes(from: nodes, fileTreeStore: fileTreeStore)
        pendingTrashSelection = PendingTrashSelection(nodes: trashNodes)
    }

    nonisolated static func prepareDiscardPileTrashRequest(
        nodes: [FileNodeRecord],
        trashSafetyPolicy: TrashSafetyPolicy,
        verifyIdentity: (FileNodeRecord) -> TrashIdentityVerificationResult
    ) throws -> PendingTrashSelection {
        guard !nodes.isEmpty else { throw FileActionError.noSelection }

        var unavailable: [DiscardPileTrashBatch.Unavailable] = []
        var eligible: [FileNodeRecord] = []
        for node in nodes {
            try Task.checkCancellation()
            let message: String?
            if !node.supportsMoveToTrash(trashSafetyPolicy: trashSafetyPolicy) {
                message = FileActionError.unsupported.localizedDescription
            } else {
                let result = node.fileIdentity == nil ? .missingScannedIdentity : verifyIdentity(node)
                switch result {
                case .mismatch, .missingScannedIdentity:
                    message = String(localized: "Radix can’t verify this mark. Scan the item and mark it again.")
                default:
                    message = Self.fileActionError(for: result, node: node)?.localizedDescription
                }
            }
            if let message {
                unavailable.append(.init(node: node, message: message))
            } else {
                eligible.append(node)
            }
        }

        var foldersByPath: [String: FileNodeRecord.ID] = [:]
        for folder in eligible where folder.isDirectory && !folder.isSymbolicLink {
            try Task.checkCancellation()
            let path = folder.url.resolvingSymlinksInPath().path
            if foldersByPath[path] == nil { foldersByPath[path] = folder.id }
        }
        var coveredMarks: [FileNodeRecord.ID: [FileNodeRecord]] = [:]
        let operations = try eligible.filter { node in
            try Task.checkCancellation()
            guard !foldersByPath.isEmpty else { return true }
            var parent = node.url.deletingLastPathComponent().resolvingSymlinksInPath().path
            var coveringID: FileNodeRecord.ID?
            while let separator = parent.lastIndex(of: "/"), parent != "/" {
                if let ancestor = foldersByPath[parent] { coveringID = ancestor }
                parent = String(parent[..<separator])
            }
            guard let coveringID else { return true }
            coveredMarks[coveringID, default: []].append(node)
            return false
        }
        return PendingTrashSelection(
            nodes: operations,
            discardPileBatch: DiscardPileTrashBatch(unavailable: unavailable, coveredMarks: coveredMarks)
        )
    }

    func invalidateDiscardPileHistory() {
        guard discardPileUndoManager.canUndo || discardPileUndoManager.canRedo else { return }
        discardPileUndoManager.removeAllActions()
        notifyChanged()
    }

    func replaceDiscardPile(_ state: DiscardPileState) {
        invalidateDiscardPileHistory()
        guard state != discardPile else { return }
        discardPile = state
    }

    func discardPileAdding(_ nodes: [FileNodeRecord], in snapshot: ScanSnapshot) -> DiscardPileState {
        let tree = snapshot.treeStore
        var updated = discardPile.marks
        var offsets = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.node.id, $0.offset) })
        for node in nodes {
            let mark = DiscardPileState.Mark(node: node, treeID: tree.contentID)
            guard let current = tree.node(id: node.id), mark.matches(current, treeID: tree.contentID) else { continue }
            if let offset = offsets[node.id] {
                if !updated[offset].matches(node, treeID: tree.contentID) { updated[offset] = mark }
            } else {
                offsets[node.id] = updated.count
                updated.append(mark)
            }
        }

        let incomingIDs = Set(nodes.map(\.id))
        let matchingIDs = DiscardPileState(marks: updated).matchingNodeIDs(in: snapshot)
        return DiscardPileState(marks: updated.filter { mark in
            guard matchingIDs.contains(mark.node.id) else { return true }
            var parent = tree.parent(of: mark.node.id)
            while let ancestor = parent {
                if matchingIDs.contains(ancestor.id),
                   let offset = offsets[ancestor.id],
                   ancestor.isDirectory, !ancestor.isSymbolicLink,
                   incomingIDs.contains(ancestor.id) || incomingIDs.contains(mark.node.id),
                   updated[offset].node.fileIdentity != nil || mark.node.fileIdentity == nil {
                    return false
                }
                parent = tree.parent(of: ancestor.id)
            }
            return true
        })
    }

    func removeMovedDiscardPileNodes(
        _ movedNodes: [FileNodeRecord],
        batch: DiscardPileTrashBatch?,
        from originalSnapshot: ScanSnapshot?
    ) {
        guard !discardPile.isEmpty else { return }
        let removed = movedNodes + movedNodes.flatMap { batch?.coveredMarks[$0.id] ?? [] }
        let removedByID = Dictionary(removed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = originalSnapshot?.treeStore
        let movedFolders = movedNodes.filter { $0.isDirectory && !$0.isSymbolicLink }
        let matchedFolders = movedFolders.filter { folder in
            tree?.node(id: folder.id)?.fileIdentity == folder.fileIdentity
        }
        let removedSubtrees = tree?.preparedNodeSet(for: Set(matchedFolders.map(\.id)))

        let remaining = discardPile.marks.filter { mark in
            if let node = removedByID[mark.node.id] {
                return mark.node.fileIdentity != node.fileIdentity
                    || (node.fileIdentity == nil && mark.unidentifiedTreeID != tree?.contentID)
            }
            guard batch == nil, let tree, let removedSubtrees,
                  tree.isNodeOrDescendant(mark.node.id, of: removedSubtrees),
                  let original = tree.node(id: mark.node.id) else { return true }
            return !mark.matches(original, treeID: tree.contentID)
        }
        if remaining != discardPile.marks { replaceDiscardPile(DiscardPileState(marks: remaining)) }
    }

    func changeDiscardPile(_ state: DiscardPileState, actionName: String) {
        guard state != discardPile else { return }
        let previous = discardPile
        let isReplaying = discardPileUndoManager.isUndoing || discardPileUndoManager.isRedoing
        if !isReplaying { discardPileUndoManager.beginUndoGrouping() }
        discardPileUndoManager.registerUndo(withTarget: self) { controller in
            controller.changeDiscardPile(previous, actionName: actionName)
        }
        discardPileUndoManager.setActionName(actionName)
        if !isReplaying { discardPileUndoManager.endUndoGrouping() }
        discardPile = state
        if isReplaying { onDiscardPileHistoryReplay?(state) }
    }

    func removeDiscardPileNodes(ids nodeIDs: Set<FileNodeRecord.ID>) {
        guard !nodeIDs.isEmpty else { return }
        let remaining = discardPile.marks.filter { !nodeIDs.contains($0.node.id) }
        changeDiscardPile(
            DiscardPileState(marks: remaining),
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

    nonisolated static func fileActionError(
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

        let matched = nodes.compactMap { node -> FileNodeRecord? in
            guard let current = activeFileTreeStore.node(id: node.id),
                  DiscardPileState.Mark.matchesIdentity(of: node, with: current) else { return nil }
            return current
        }
        let nodeIDs = Set(activeFileTreeStore.topLevelNodeIDs(from: matched.map(\.id)))
        guard !nodeIDs.isEmpty else { return false }

        var hiddenNodes = optimisticTrashVisibility.snapshotID == snapshotID
            ? optimisticTrashVisibility.nodes
            : [:]
        for node in matched where nodeIDs.contains(node.id) {
            hiddenNodes[node.id] = node
        }
        replaceOptimisticTrashVisibility(nodes: hiddenNodes, snapshotID: snapshotID)
        return true
    }

    func unhideTrashNodesAfterFailedMove(
        requestedNodes: [FileNodeRecord],
        movedNodes: [FileNodeRecord],
        snapshotID: UUID?
    ) {
        let movedNodeIDs = Set(movedNodes.map(\.id))
        let unmovedNodeIDs = Set(requestedNodes.map(\.id)).subtracting(movedNodeIDs)
        unhideTrashNodes(unmovedNodeIDs, snapshotID: snapshotID)
    }

    func unhideTrashNodes(_ nodeIDs: Set<FileNodeRecord.ID>, snapshotID: UUID?) {
        guard !nodeIDs.isEmpty, let snapshotID,
              optimisticTrashVisibility.snapshotID == snapshotID else { return }
        replaceOptimisticTrashVisibility(
            nodes: optimisticTrashVisibility.nodes.filter { !nodeIDs.contains($0.key) },
            snapshotID: snapshotID
        )
    }

    func startConfirmedMove(
        _ nodes: [FileNodeRecord],
        moveToTrash: @escaping @MainActor (FileNodeRecord) async throws -> TrashIdentityVerificationResult,
        beginMove: () -> Void,
        onFinish: @escaping @MainActor (_ requested: [FileNodeRecord], _ moved: [FileNodeRecord], _ actionError: Error?, _ wasCancelled: Bool) -> Void
    ) {
        guard !isReadOnlyMode else {
            onFinish(nodes, [], FileActionError.readOnlyMode, false)
            return
        }
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
            guard !Task.isCancelled else { return }
            self?.postTrashRemovalTask = nil
        }
    }

    private func notifyChanged() {
        onChange?()
    }
}
