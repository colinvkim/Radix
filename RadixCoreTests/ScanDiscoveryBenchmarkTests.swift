import Darwin
import Foundation
import Testing

@testable import RadixCore

struct ScanDiscoveryBenchmarkTests {
    /// Run separately built versions in fresh Release processes against the same
    /// unchanged folder. Timing ends after the scanner publishes its snapshot.
    @Test(.tags(.benchmark), .enabled(if: ProcessInfo.processInfo.environment["RADIX_BENCH_SCAN_PATH"] != nil))
    func testDirectScan() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["RADIX_BENCH_SCAN_PATH"])
        var options = ScanOptions()
        options.includeHiddenFiles = true
        options.treatPackagesAsDirectories = environment["RADIX_BENCH_SCAN_SUMMARIZE"] != "1"
        options.autoSummarizeDirectories = !options.treatPackagesAsDirectories
        let initialHeap = Self.heapBytes()
        let initialCPU = Self.cpuSeconds()
        let started = ContinuousClock.now
        var finalizationStarted: ContinuousClock.Instant?
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(
            target: ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)), options: options
        ) {
            if case .progress(let metrics) = event, metrics.isFinalizing, finalizationStarted == nil {
                finalizationStarted = .now
            }
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let ended = ContinuousClock.now
        let cpuSeconds = Self.cpuSeconds() - initialCPU
        let peakRSS = BenchmarkSupport.peakResidentBytes()
        let snapshot = try #require(finished)
        _ = malloc_zone_pressure_relief(nil, 0)
        let retainedHeap = Self.heapBytes()
        BenchmarkSupport.report(
            prefix: "RADIX_SCAN", phase: "scan",
            seconds: BenchmarkSupport.durationSeconds(started.duration(to: ended)),
            count: snapshot.treeStore.nodeCount, peakRSS: peakRSS,
            extra: "cpu_seconds=\(BenchmarkSupport.format(cpuSeconds)) "
                + "finalization_seconds=\(BenchmarkSupport.format(finalizationStarted.map { BenchmarkSupport.durationSeconds($0.duration(to: ended)) } ?? 0)) "
                + "malloc_delta=\(BenchmarkSupport.byteDelta(from: initialHeap, to: retainedHeap)) "
                + "allocated=\(snapshot.root.allocatedSize) logical=\(snapshot.root.logicalSize) "
                + "warnings=\(snapshot.scanWarnings.count) fingerprint=\(scanResultFingerprint(snapshot.treeStore)) "
                + "warning_fingerprint=\(scanWarningFingerprint(snapshot.scanWarnings))"
        )
        withExtendedLifetime(snapshot) {}
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func heapBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }
}
