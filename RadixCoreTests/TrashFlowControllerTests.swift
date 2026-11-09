import Foundation
import Testing

@testable import RadixCore

@MainActor
struct TrashFlowControllerTests {
    @Test(arguments: [false, true])
    func testDiscardPileProjectsAcrossEnumeratorsOnlyForTheOriginalFile(replaced: Bool) throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fileURL = fixture.appending(path: "marked.txt")
        try Data([1]).write(to: fileURL)
        let loader = ScanMetadataLoader()
        let bulkResult = try BulkDirectoryEnumerator.directoryEntries(
            at: fixture, includeHiddenFiles: false, metadataLoader: loader, cancellationCheck: {}
        )
        let bulk = try #require(bulkResult)
        let nativeIdentity = try #require(bulk.entries.first?.metadata?.fileIdentity)
        if replaced {
            try FileManager.default.moveItem(at: fileURL, to: fixture.appending(path: "original.txt"))
            try Data([2]).write(to: fileURL)
        }
        let metadata = try loader.metadata(for: fileURL)
        let foundationIdentity = try #require(metadata.fileIdentity)
        let nativeNode = makeTestFileNode(id: fileURL.path, name: "marked.txt", fileIdentity: nativeIdentity)
        let foundationNode = makeTestFileNode(id: fileURL.path, name: "marked.txt", fileIdentity: foundationIdentity)
        #expect(SystemIntegration.verifyTrashIdentity(nativeNode) == (replaced ? .mismatch : .matches))
        #expect(SystemIntegration.verifyTrashIdentity(foundationNode) == .matches)
        try #require(nativeIdentity != foundationIdentity)

        func snapshot(_ node: FileNodeRecord) -> ScanSnapshot {
            let root = makeTestDirectoryNode(id: fixture.path, name: "fixture", children: [node])
            return makeTestSnapshot(root: root, store: FileTreeStore(root: root, childrenByID: [root.id: [node]]))
        }
        let initial = snapshot(nativeNode)
        let controller = TrashFlowController()
        controller.changeDiscardPile(controller.discardPileAdding([nativeNode], in: initial).pile, actionName: "Add")
        let refreshed = snapshot(foundationNode)

