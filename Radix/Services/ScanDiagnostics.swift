#if DEBUG
import Dispatch
import Foundation

nonisolated final class ScanDiagnostics: @unchecked Sendable {
    private struct OperationStats {
        var count = 0
        var totalNanoseconds: UInt64 = 0
        var itemCount = 0
        var maxNanoseconds: UInt64 = 0
    }

    private struct SlowEvent {
        let operation: String
        let path: String
        let nanoseconds: UInt64
        let itemCount: Int?
        let detail: String?
    }

    private let reportLimit: Int
    private let slowThresholdNanoseconds: UInt64
    private let lock = NSLock()
    private var statsByOperation: [String: OperationStats] = [:]
    private var statsByPathBucket: [String: OperationStats] = [:]
    private var slowEvents: [SlowEvent] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        reportLimit = environment["RADIX_SCAN_DIAGNOSTICS_LIMIT"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 30
        let slowThresholdMilliseconds = environment["RADIX_SCAN_DIAGNOSTICS_SLOW_MS"]
            .flatMap(Double.init) ?? 50
        slowThresholdNanoseconds = UInt64(max(0, slowThresholdMilliseconds) * 1_000_000)
    }

    static func makeIfEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> ScanDiagnostics? {
        guard environment["RADIX_SCAN_DIAGNOSTICS"] == "1" else { return nil }
        return ScanDiagnostics(environment: environment)
    }

    func start() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func record(
        operation: String,
        url: URL,
        startedAt start: UInt64?,
        itemCount: Int? = nil,
        detail: String? = nil
    ) {
        guard let start else { return }
        record(
            operation: operation,
            path: url.path,
            nanoseconds: DispatchTime.now().uptimeNanoseconds - start,
            itemCount: itemCount,
            detail: detail
        )
    }

    func recordElapsed(
        operation: String,
        url: URL,
        nanoseconds: UInt64,
        itemCount: Int? = nil,
        detail: String? = nil
    ) {
        record(
            operation: operation,
            path: url.path,
            nanoseconds: nanoseconds,
            itemCount: itemCount,
            detail: detail
        )
    }

    func makeReport(targetPath: String, elapsedSeconds: Double) -> String {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = [
            "RADIX_SCAN_DIAGNOSTICS target=\(targetPath) elapsed=\(Self.format(seconds: elapsedSeconds))s",
            "RADIX_SCAN_DIAGNOSTICS operations"
        ]

        for (operation, stats) in sortedStats(statsByOperation) {
            lines.append(
                "  \(operation): total=\(Self.format(nanoseconds: stats.totalNanoseconds))s count=\(stats.count) avg=\(Self.format(nanoseconds: Self.average(stats.totalNanoseconds, stats.count)))s max=\(Self.format(nanoseconds: stats.maxNanoseconds))s items=\(stats.itemCount)"
            )
        }

        lines.append("RADIX_SCAN_DIAGNOSTICS hot_path_buckets")
        for (path, stats) in sortedStats(statsByPathBucket).prefix(reportLimit) {
            lines.append(
                "  total=\(Self.format(nanoseconds: stats.totalNanoseconds))s count=\(stats.count) max=\(Self.format(nanoseconds: stats.maxNanoseconds))s items=\(stats.itemCount) path=\(path)"
            )
        }

        lines.append("RADIX_SCAN_DIAGNOSTICS slow_events")
        for event in slowEvents.prefix(reportLimit) {
            let itemText = event.itemCount.map { " items=\($0)" } ?? ""
            let detailText = event.detail.map { " \($0)" } ?? ""
            lines.append(
                "  \(Self.format(nanoseconds: event.nanoseconds))s \(event.operation)\(itemText)\(detailText) path=\(event.path)"
            )
        }

        return lines.joined(separator: "\n")
    }

    private func record(
        operation: String,
        path: String,
        nanoseconds: UInt64,
        itemCount: Int?,
        detail: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        updateStats(&statsByOperation[operation, default: OperationStats()], nanoseconds: nanoseconds, itemCount: itemCount)
        updateStats(&statsByPathBucket[Self.pathBucket(for: path), default: OperationStats()], nanoseconds: nanoseconds, itemCount: itemCount)
        recordSlowEvent(
            SlowEvent(
                operation: operation,
                path: path,
                nanoseconds: nanoseconds,
                itemCount: itemCount,
                detail: detail
            )
        )
    }

    private func updateStats(_ stats: inout OperationStats, nanoseconds: UInt64, itemCount: Int?) {
        stats.count += 1
        stats.totalNanoseconds += nanoseconds
        stats.itemCount += itemCount ?? 0
        stats.maxNanoseconds = max(stats.maxNanoseconds, nanoseconds)
    }

    private func recordSlowEvent(_ event: SlowEvent) {
        guard event.nanoseconds >= slowThresholdNanoseconds || slowEvents.count < reportLimit else {
            if let smallest = slowEvents.last, event.nanoseconds > smallest.nanoseconds {
                slowEvents.removeLast()
                insertSlowEvent(event)
            }
            return
        }

        insertSlowEvent(event)
        if slowEvents.count > reportLimit {
            slowEvents.removeLast(slowEvents.count - reportLimit)
        }
    }

    private func insertSlowEvent(_ event: SlowEvent) {
        let insertionIndex = slowEvents.firstIndex { existingEvent in
            event.nanoseconds > existingEvent.nanoseconds
        } ?? slowEvents.endIndex
        slowEvents.insert(event, at: insertionIndex)
    }

    private func sortedStats(_ stats: [String: OperationStats]) -> [(String, OperationStats)] {
        stats.sorted { first, second in
            if first.value.totalNanoseconds == second.value.totalNanoseconds {
                return first.key < second.key
            }
            return first.value.totalNanoseconds > second.value.totalNanoseconds
        }
    }

    private static func average(_ totalNanoseconds: UInt64, _ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        return totalNanoseconds / UInt64(count)
    }

    private static func pathBucket(for path: String) -> String {
        let components = path.split(separator: "/")
        guard !components.isEmpty else { return "/" }
        return "/" + components.prefix(3).joined(separator: "/")
    }

    private static func format(nanoseconds: UInt64) -> String {
        format(seconds: Double(nanoseconds) / 1_000_000_000)
    }

    private static func format(seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
#endif
