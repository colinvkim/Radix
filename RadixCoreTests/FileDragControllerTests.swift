import AppKit
import Testing
@testable import RadixCore

@MainActor
struct FileDragControllerTests {
    @Test
    func gestureEligibilityDoesNotValidateIdentitiesOrPrepareSessions() throws {
        let snapshot = fixture()
        var verificationCount = 0
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { _ in verificationCount += 1; return .matches }, refresh: { _ in }
        )
        let nodeID = snapshot.root.id + "/Folder"
        for _ in 0..<4 { #expect(controller.canAttemptDrag(nodeID: nodeID)) }
        #expect(!controller.canAttemptDrag(nodeID: "/missing"))
        #expect(!controller.canAttemptDrag(nodeID: snapshot.root.id + "/synthetic"))
        #expect(verificationCount == 0)
        #expect(!controller.isDragging)

        let session = try #require(controller.prepare(nodeIDs: [nodeID]))
        #expect(verificationCount == 1)
        session.begin()
        #expect(controller.isDragging)
        session.end(operation: [])
    }

    @Test
    func nativeItemsPreserveInternalPayloadAndOriginalURLs() throws {
        let snapshot = fixture()
        var verified: [String] = []
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { verified.append($0.id); return .matches }, refresh: { _ in }
        )
        let folderID = snapshot.root.id + "/Folder"
        let childID = folderID + "/a space ☃.txt"
        let session = try #require(controller.prepare(nodeIDs: [childID, folderID, folderID]))
        #expect(session.nodes.map(\.id) == [folderID])
        #expect(verified == [folderID])
        #expect(session.pasteboardWriter(for: childID) == nil)
        let writer = try #require(session.pasteboardWriter(for: folderID))
        #expect(writer.string(forType: .fileURL) == URL(filePath: folderID, directoryHint: .isDirectory).absoluteString)
        let data = try #require(writer.data(forType: .init(DiscardPileDragPayload.contentType.identifier)))
        let payload = try JSONDecoder().decode(DiscardPileDragPayload.self, from: data)
        #expect(payload.snapshotID == snapshot.id)
        #expect(payload.nodeIDs == [folderID])
        #expect(session.operationMask(for: .withinApplication) == .copy)
        #expect(session.operationMask(for: .outsideApplication).contains(.move))
    }

    @Test(arguments: [false, true])
    func multipleFilesExportOneURLPerItemAndRejectPartialValidation(stale: Bool) throws {
        let snapshot = fixture()
        let childID = snapshot.root.id + "/Folder/a space ☃.txt"
        let siblingID = snapshot.root.id + "/other.txt"
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { stale && $0.id == siblingID ? .mismatch : .matches }, refresh: { _ in }
        )
        let session = try #require(controller.prepare(nodeIDs: [childID, siblingID]))
        #expect(session.nodes.map(\.id) == [childID, siblingID])
        for id in [childID, siblingID] {
            let writer = try #require(session.pasteboardWriter(for: id))
            #expect(writer.string(forType: .fileURL) == (stale ? nil : URL(filePath: id).absoluteString))
            let data = try #require(writer.data(forType: .init(DiscardPileDragPayload.contentType.identifier)))
            #expect(try JSONDecoder().decode(DiscardPileDragPayload.self, from: data).nodeIDs == [id])
        }
    }

    @Test(arguments: [TrashIdentityVerificationResult.mismatch, .missingCurrentItem, .missingScannedIdentity, .metadataUnavailable("denied")])
    func staleItemsRemainInternalOnly(result: TrashIdentityVerificationResult) throws {
        let snapshot = fixture()
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { _ in result }, refresh: { _ in Issue.record("Internal items must not trigger a refresh") }
        )
        let session = try #require(controller.prepare(nodeIDs: [snapshot.root.id + "/Folder"]))
        let writer = try #require(session.pasteboardWriter(for: session.nodes[0].id))
        #expect(writer.string(forType: .fileURL) == nil)
        #expect(writer.data(forType: .init(DiscardPileDragPayload.contentType.identifier)) != nil)
        #expect(session.operationMask(for: .outsideApplication).isEmpty)
        session.begin()
        session.end(operation: .copy)
    }

    @Test
    func protectedLocationsExportOnlyCopyWithoutCollectorPayload() throws {
        let snapshot = fixture(path: "/Applications")
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { _ in .matches }, refresh: { _ in }
        )
        let session = try #require(controller.prepare(nodeIDs: [snapshot.root.id]))
        let writer = try #require(session.pasteboardWriter(for: snapshot.root.id))
        #expect(writer.string(forType: .fileURL) != nil)
        #expect(writer.data(forType: .init(DiscardPileDragPayload.contentType.identifier)) == nil)
        #expect(session.operationMask(for: .outsideApplication) == .copy)
        #expect(session.operationMask(for: .withinApplication).isEmpty)
    }

    @Test(arguments: [false, true])
    func readOnlyModeAllowsOnlyValidatedExternalCopies(stale: Bool) throws {
        let snapshot = fixture()
        let controller = FileDragController(
            context: {
                .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live(), isReadOnlyMode: true)
            },
            verifyIdentity: { _ in stale ? .mismatch : .matches }, refresh: { _ in }
        )
        let nodeID = snapshot.root.id + "/Folder"
        #expect(controller.canAttemptDrag(nodeID: nodeID))
        if stale {
            #expect(controller.prepare(nodeIDs: [nodeID]) == nil)
        } else {
            let session = try #require(controller.prepare(nodeIDs: [nodeID]))
            let writer = try #require(session.pasteboardWriter(for: nodeID))
            #expect(writer.string(forType: .fileURL) != nil)
            #expect(writer.data(forType: .init(DiscardPileDragPayload.contentType.identifier)) == nil)
            #expect(session.operationMask(for: .outsideApplication) == .copy)
            #expect(session.operationMask(for: .withinApplication).isEmpty)
        }
    }

    @Test
    func cancelledAndInternalDropsDoNotRefreshButExternalDropsRefreshOnce() throws {
        let snapshot = fixture()
        var refreshed: [FileTransfer] = []
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { _ in .matches }, refresh: { refreshed.append($0) }
        )
        let ids = [snapshot.root.id + "/Folder"]
        let cancelled = try #require(controller.prepare(nodeIDs: ids))
        cancelled.begin()
        #expect(controller.isDragging)
        cancelled.end(operation: [])
        #expect(!controller.isDragging)
        let internalDrop = try #require(controller.prepare(nodeIDs: ids))
        internalDrop.begin()
        controller.markInternalDrop()
        internalDrop.end(operation: .copy)
        #expect(refreshed.isEmpty)
        let external = try #require(controller.prepare(nodeIDs: ids))
        external.begin()
        external.end(operation: .move)
        external.end(operation: .move)
        #expect(refreshed.map { $0.snapshot.id } == [snapshot.id])
        #expect(refreshed.first?.nodes.map(\.id) == ids)
        #expect(refreshed.first?.sourceDirectoryPaths == [snapshot.root.id])
        #expect(refreshed.first?.operation == .move)
    }

    @Test
    func importedSyntheticAndUnknownNodesNeverExport() {
        let live = fixture()
        var snapshot = live
        let controller = FileDragController(
            context: { .init(snapshot: snapshot, target: snapshot.target, trashSafetyPolicy: .live()) },
            verifyIdentity: { _ in Issue.record("Rejected nodes must not access the filesystem"); return .matches },
            refresh: { _ in }
        )
        #expect(controller.prepare(nodeIDs: ["/missing"]) == nil)
        #expect(controller.prepare(nodeIDs: [live.root.id + "/synthetic"]) == nil)
        snapshot = ScanSnapshot(
            target: live.target, treeStore: live.treeStore, startedAt: live.startedAt, finishedAt: live.finishedAt,
            scanWarnings: [], isComplete: true,
            source: .imported(.init(sourceURL: URL(filePath: "/saved.radixscan"), pathMode: .absolute, liveActionCapability: .pathValidation))
        )
        #expect(!controller.canAttemptDrag(nodeID: live.root.id))
        #expect(controller.prepare(nodeIDs: [live.root.id]) == nil)
    }

    private func fixture(path: String = "/drag-fixture") -> ScanSnapshot {
        let child = makeTestFileNode(id: path + "/Folder/a space ☃.txt", name: "a space ☃.txt")
        let folder = makeTestDirectoryNode(id: path + "/Folder", name: "Folder", children: [child])
        let synthetic = makeTestFileNode(id: path + "/synthetic", name: "System", isSynthetic: true)
        let sibling = makeTestFileNode(id: path + "/other.txt", name: "other.txt")
        let root = makeTestDirectoryNode(id: path, name: "Root", children: [folder, sibling, synthetic])
        return ScanSnapshot(
            target: ScanTarget(url: root.url, kind: .folder),
            treeStore: FileTreeStore(root: root, childrenByID: [root.id: [folder, sibling, synthetic], folder.id: [child]]),
            startedAt: Date(), finishedAt: Date(), scanWarnings: [], isComplete: true, scanOptions: ScanOptions()
        )
    }
}
