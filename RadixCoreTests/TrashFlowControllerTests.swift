import XCTest
@testable import RadixCore

@MainActor
final class TrashFlowControllerTests: XCTestCase {
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
                    XCTAssertEqual(requested, [first, second])
                    XCTAssertEqual(moved, [first])
                    XCTAssertNil(error)
                    XCTAssertTrue(wasCancelled)
                    finishedCount += 1
                }
            )
        }
        try await waitUntil("both batches enter their first move") { continuations.count == 2 }
        controller = nil
        for continuation in continuations { continuation.resume() }

        try await waitUntil("both cancelled batches finish") { finishedCount == 2 }
        XCTAssertEqual(attemptedIDs.sorted(), ["/batch-0/first", "/batch-1/first"])
    }

    func testCancellationBeforeTaskStartsDoesNotMoveFiles() async throws {
        let controller = TrashFlowController()
        let node = makeTestFileNode(id: "/file", name: "file")
        var didFinish = false
        controller.startConfirmedMove(
            [node],
            moveToTrash: { _ in
                XCTFail("A cancelled batch must not start a filesystem move")
                return .matches
            },
            beginMove: { controller.cancelConfirmedTrashMoves() },
            onFinish: { _, moved, error, wasCancelled in
                XCTAssertTrue(moved.isEmpty)
                XCTAssertNil(error)
                XCTAssertTrue(wasCancelled)
                didFinish = true
            }
        )

        try await waitUntil("cancelled batch reports its outcome") { didFinish }
    }

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
            XCTFail("Cancellation must discard queued removal requests")
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
        XCTAssertEqual(events, ["old started", "new started", "old returned", "new returned", "next", "last"])
    }
}
