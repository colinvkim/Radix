import Foundation
import Testing

@testable import RadixCore

struct ScanSortSpeedAuditBenchmarkTests {
    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_SCAN_SORT"] == "1",
            "Set RADIX_BENCH_SCAN_SORT=1 to compare scanner sibling-sort field access."))
    func testSiblingSortFieldAccessBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = max(environment["RADIX_BENCH_SCAN_SORT_COUNT"].flatMap(Int.init) ?? 200_000, 1)
        let modes =
            environment["RADIX_BENCH_SCAN_SORT_REVERSE"] == "1"
            ? ["fields", "records"] : ["records", "fields"]
        for scenario in ["ordered-ties", "shuffled-ties", "shuffled-sizes"] {
            let nodes = (0..<count).map { index in
                let digits = String(index)
                let name = "file-" + String(repeating: "0", count: max(8 - digits.count, 0)) + digits + ".dat"
                return ChartResponsivenessBenchmarkSupport.node(
                    id: "/scan-sort-audit/\(name)", name: name, isDirectory: false,
                    allocatedSize: scenario == "shuffled-sizes" ? Int64(index % 997) : 0,
                    descendantFileCount: 1
                )
            }
            var input = Array(nodes.indices)
            if scenario.hasPrefix("shuffled") {
                var state: UInt64 = 42
                for index in input.indices.dropFirst().reversed() {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    input.swapAt(index, Int(state % UInt64(index + 1)))
                }
            }
            var expected: [Int]?
            for mode in modes {
                var keys = input
                let start = ContinuousClock.now
                if mode == "records" {
                    try Self.sortRecords(&keys, nodes: nodes)
                } else {
                    try Self.sortFields(&keys, nodes: nodes)
                }
                let seconds = BenchmarkSupport.durationSeconds(start.duration(to: .now))
                if let expected { #expect(keys == expected) }
                expected = keys
                print("RADIX_BENCH_SCAN_SORT scenario=\(scenario) mode=\(mode) count=\(count) seconds=\(seconds)")
            }
        }
    }

    // Match the shipping comparator's owned record temporaries.
    @inline(never)
    private static func sortRecords(_ keys: inout [Int], nodes: [FileNodeRecord]) throws {
        try CancellableSort.sort(&keys, cancellationCheck: Task.checkCancellation) { lhsKey, rhsKey in
            let lhs = nodes[lhsKey]
            let rhs = nodes[rhsKey]
            if lhs.allocatedSize == rhs.allocatedSize {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.allocatedSize > rhs.allocatedSize
        }
    }

    // Read just the sort fields, keeping identical collation and cancellation.
    @inline(never)
    private static func sortFields(_ keys: inout [Int], nodes: [FileNodeRecord]) throws {
        try CancellableSort.sort(&keys, cancellationCheck: Task.checkCancellation) { lhsKey, rhsKey in
            let lhsSize = nodes[lhsKey].allocatedSize
            let rhsSize = nodes[rhsKey].allocatedSize
            if lhsSize == rhsSize {
                return nodes[lhsKey].name.localizedStandardCompare(nodes[rhsKey].name) == .orderedAscending
            }
            return lhsSize > rhsSize
        }
    }
}