        #expect(controller.discardPile.matchingNodeIDs(in: refreshed) == (replaced ? [] : [nativeNode.id]))
        #expect(controller.discardPile.nodes == [nativeNode])
        let preview = try TrashFlowController.prepareDiscardPileTrashRequest(
            nodes: controller.discardPile.nodes, trashSafetyPolicy: .live(),
            verifyIdentity: SystemIntegration.verifyTrashIdentity
        )
        #expect(preview.nodes == (replaced ? [] : [nativeNode]))
        #expect(preview.discardPileBatch?.unavailable.map(\.node) == (replaced ? [nativeNode] : []))
    }

    @Test
    func testDiscardPileBatchDeduplicatesAliasesAndKeepsDistinctDirectoryEntries() throws {
        let fixture = try makeTemporaryDirectory()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: fixture) }
        let folder = fixture.appending(path: "folder", directoryHint: .isDirectory)
        let aliasFolder = fixture.appending(path: "alias", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: aliasFolder, withDestinationURL: folder)
        let file = folder.appending(path: "marked.txt")
        let hardLink = folder.appending(path: "hard-link.txt")
        let symlink = folder.appending(path: "symlink.txt")
        try Data([1]).write(to: file)
        try manager.linkItem(at: file, to: hardLink)
        try manager.createSymbolicLink(at: symlink, withDestinationURL: file)

        let loader = ScanMetadataLoader()
        func node(at url: URL, isSymbolicLink: Bool = false) throws -> FileNodeRecord {
            makeTestFileNode(
                id: url.path,
                name: url.lastPathComponent,
                fileIdentity: try loader.fileSystemIdentity(at: url),
                isSymbolicLink: isSymbolicLink
            )
        }
        let original = try node(at: file)
        let alias = try node(at: aliasFolder.appending(path: file.lastPathComponent))
        let distinctEntries = try [node(at: hardLink), node(at: symlink, isSymbolicLink: true)]
        try #require(original.fileIdentity == alias.fileIdentity)
        try #require(original.fileIdentity == distinctEntries[0].fileIdentity)
        let marks = [original, alias] + distinctEntries
        let controller = TrashFlowController(discardPile: DiscardPileState(marks: marks.map { .init(node: $0) }))

        let preview = try TrashFlowController.prepareDiscardPileTrashRequest(
            nodes: marks, trashSafetyPolicy: .live(), verifyIdentity: SystemIntegration.verifyTrashIdentity
        )
        #expect(preview.nodes == [original] + distinctEntries)
        #expect(preview.discardPileBatch?.unavailable.isEmpty == true)
        controller.removeMovedDiscardPileNodes([original], batch: preview.discardPileBatch, from: nil)
        #expect(controller.discardPile.nodes == distinctEntries)
    }

    @Test
    func testDiscardPileBatchCollapsesVerifiedDescendantsAndRetainsUnavailableMarks() throws {
        let identity = FileIdentity(device: 1, inode: 1)
        let folder = makeTestDirectoryNode(id: "/scope/folder", name: "folder", children: [], fileIdentity: identity)
        let child = makeTestFileNode(
            id: "/scope/folder/deep/file", name: "file", fileIdentity: FileIdentity(device: 1, inode: 2)
        )
        let unavailable = makeTestFileNode(
            id: "/scope/folder/deep/missing", name: "missing", fileIdentity: FileIdentity(device: 1, inode: 3)
        )
        let sibling = makeTestFileNode(
            id: "/scope/folder-other/file", name: "file", fileIdentity: FileIdentity(device: 1, inode: 4)
        )
        let controller = TrashFlowController(
            discardPile: DiscardPileState(marks: [child, folder, unavailable, sibling].map { .init(node: $0) })
        )

        let preview = try TrashFlowController.prepareDiscardPileTrashRequest(
            nodes: controller.discardPile.nodes, trashSafetyPolicy: .live()
        ) {
            $0 == unavailable ? .missingCurrentItem : .matches
        }
        #expect(preview.nodes == [folder, sibling])
        #expect(preview.discardPileBatch?.unavailable.map(\.node) == [unavailable])
        controller.removeMovedDiscardPileNodes([folder], batch: preview.discardPileBatch, from: nil)
        #expect(controller.discardPile.nodes == [unavailable, sibling])
    }

    @Test
    func testDiscardPileRemovalAndClearRestoreExactOrderedBatches() {
        let original = makePile(["first", "second", "third"])
        let controller = TrashFlowController(discardPile: original)
        controller.removeDiscardPileNodes(ids: ["/first", "/third"])
        #expect(controller.discardPile == makePile(["second"]))
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile == original)
        controller.discardPileUndoManager.redo()
        #expect(controller.discardPile == makePile(["second"]))
        controller.clearDiscardPile()
        #expect(controller.discardPile.isEmpty)
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile == makePile(["second"]))
        controller.discardPileUndoManager.redo()
        #expect(controller.discardPile.isEmpty)
    }

    @Test
    func testCompletedDirectTrashMovePrunesOnlyMovedItems() {
        let child = makeTestFileNode(id: "/selection/folder/child", name: "child")
        let folder = makeTestDirectoryNode(id: "/selection/folder", name: "folder", children: [child])
        let kept = makeTestFileNode(id: "/selection/kept", name: "kept")
        let root = makeTestDirectoryNode(id: "/selection", name: "selection", children: [folder, kept])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [folder, kept], folder.id: [child]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let controller = TrashFlowController()
        controller.changeDiscardPile(controller.discardPileAdding([child, kept], in: snapshot).pile, actionName: "Add")

        controller.removeMovedDiscardPileNodes([folder], batch: nil, from: snapshot)

        #expect(controller.discardPile.nodeIDs == [kept.id])
    }

    @Test
    func testNoOpEditsKeepRedoAndNewEditReplacesIt() {
        let controller = TrashFlowController()
        let first = makePile(["first"])
        controller.changeDiscardPile(first, actionName: "Add")
        controller.changeDiscardPile(first, actionName: "Duplicate")
        controller.removeDiscardPileNodes(ids: ["/unknown"])
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile.isEmpty)
        #expect(!(controller.discardPileUndoManager.canUndo))
        #expect(controller.discardPileUndoManager.canRedo)
        controller.clearDiscardPile()
        controller.removeDiscardPileNodes(ids: [])
        #expect(controller.discardPileUndoManager.canRedo)
        controller.changeDiscardPile(makePile(["second"]), actionName: "Add")
        #expect(!(controller.discardPileUndoManager.canRedo))
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPile.isEmpty)
    }

    @Test
    func testDiscardPileHistoryIsBoundedToFiftyUserEdits() {
        let controller = TrashFlowController()
        for count in 1...60 {
            controller.changeDiscardPile(makePile((1...count).map(String.init)), actionName: "Add")
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
    func testProgrammaticPileReplacementInvalidatesHistory() {
        let controller = TrashFlowController()
        controller.changeDiscardPile(makePile(["first"]), actionName: "Add")
        controller.discardPileUndoManager.undo()
        #expect(controller.discardPileUndoManager.canRedo)
        controller.replaceDiscardPile(DiscardPileState())
        #expect(!(controller.discardPileUndoManager.canRedo))
    }

    private func makePile(_ names: [String]) -> DiscardPileState {
        DiscardPileState(marks: names.map {
            .init(node: makeTestFileNode(id: "/" + $0, name: $0))
        })
    }

    @Test
    func testReadOnlyModeRejectsDirectTrashRequestsAndConfirmedMoves() throws {
        let controller = TrashFlowController()
        let node = makeTestFileNode(id: "/selection/file", name: "file")
        #expect(controller.setReadOnlyMode(true))
        #expect(throws: FileActionError.self) {
            try controller.stageTrashRequest(for: [node], activeTarget: nil,
                trashSafetyPolicy: .live(), fileTreeStore: nil)
        }
        #expect(controller.pendingTrashSelection == nil)
        var didFinish = false
        controller.startConfirmedMove([node], moveToTrash: { _ in
            Issue.record("Read-only mode must prevent filesystem moves")
            return .matches
        }, beginMove: {
            Issue.record("Rejected moves must not hide scan results")
        }, onFinish: { _, moved, error, wasCancelled in
            #expect(moved.isEmpty)
            #expect(!wasCancelled)
            if case .readOnlyMode? = error as? FileActionError {} else {
                Issue.record("Expected the read-only mode error")
            }
            didFinish = true
        })
        #expect(didFinish)
        #expect(!controller.isMovingFiles)
    }

    @Test
    func testReadOnlyModeCannotChangeDuringTrashMove() async throws {
        let controller = TrashFlowController()
        let node = makeTestFileNode(id: "/selection/file", name: "file")
        var continuation: CheckedContinuation<Void, Never>?
        var didFinish = false
        controller.startConfirmedMove([node], moveToTrash: { _ in
            await withCheckedContinuation { continuation = $0 }
            return .matches
        }, beginMove: {}, onFinish: { _, _, _, _ in didFinish = true })
        #expect(!controller.setReadOnlyMode(true))
        try await waitUntil("move starts") { continuation != nil }
        #expect(!controller.setReadOnlyMode(true))
        #expect(!controller.isReadOnlyMode)
        continuation?.resume()
        try await waitUntil("move finishes") { didFinish }
        #expect(controller.setReadOnlyMode(true))
        #expect(controller.isReadOnlyMode)
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
