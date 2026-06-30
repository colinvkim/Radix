import XCTest
@testable import RadixCore

@MainActor
final class SunburstVisualizationFilterModelTests: XCTestCase {
    func testDiscardPileFilterReturnsBaseInputUntilCachedFilterCompletes() async throws {
        let hidden = makeTestFileNode(id: "/root/hidden.bin", name: "hidden.bin", size: 20)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 30)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [hidden, visible])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [hidden, visible]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = SunburstVisualizationFilterModel()
        let baseInput = SunburstFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        let immediateInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id]
        )

        XCTAssertNotNil(immediateInput.treeStore.node(id: hidden.id))

        let filteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [hidden.id],
            removedNodeID: hidden.id
        )

        XCTAssertNil(filteredInput.treeStore.node(id: hidden.id))
        XCTAssertNotNil(filteredInput.treeStore.node(id: visible.id))
        XCTAssertEqual(filteredInput.rootNode.allocatedSize, visible.allocatedSize)
        XCTAssertEqual(
            filteredInput.layoutIDComponent,
            "free-space:0|discard-pile:1:\(hidden.id.count):\(hidden.id)"
        )
    }

    func testDiscardPileFilterDoesNotReturnStaleCachedInputForDifferentHiddenIDs() async throws {
        let firstHidden = makeTestFileNode(id: "/root/first-hidden.bin", name: "first-hidden.bin", size: 20)
        let secondHidden = makeTestFileNode(id: "/root/second-hidden.bin", name: "second-hidden.bin", size: 30)
        let visible = makeTestFileNode(id: "/root/visible.bin", name: "visible.bin", size: 40)
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: [firstHidden, secondHidden, visible]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [firstHidden, secondHidden, visible]]
        )
        let snapshot = makeTestSnapshot(root: root, store: store)
        let model = SunburstVisualizationFilterModel()
        let baseInput = SunburstFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: root,
            showFreeSpace: false,
            availableCapacity: nil
        )

        _ = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id]
        )
        let firstFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [firstHidden.id],
            removedNodeID: firstHidden.id
        )
        XCTAssertNil(firstFilteredInput.treeStore.node(id: firstHidden.id))

        let immediateInput = model.input(
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id]
        )

        XCTAssertNotNil(immediateInput.treeStore.node(id: firstHidden.id))
        XCTAssertNotNil(immediateInput.treeStore.node(id: secondHidden.id))

        let secondFilteredInput = try await waitForFilteredInput(
            model: model,
            baseInput: baseInput,
            snapshotID: snapshot.id,
            focusNodeID: root.id,
            hiddenNodeIDs: [secondHidden.id],
            removedNodeID: secondHidden.id
        )

        XCTAssertNotNil(secondFilteredInput.treeStore.node(id: firstHidden.id))
        XCTAssertNil(secondFilteredInput.treeStore.node(id: secondHidden.id))
    }

    private func waitForFilteredInput(
        model: SunburstVisualizationFilterModel,
        baseInput: SunburstVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        removedNodeID: FileNodeRecord.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SunburstVisualizationInput {
        for _ in 0..<100 {
            let input = model.input(
                baseInput: baseInput,
                snapshotID: snapshotID,
                focusNodeID: focusNodeID,
                hiddenNodeIDs: hiddenNodeIDs
            )
            if input.treeStore.node(id: removedNodeID) == nil {
                return input
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for filtered visualization input.", file: file, line: line)
        return model.input(
            baseInput: baseInput,
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            hiddenNodeIDs: hiddenNodeIDs
        )
    }
}
