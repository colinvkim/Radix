import AppKit
import CoreTransferable
import UniformTypeIdentifiers

struct DiscardPileDragPayload: Codable, Hashable, Transferable {
    static let contentType = UTType(exportedAs: "dev.colinkim.radix.discard-pile-drag-payload")
    let snapshotID: UUID
    let nodeIDs: [FileNodeRecord.ID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

/// One preparation per gesture, shared by the table and both disk maps.
@MainActor
final class FileDragController {
    struct Context {
        let snapshot: ScanSnapshot
        let target: ScanTarget?
        let trashSafetyPolicy: TrashSafetyPolicy
    }

    private let context: () -> Context?
    private let verifyIdentity: (FileNodeRecord) -> TrashIdentityVerificationResult
    private let refresh: (UUID) -> Void
    private weak var activeSession: FileDragSession?

    init(
        context: @escaping () -> Context?,
        verifyIdentity: @escaping (FileNodeRecord) -> TrashIdentityVerificationResult,
        refresh: @escaping (UUID) -> Void
    ) {
        self.context = context
        self.verifyIdentity = verifyIdentity
        self.refresh = refresh
    }

    var isDragging: Bool { activeSession != nil }

    func prepare(nodeIDs: [FileNodeRecord.ID]) -> FileDragSession? {
        guard let context = context(), context.snapshot.isComplete,
              context.snapshot.source.allowsFileMutation, !nodeIDs.isEmpty else { return nil }
        let tree = context.snapshot.treeStore
        let nodes = tree.topLevelNodeIDs(from: nodeIDs).compactMap { tree.node(id: $0) }
        guard !nodes.isEmpty, nodes.allSatisfy(\.supportsFileActions),
              nodeIDs.allSatisfy({ tree.node(id: $0) != nil }) else { return nil }

        let canCollect = nodes.allSatisfy {
            $0.supportsMoveToTrash(activeTarget: context.target, trashSafetyPolicy: context.trashSafetyPolicy)
        }
        // A stale item still supports the existing internal review workflow, but
        // must never be handed to another app under its old scanned identity.
        let exportsURLs = nodes.allSatisfy { verifyIdentity($0) == .matches }
        guard canCollect || exportsURLs else { return nil }
        return FileDragSession(
            snapshotID: context.snapshot.id, nodes: nodes,
            canCollect: canCollect, exportsURLs: exportsURLs,
            onBegin: { [weak self] session in self?.activeSession = session },
            onEnd: { [weak self] session, operation in
                guard let self, activeSession === session else { return }
                activeSession = nil
                if !session.wasDroppedInternally, session.exportsURLs, !operation.isEmpty {
                    refresh(session.snapshotID)
                }
            }
        )
    }

    func markInternalDrop() { activeSession?.wasDroppedInternally = true }
}

@MainActor
final class FileDragSession {
    let snapshotID: UUID
    let nodes: [FileNodeRecord]
    let canCollect: Bool
    let exportsURLs: Bool
    fileprivate var wasDroppedInternally = false
    private let nodesByID: [FileNodeRecord.ID: FileNodeRecord]
    private let onBegin: (FileDragSession) -> Void
    private let onEnd: (FileDragSession, NSDragOperation) -> Void

    init(
        snapshotID: UUID, nodes: [FileNodeRecord], canCollect: Bool, exportsURLs: Bool,
        onBegin: @escaping (FileDragSession) -> Void,
        onEnd: @escaping (FileDragSession, NSDragOperation) -> Void
    ) {
        self.snapshotID = snapshotID
        self.nodes = nodes
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.canCollect = canCollect
        self.exportsURLs = exportsURLs
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    func pasteboardWriter(for nodeID: FileNodeRecord.ID) -> NSPasteboardItem? {
        guard let node = nodesByID[nodeID] else { return nil }
        let item = NSPasteboardItem()
        if canCollect,
           let data = try? JSONEncoder().encode(DiscardPileDragPayload(snapshotID: snapshotID, nodeIDs: [nodeID])) {
            item.setData(data, forType: NSPasteboard.PasteboardType(DiscardPileDragPayload.contentType.identifier))
        }
        if exportsURLs {
            item.setString(node.url.absoluteString, forType: .fileURL)
        }
        return item
    }

    func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return canCollect ? .copy : [] }
        guard exportsURLs else { return [] }
        // Protected roots can be opened/copied externally, never moved.
        return canCollect ? [.copy, .move, .generic] : .copy
    }

    func begin() { onBegin(self) }
    func end(operation: NSDragOperation) { onEnd(self, operation) }
}
