import XCTest
@testable import RadixCore

final class AppUsageStatsStoreTests: XCTestCase {
    func testRecordsScanInteractionAndCleanupStats() {
        let first = makeTestFileNode(id: "/stats/first.bin", name: "first.bin", size: 100)
        let second = makeTestFileNode(id: "/stats/second.bin", name: "second.bin", size: 200)
        let root = makeTestDirectoryNode(id: "/stats", name: "stats", children: [first, second])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [first, second]])
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: root.url),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 14),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )

        var stats = AppUsageStats.empty
        stats.recordCompletedScan(snapshot)
        stats.recordSunburstSegmentClick()
        stats.recordSunburstSegmentClick()
        stats.recordTrashCleanup(nodes: [root])

        XCTAssertEqual(stats.totalScansRun, 1)
        XCTAssertEqual(stats.totalBytesScanned, 300)
        XCTAssertEqual(stats.largestScanBytes, 300)
        XCTAssertEqual(stats.totalScanDuration, 4)
        XCTAssertEqual(stats.averageScanBytesPerSecond, 75)
        XCTAssertEqual(stats.fastestScanBytesPerSecond, 75)
        XCTAssertEqual(stats.sunburstSegmentsClicked, 2)
        XCTAssertEqual(stats.filesDeleted, 2)
        XCTAssertEqual(stats.bytesMovedToTrash, 300)
        XCTAssertEqual(stats.biggestSingleCleanupBytes, 300)
        XCTAssertNotNil(stats.lastUpdatedAt)
    }

    func testUserDefaultsStoreRoundTripsAndClearsStats() {
        let defaults = makeIsolatedUsageStatsDefaults()
        let store = UserDefaultsAppUsageStatsStore(defaults: defaults)
        var stats = AppUsageStats.empty
        stats.totalScansRun = 3
        stats.totalBytesScanned = 1024
        stats.sunburstSegmentsClicked = 9

        store.saveUsageStats(stats)

        XCTAssertEqual(store.loadUsageStats(), stats)

        store.clearUsageStats()

        XCTAssertEqual(store.loadUsageStats(), .empty)
    }

    func testUserDefaultsStoreFallsBackToEmptyForInvalidData() {
        let defaults = makeIsolatedUsageStatsDefaults()
        defaults.set(Data("not-json".utf8), forKey: "usageStats")

        let stats = UserDefaultsAppUsageStatsStore(defaults: defaults).loadUsageStats()

        XCTAssertEqual(stats, .empty)
    }
}

private func makeIsolatedUsageStatsDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
) -> UserDefaults {
    let suiteName = "RadixUsageStatsTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create isolated UserDefaults suite.", file: file, line: line)
        return .standard
    }

    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
