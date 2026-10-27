import Foundation
import Testing

@testable import RadixCore

@MainActor
struct RecentTargetStoreTests {
    private let temporaryDefaults = TemporaryTestDefaults()

    @Test(arguments: ["not-json", #"[{"path":"/recent","kind":"unknown"}]"#, #"[{"kind":"folder"}]"#])
    func testUserDefaultsPersistenceFallsBackToEmptyForInvalidPayload(payload: String) throws {
        let defaults = try temporaryDefaults.make()
        defaults.set(Data(payload.utf8), forKey: "recentTargets")

        #expect(UserDefaultsRecentTargetPersistence(defaults: defaults).loadRecentTargets().isEmpty)
    }

    @Test
    func testLoadPrunesUnavailableTargetsAndPersistsAvailableSubset() {
        let available = makeRecentTarget("/recent/available")
        let missing = makeRecentTarget("/recent/missing")
        let persistence = TestRecentTargetPersistence(targets: [available, missing])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { $0.id == available.id }
        )

        #expect(store.loadAvailableTargets() == [available])
        #expect(persistence.savedTargets == [[available]])
    }

    @Test
    func testRecordMovesTargetToFrontDeduplicatesPrunesAndCaps() {
        let first = makeRecentTarget("/recent/first")
        let duplicate = makeRecentTarget("/recent/duplicate")
        let missing = makeRecentTarget("/recent/missing")
        let lastKept = makeRecentTarget("/recent/last-kept")
        let droppedByLimit = makeRecentTarget("/recent/dropped")
        let persistence = TestRecentTargetPersistence()
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

        #expect(updatedTargets == [duplicate, first, lastKept])
        #expect(persistence.savedTargets == [[duplicate, first, lastKept]])
    }

    @Test
    func testRecordUnavailableTargetPrunesAndDoesNotInsert() {
        let available = makeRecentTarget("/recent/available")
        let missing = makeRecentTarget("/recent/missing")
        let unavailableNewTarget = makeRecentTarget("/recent/unavailable-new")
        let persistence = TestRecentTargetPersistence()
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { $0.id == available.id }
        )

        let updatedTargets = store.record(
            unavailableNewTarget,
            currentTargets: [available, missing]
        )

        #expect(updatedTargets == [available])
        #expect(persistence.savedTargets == [[available]])
    }

    @Test
    func testRemoveTargetPrunesAndPersistsRemainingTargets() {
        let first = makeRecentTarget("/recent/first")
        let removed = makeRecentTarget("/recent/removed")
        let missing = makeRecentTarget("/recent/missing")
        let last = makeRecentTarget("/recent/last")
        let persistence = TestRecentTargetPersistence()
        let availableIDs = Set([first.id, removed.id, last.id])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { availableIDs.contains($0.id) }
        )

        let updatedTargets = store.remove(
            removed,
            currentTargets: [first, removed, missing, last]
        )

        #expect(updatedTargets == [first, last])
        #expect(persistence.savedTargets == [[first, last]])
    }

    @Test
    func testClearDelegatesToPersistence() {
        let persistence = TestRecentTargetPersistence(targets: [makeRecentTarget("/recent/item")])
        let store = RecentTargetStore(
            persistence: persistence,
            isAvailable: { _ in true }
        )

        store.clear()

        #expect(persistence.didClear)
        #expect(persistence.targets.isEmpty)
    }
}

private func makeRecentTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}
