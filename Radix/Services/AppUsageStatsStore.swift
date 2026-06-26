//
//  AppUsageStatsStore.swift
//  Radix
//

import Foundation

struct AppUsageStats: Codable, Equatable, Sendable {
    var totalScansRun = 0
    var totalBytesScanned: Int64 = 0
    var largestScanBytes: Int64 = 0
    var totalScanDuration: TimeInterval = 0
    var fastestScanBytesPerSecond = 0.0
    var sunburstSegmentsClicked = 0
    var filesDeleted = 0
    var bytesMovedToTrash: Int64 = 0
    var biggestSingleCleanupBytes: Int64 = 0
    var lastUpdatedAt: Date?

    static let empty = AppUsageStats()

    var averageScanBytesPerSecond: Double {
        guard totalScanDuration > 0 else { return 0 }
        return Double(totalBytesScanned) / totalScanDuration
    }

    var isEmpty: Bool {
        self == .empty
    }

    mutating func recordCompletedScan(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete else { return }

        let scannedBytes = max(0, snapshot.aggregateStats.totalAllocatedSize)
        totalScansRun = totalScansRun.incrementedClampingToMax()
        totalBytesScanned = totalBytesScanned.addingClamped(scannedBytes)
        largestScanBytes = max(largestScanBytes, scannedBytes)

        if let finishedAt = snapshot.finishedAt {
            let duration = max(0, finishedAt.timeIntervalSince(snapshot.startedAt))
            if duration > 0 {
                totalScanDuration += duration
                fastestScanBytesPerSecond = max(
                    fastestScanBytesPerSecond,
                    Double(scannedBytes) / duration
                )
            }
        }

        lastUpdatedAt = Date()
    }

    mutating func recordSunburstSegmentClick() {
        sunburstSegmentsClicked = sunburstSegmentsClicked.incrementedClampingToMax()
        lastUpdatedAt = Date()
    }

    mutating func recordTrashCleanup(nodes: [FileNodeRecord]) {
        guard !nodes.isEmpty else { return }

        let cleanupBytes = nodes.reduce(into: Int64(0)) { result, node in
            result = result.addingClamped(max(0, node.allocatedSize))
        }
        let deletedFiles = nodes.reduce(into: 0) { result, node in
            result = result.addingClamped(max(0, node.descendantFileCount))
        }

        bytesMovedToTrash = bytesMovedToTrash.addingClamped(cleanupBytes)
        filesDeleted = filesDeleted.addingClamped(deletedFiles)
        biggestSingleCleanupBytes = max(biggestSingleCleanupBytes, cleanupBytes)
        lastUpdatedAt = Date()
    }
}

protocol AppUsageStatsPersisting: AnyObject {
    func loadUsageStats() -> AppUsageStats
    func saveUsageStats(_ stats: AppUsageStats)
    func clearUsageStats()
}

final class UserDefaultsAppUsageStatsStore: AppUsageStatsPersisting {
    private enum Key {
        static let usageStats = "usageStats"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadUsageStats() -> AppUsageStats {
        guard let data = defaults.data(forKey: Key.usageStats) else {
            return .empty
        }

        do {
            return try JSONDecoder().decode(AppUsageStats.self, from: data)
        } catch {
            return .empty
        }
    }

    func saveUsageStats(_ stats: AppUsageStats) {
        do {
            let data = try JSONEncoder().encode(stats)
            defaults.set(data, forKey: Key.usageStats)
        } catch {
            defaults.removeObject(forKey: Key.usageStats)
        }
    }

    func clearUsageStats() {
        defaults.removeObject(forKey: Key.usageStats)
    }
}

final class InMemoryAppUsageStatsStore: AppUsageStatsPersisting {
    private var stats: AppUsageStats

    init(stats: AppUsageStats = .empty) {
        self.stats = stats
    }

    func loadUsageStats() -> AppUsageStats {
        stats
    }

    func saveUsageStats(_ stats: AppUsageStats) {
        self.stats = stats
    }

    func clearUsageStats() {
        stats = .empty
    }
}

private extension Int {
    func addingClamped(_ value: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? Int.max : sum
    }

    func incrementedClampingToMax() -> Int {
        addingClamped(1)
    }
}

private extension Int64 {
    func addingClamped(_ value: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? Int64.max : sum
    }
}
