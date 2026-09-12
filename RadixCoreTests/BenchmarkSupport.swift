import Darwin
import Foundation

enum BenchmarkSupport {
    static func measure<Value>(
        _ operation: () throws -> Value
    ) rethrows -> BenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try operation()
        return BenchmarkMeasurement(
            value: value,
            seconds: durationSeconds(startedAt.duration(to: .now))
        )
    }

    static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2
        }
        return sortedValues[midpoint]
    }

    static func report(
        prefix: String,
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        print(
            resultLine(
                prefix: prefix,
                phase: phase,
                seconds: seconds,
                count: count,
                peakRSS: peakRSS,
                extra: extra
            ))
    }

    static func resultLine(
        prefix: String,
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) -> String {
        "\(prefix) phase=\(phase) "
            + "seconds=\(format(seconds)) count=\(count) "
            + "peak_rss=\(peakRSS) \(extra)"
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(usage.ru_maxrss, 0))
    }

    static func byteDelta(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

struct BenchmarkMeasurement<Value> {
    let value: Value
    let seconds: Double
}

final class BenchmarkMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakRSS: UInt64

    init(initialRSS: UInt64) {
        peakRSS = initialRSS
    }

    func sample() {
        let currentRSS = Self.currentResidentMemoryBytes()
        lock.lock()
        peakRSS = max(peakRSS, currentRSS)
        lock.unlock()
    }

    func peak() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return peakRSS
    }

    static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundInfo in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundInfo,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
