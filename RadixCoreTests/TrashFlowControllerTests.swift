import Foundation
import Testing

@testable import RadixCore

@MainActor
struct TrashFlowControllerTests {
    @Test
    func testDiscardPileRemovalAndClearRestoreExactOrderedBatches() {
        let snapshotID = UUID()
        let original = DiscardPileState(nodeIDs: ["first", "second", "third"], snapshotID: snapshotID)
        let controller = TrashFlowController(discardPile: original)
        controller.removeDiscardPileNodes(ids: ["first", "third"])
        #expect(controller.discardPile.nodeIDs == ["second"])
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile == original)
        controller.discardPileUndoManager.redo()
        #expect(controller.discardPile.nodeIDs == ["second"])
        controller.clearDiscardPile()
        #expect(controller.discardPile.isEmpty)
        #expect(controller.discardPile.snapshotID == nil)
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile == DiscardPileState(nodeIDs: ["second"], snapshotID: snapshotID))
        controller.discardPileUndoManager.redo()
        #expect(controller.discardPile.isEmpty)
    }

    @Test
    func testNoOpEditsKeepRedoAndNewEditReplacesIt() {
        let snapshotID = UUID()
        let controller = TrashFlowController()
        controller.synchronizeDiscardPileContext(snapshotID: snapshotID, treeContentID: UUID())
        let first = DiscardPileState(nodeIDs: ["first"], snapshotID: snapshotID)
        controller.changeDiscardPile(first, actionName: "Add")
        controller.changeDiscardPile(first, actionName: "Duplicate")
        controller.removeDiscardPileNodes(ids: ["unknown"])
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile.isEmpty)
        #expect(!(controller.discardPileUndoManager.canUndo))
        #expect(controller.discardPileUndoManager.canRedo)
        controller.clearDiscardPile()
        controller.removeDiscardPileNodes(ids: [])
        #expect(controller.discardPileUndoManager.canRedo)
        controller.changeDiscardPile(
            DiscardPileState(nodeIDs: ["second"], snapshotID: snapshotID), actionName: "Add"
        )
        #expect(!(controller.discardPileUndoManager.canRedo))
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile.isEmpty)
    }

    @Test
    func testDiscardPileHistoryIsBoundedToFiftyUserEdits() {
        let snapshotID = UUID()
        let controller = TrashFlowController()
        controller.synchronizeDiscardPileContext(snapshotID: snapshotID, treeContentID: UUID())
        for count in 1...60 {
            controller.changeDiscardPile(
                DiscardPileState(nodeIDs: (1...count).map(String.init), snapshotID: snapshotID),
                actionName: "Add"
            )
        }
        var undoCount = 0
        while controller.discardPileUndoManager.canUndo {
            controller.discardPileUndoManager.undo()
            undoCount += 1
        }
        #expect(undoCount == 50)
        #expect(controller.discardPile.nodeIDs.count == 10)
        for _ in 0..<50 { controller.discardPileUndoManager.redo() }
        #expect(controller.discardPile.nodeIDs.count == 60)
    }

    @Test
    func testProgrammaticAndEmptyPileContextReplacementsInvalidateHistory() {
        let snapshotID = UUID()
        let contentID = UUID()
        let original = DiscardPileState(nodeIDs: ["first"], snapshotID: snapshotID)
        let controller = TrashFlowController()
        controller.synchronizeDiscardPileContext(snapshotID: snapshotID, treeContentID: contentID)
        controller.changeDiscardPile(original, actionName: "Add")
        controller.clearDiscardPile()
        controller.synchronizeDiscardPileContext(snapshotID: snapshotID, treeContentID: contentID)
        #expect(controller.discardPileUndoManager.canUndo)
        controller.synchronizeDiscardPileContext(snapshotID: UUID(), treeContentID: UUID())
        #expect(!(controller.discardPileUndoManager.canUndo))
        #expect(!(controller.discardPileUndoManager.canRedo))
        controller.synchronizeDiscardPileContext(snapshotID: snapshotID, treeContentID: contentID)
        controller.changeDiscardPile(original, actionName: "Add")
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPileUndoManager.canRedo)
        controller.replaceDiscardPile(DiscardPileState())
        #expect(!(controller.discardPileUndoManager.canRedo))
    }

    @Test
    func testReleasingControllerCancelsEveryConfirmedBatch() async throws {
        var controller: TrashFlowController? = TrashFlowController()
        var continuations: [CheckedContinuation<Void, Never>] = []
        var attemptedIDs: [String] = []
        var finishedCount = 0

        for batch in 0..<2 {
            let first = makeTestFileNode(id: "/batch-\(batch)/first", name: "first")
            let second = makeTestFileNode(id: "/batch-\(batch)/second", name: "second")
            controller?.startConfirmedMove(
                [first, second],
                moveToTrash: { node in
                    attemptedIDs.append(node.id)
                    await withCheckedContinuation { continuations.append($0) }
                    return .matches
                },
                beginMove: {},
                onFinish: { requested, moved, error, wasCancelled in
                    #expect(requested == [first, second])
                    #expect(moved == [first])
                    #expect(error == nil)
                    #expect(wasCancelled)
                    finishedCount += 1
                }
            )
        }
        try await waitUntil("both batches enter their first move") { continuations.count == 2 }
        controller = nil
        for continuation in continuations { continuation.resume() }

        try await waitUntil("both cancelled batches finish") { finishedCount == 2 }
        #expect(attemptedIDs.sorted() == ["/batch-0/first", "/batch-1/first"])
    }

    @Test
    func testCancellationBeforeTaskStartsDoesNotMoveFiles() async throws {
        let controller = TrashFlowController()
        let node = makeTestFileNode(id: "/file", name: "file")
        var didFinish = false
        controller.startConfirmedMove(
            [node],
            moveToTrash: { _ in
                Issue.record("A cancelled batch must not start a filesystem move")
                return .matches
            },
            beginMove: { controller.cancelConfirmedTrashMoves() },
            onFinish: { _, moved, error, wasCancelled in
                #expect(moved.isEmpty)
                #expect(error == nil)
                #expect(wasCancelled)
                didFinish = true
            }
        )

        try await waitUntil("cancelled batch reports its outcome") { didFinish }
    }

    @Test
    func testCancelledRemovalWorkerCannotDisturbReplacementQueue() async throws {
        let controller = TrashFlowController()
        var oldContinuation: CheckedContinuation<Void, Never>?
        var newContinuation: CheckedContinuation<Void, Never>?
        var events: [String] = []
        controller.enqueuePostTrashSnapshotRemoval {
            events.append("old started")
            await withCheckedContinuation { oldContinuation = $0 }
            events.append("old returned")
        }
        controller.enqueuePostTrashSnapshotRemoval {
            Issue.record("Cancellation must discard queued removal requests")
        }
        try await waitUntil("old removal starts") { oldContinuation != nil }
        controller.cancelPostTrashSnapshotRemoval()

        controller.enqueuePostTrashSnapshotRemoval {
            events.append("new started")
            await withCheckedContinuation { newContinuation = $0 }
            events.append("new returned")
        }
        controller.enqueuePostTrashSnapshotRemoval { events.append("next") }
        try await waitUntil("replacement removal starts") { newContinuation != nil }
        oldContinuation?.resume()
        try await waitUntil("cancelled removal returns") { events.contains("old returned") }
        controller.enqueuePostTrashSnapshotRemoval { events.append("last") }
        newContinuation?.resume()

        try await waitUntil("replacement queue drains") { events.contains("last") }
        #expect(events == ["old started", "new started", "old returned", "new returned", "next", "last"])
    }
}
