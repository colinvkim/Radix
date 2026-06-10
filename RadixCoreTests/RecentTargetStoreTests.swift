import XCTest
@testable import RadixCore

final class RecentTargetStoreTests: XCTestCase {
    func testLoadPrunesUnavailableTargetsAndPersistsAvailableSubset() {
        let available = makeRecentTarget("/recent/available")
        let missing = makeRecentTarget("/recent/missing")
        let persistence = InMemoryRecentTargetPersistence(targets: [available, missing])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { $0.id == available.id }
        )

        XCTAssertEqual(store.loadAvailableTargets(), [available])
        XCTAssertEqual(persistence.savedTargets, [[available]])
    }

    func testRecordMovesTargetToFrontDeduplicatesPrunesAndCaps() {
        let first = makeRecentTarget("/recent/first")
        let duplicate = makeRecentTarget("/recent/duplicate")
        let missing = makeRecentTarget("/recent/missing")
        let lastKept = makeRecentTarget("/recent/last-kept")
        let droppedByLimit = makeRecentTarget("/recent/dropped")
        let persistence = InMemoryRecentTargetPersistence()
        let availableIDs = Set([first.id, duplicate.id, lastKept.id, droppedByLimit.id])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { availableIDs.contains($0.id) },
            limit: 3
        )

        let updatedTargets = store.record(
            duplicate,
            currentTargets: [first, duplicate, missing, lastKept, droppedByLimit]
        )

        XCTAssertEqual(updatedTargets, [duplicate, first, lastKept])
        XCTAssertEqual(persistence.savedTargets, [[duplicate, first, lastKept]])
    }

    func testRecordUnavailableTargetPrunesAndDoesNotInsert() {
        let available = makeRecentTarget("/recent/available")
        let missing = makeRecentTarget("/recent/missing")
        let unavailableNewTarget = makeRecentTarget("/recent/unavailable-new")
        let persistence = InMemoryRecentTargetPersistence()
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { $0.id == available.id }
        )

        let updatedTargets = store.record(
            unavailableNewTarget,
            currentTargets: [available, missing]
        )

        XCTAssertEqual(updatedTargets, [available])
        XCTAssertEqual(persistence.savedTargets, [[available]])
    }

    func testRemoveTargetPrunesAndPersistsRemainingTargets() {
        let first = makeRecentTarget("/recent/first")
        let removed = makeRecentTarget("/recent/removed")
        let missing = makeRecentTarget("/recent/missing")
        let last = makeRecentTarget("/recent/last")
        let persistence = InMemoryRecentTargetPersistence()
        let availableIDs = Set([first.id, removed.id, last.id])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { availableIDs.contains($0.id) }
        )

        let updatedTargets = store.remove(
            removed,
            currentTargets: [first, removed, missing, last]
        )

        XCTAssertEqual(updatedTargets, [first, last])
        XCTAssertEqual(persistence.savedTargets, [[first, last]])
    }

    func testClearDelegatesToPersistence() {
        let persistence = InMemoryRecentTargetPersistence(targets: [makeRecentTarget("/recent/item")])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { _ in true }
        )

        store.clear()

        XCTAssertTrue(persistence.didClear)
        XCTAssertTrue(persistence.targets.isEmpty)
    }
}

private func makeRecentTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

private final class InMemoryRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget]
    var savedTargets: [[ScanTarget]] = []
    var didClear = false

    init(targets: [ScanTarget] = []) {
        self.targets = targets
    }

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
        savedTargets.append(targets)
    }

    func clearRecentTargets() {
        didClear = true
        targets = []
    }
}
