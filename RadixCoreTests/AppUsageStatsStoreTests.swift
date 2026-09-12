import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppUsageStatsStoreTests {
    private let temporaryDefaults = TemporaryTestDefaults()

    @Test
    func testRecordsScanInteractionAndTrashStats() {
        let first = makeTestFileNode(id: "/stats/first.bin", name: "first.bin", size: 100)
        let second = makeTestFileNode(id: "/stats/second.bin", name: "second.bin", size: 200)
        let nested = makeTestDirectoryNode(id: "/stats/folder/nested", name: "nested", children: [first])
        let folder = makeTestDirectoryNode(id: "/stats/folder", name: "folder", children: [nested, second])
        let root = makeTestDirectoryNode(id: "/stats", name: "stats", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: [nested, second],
                nested.id: [first],
            ])
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 14),
            scanWarnings: [],
            isComplete: true
        )

        var stats = AppUsageStats.empty
        stats.recordCompletedScan(snapshot)
        stats.recordSunburstSegmentClick()
        stats.recordSunburstSegmentClick()
        stats.recordTrashMove(nodes: [folder], fileTreeStore: store)

        #expect(stats.totalScansRun == 1)
        #expect(stats.totalBytesScanned == 300)
        #expect(stats.largestScanBytes == 300)
        #expect(stats.totalScanDuration == 4)
        #expect(stats.averageScanBytesPerSecond == 75)
        #expect(stats.fastestScanBytesPerSecond == 75)
        #expect(stats.sunburstSegmentsClicked == 2)
        #expect(stats.filesDeleted == 2)
        #expect(stats.foldersDeleted == 2)
        #expect(stats.bytesMovedToTrash == 300)
        #expect(stats.largestTrashMoveBytes == 300)
        #expect(stats.lastUpdatedAt != nil)
    }

    @Test
    func testRecordsDirectFileTrashMoveAsDeletedFile() {
        let file = makeTestFileNode(id: "/stats/file.bin", name: "file.bin", size: 128)

        var stats = AppUsageStats.empty
        stats.recordTrashMove(nodes: [file])

        #expect(stats.filesDeleted == 1)
        #expect(stats.foldersDeleted == 0)
        #expect(stats.bytesMovedToTrash == 128)
        #expect(stats.largestTrashMoveBytes == 128)
    }

    @Test
    func testUserDefaultsStoreRoundTripsAndClearsStats() throws {
        let defaults = try temporaryDefaults.make()
        let store = UserDefaultsAppUsageStatsStore(defaults: defaults)
        var stats = AppUsageStats.empty
        stats.totalScansRun = 3
        stats.totalBytesScanned = 1024
        stats.sunburstSegmentsClicked = 9

        store.saveUsageStats(stats)

        #expect(store.loadUsageStats() == stats)

        store.clearUsageStats()

        #expect(store.loadUsageStats() == .empty)
    }

    @Test
    func testUserDefaultsStoreDefaultsMissingTrashCounts() throws {
        let defaults = try temporaryDefaults.make()
        defaults.set(
            Data(#"{"totalScansRun":1,"filesDeleted":2,"bytesMovedToTrash":300}"#.utf8),
            forKey: "usageStats"
        )

        let stats = UserDefaultsAppUsageStatsStore(defaults: defaults).loadUsageStats()

        #expect(stats.totalScansRun == 1)
        #expect(stats.filesDeleted == 2)
        #expect(stats.foldersDeleted == 0)
        #expect(stats.bytesMovedToTrash == 300)
    }

    @Test
    func testUserDefaultsStoreFallsBackToEmptyForInvalidData() throws {
        let defaults = try temporaryDefaults.make()
        defaults.set(Data("not-json".utf8), forKey: "usageStats")

        let stats = UserDefaultsAppUsageStatsStore(defaults: defaults).loadUsageStats()

        #expect(stats == .empty)
    }
}
