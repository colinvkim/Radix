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
    var foldersDeleted = 0
    var bytesMovedToTrash: Int64 = 0
    var largestTrashMoveBytes: Int64 = 0
    var lastUpdatedAt: Date?

    static let empty = AppUsageStats()

    private enum CodingKeys: String, CodingKey {
        case totalScansRun
        case totalBytesScanned
        case largestScanBytes
        case totalScanDuration
        case fastestScanBytesPerSecond
        case sunburstSegmentsClicked
        case filesDeleted
        case foldersDeleted
        case bytesMovedToTrash
        case largestTrashMoveBytes
        case lastUpdatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        totalScansRun = try container.decodeIfPresent(Int.self, forKey: .totalScansRun) ?? 0
        totalBytesScanned = try container.decodeIfPresent(Int64.self, forKey: .totalBytesScanned) ?? 0
        largestScanBytes = try container.decodeIfPresent(Int64.self, forKey: .largestScanBytes) ?? 0
        totalScanDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .totalScanDuration) ?? 0
        fastestScanBytesPerSecond = try container.decodeIfPresent(
            Double.self,
            forKey: .fastestScanBytesPerSecond
        ) ?? 0
        sunburstSegmentsClicked = try container.decodeIfPresent(Int.self, forKey: .sunburstSegmentsClicked) ?? 0
        filesDeleted = try container.decodeIfPresent(Int.self, forKey: .filesDeleted) ?? 0
        foldersDeleted = try container.decodeIfPresent(Int.self, forKey: .foldersDeleted) ?? 0
        bytesMovedToTrash = try container.decodeIfPresent(Int64.self, forKey: .bytesMovedToTrash) ?? 0
        largestTrashMoveBytes = try container.decodeIfPresent(Int64.self, forKey: .largestTrashMoveBytes) ?? 0
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
    }

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

    mutating func recordTrashMove(nodes: [FileNodeRecord], fileTreeStore: FileTreeStore? = nil) {
        guard !nodes.isEmpty else { return }

        let trashMoveBytes = nodes.reduce(into: Int64(0)) { result, node in
            result = result.addingClamped(max(0, node.allocatedSize))
        }
        let deletedFiles = nodes.reduce(into: 0) { result, node in
            result = result.addingClamped(max(0, node.descendantFileCount))
        }
        let deletedFolders = nodes.reduce(into: 0) { result, node in
            result = result.addingClamped(deletedFolderCount(for: node, in: fileTreeStore))
        }

        bytesMovedToTrash = bytesMovedToTrash.addingClamped(trashMoveBytes)
        filesDeleted = filesDeleted.addingClamped(deletedFiles)
        foldersDeleted = foldersDeleted.addingClamped(deletedFolders)
        largestTrashMoveBytes = max(largestTrashMoveBytes, trashMoveBytes)
        lastUpdatedAt = Date()
    }

    private func deletedFolderCount(for node: FileNodeRecord, in fileTreeStore: FileTreeStore?) -> Int {
        guard node.isDirectory else { return 0 }
        guard let fileTreeStore else { return 1 }

        var count = 0
        var stack = [node.id]
        while let nodeID = stack.popLast() {
            guard let currentNode = fileTreeStore.node(id: nodeID) else { continue }
            if currentNode.isDirectory {
                count = count.incrementedClampingToMax()
            }
            stack.append(contentsOf: fileTreeStore.children(of: nodeID).map(\.id))
        }

        return max(count, 1)
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
