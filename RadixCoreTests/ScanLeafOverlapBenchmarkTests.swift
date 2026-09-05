import Foundation
import XCTest
@testable import RadixCore

/// A feasibility experiment, not the complete scanner: retain native listings for
/// rollback while preparing nodes in bounded tasks, then publish only on success.
final class ScanLeafOverlapBenchmarkTests: XCTestCase {
    func testNativeLeafOverlapBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RADIX_BENCH_OVERLAP_PATH"] else {
            throw XCTSkip("Set RADIX_BENCH_OVERLAP_PATH to a flat, ordinary-file fixture.")
        }
        let root = URL(filePath: path, directoryHint: .isDirectory)
        let overlap = environment["RADIX_BENCH_OVERLAP_MODE"] == "overlap"
        let workers = max(environment["RADIX_BENCH_OVERLAP_WORKERS"].flatMap(Int.init) ?? 5, 1)
        let start = ContinuousClock.now
        let (nodes, entryCount) = try await Self.prepareNativeLeaves(at: root, overlap: overlap, workers: workers)
        let seconds = BenchmarkSupport.durationSeconds(start.duration(to: .now))
        let peakRSS = BenchmarkSupport.peakResidentBytes()
        XCTAssertEqual(nodes.count, entryCount, "The fixture must contain only ordinary files or symlinks.")
        XCTAssertEqual(Set(nodes.map(\.id)).count, entryCount)
        XCTAssertTrue(nodes.allSatisfy { $0.id == $0.url.path && $0.name == $0.url.lastPathComponent })
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for node in nodes.sorted(by: { $0.id < $1.id }) {
            for byte in node.id.utf8 {
                fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
            }
            fingerprint = (fingerprint ^ 0) &* 1_099_511_628_211
        }
        print("RADIX_BENCH_OVERLAP mode=\(overlap ? "overlap" : "staged") workers=\(workers) seconds=\(BenchmarkSupport.format(seconds)) nodes=\(nodes.count) peak_rss=\(peakRSS) fingerprint=\(String(fingerprint, radix: 16))")

        if environment["RADIX_BENCH_OVERLAP_VALIDATE"] == "1" {
            do {
                _ = try await Self.prepareNativeLeaves(at: root, overlap: true, workers: workers, unavailableAfter: 1)
                XCTFail("Late native unavailability must discard all provisional nodes.")
            } catch BulkDirectoryEnumerator.StreamError.unavailable {
            }
            let task = Task<Void, Error> {
                _ = try await ScanLeafOverlapBenchmarkTests.prepareNativeLeaves(at: root, overlap: true, workers: workers)
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            do {
                try await task.value
                XCTFail("Cancellation must not publish provisional nodes.")
            } catch is CancellationError {
            }
        }
    }

    private nonisolated static func prepareNativeLeaves(
        at root: URL,
        overlap: Bool,
        workers: Int,
        unavailableAfter: Int? = nil
    ) async throws -> ([FileNodeRecord], Int) {
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: root,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: Task.checkCancellation,
            forcedUnavailableAfterBatchCount: unavailableAfter
        )
        defer { cursor.invalidate() }
        let engine = ScanEngine()
        return try await withThrowingTaskGroup(of: [FileNodeRecord].self) { group in
            var batches: [[DirectoryEntry]] = []
            var entryCount = 0
            if !overlap {
                while let batch = try cursor.nextBatch(cancellationCheck: Task.checkCancellation) {
                    batches.append(batch.entries)
                    entryCount += batch.enumeratedItemCount
                }
            }
            var batchIndex = 0
            var active = 0
            var nodes: [FileNodeRecord] = []
            while true {
                let entries: [DirectoryEntry]
                if overlap {
                    guard let batch = try cursor.nextBatch(cancellationCheck: Task.checkCancellation) else { break }
                    batches.append(batch.entries)
                    entryCount += batch.enumeratedItemCount
                    entries = batch.entries
                } else {
                    guard batchIndex < batches.count else { break }
                    entries = batches[batchIndex]
                    batchIndex += 1
                }
                if active == workers {
                    if let prepared = try await group.next() { nodes.append(contentsOf: prepared) }
                    active -= 1
                }
                active += 1
                group.addTask {
                    var prepared: [FileNodeRecord] = []
                    prepared.reserveCapacity(entries.count)
                    for (index, entry) in entries.enumerated() {
                        if index.isMultiple(of: 256) { try Task.checkCancellation() }
                        guard let metadata = entry.metadata, !metadata.isDirectory || metadata.isSymbolicLink else { continue }
                        prepared.append(engine.makeFileNode(url: entry.url, metadata: metadata))
                    }
                    try Task.checkCancellation()
                    return prepared
                }
            }
            while let prepared = try await group.next() { nodes.append(contentsOf: prepared) }
            try Task.checkCancellation()
            withExtendedLifetime(batches) {}
            return (nodes, entryCount)
        }
    }
}
