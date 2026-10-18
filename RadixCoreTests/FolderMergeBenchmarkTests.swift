import Dispatch
import Foundation
import Testing

@testable import RadixCore

struct FolderMergeBenchmarkTests {
    @Test(.tags(.benchmark), .enabled(if: ProcessInfo.processInfo.environment["RADIX_BENCH_FOLDER_MERGE"] == "1"))
    func measureRetainedTreeMerge() throws {
        let directories = Int(ProcessInfo.processInfo.environment["RADIX_BENCH_MERGE_DIRECTORIES"] ?? "200") ?? 200
        let filesPerDirectory = 1_000
        let baseline = buildTree(directories: directories, filesPerDirectory: filesPerDirectory)
        let subtreeID = "/benchmark/directory-0"
        let replacementRoot = node(path: subtreeID, directory: true, bytes: 4_096 * 1_001, files: 1_001)
        let replacementFiles = (0..<1_001).map {
            node(path: subtreeID + "/file-\($0).bin", directory: false, bytes: 4_096, files: 1)
        }
        let replacement = FileTreeStore(root: replacementRoot, childrenByID: [subtreeID: replacementFiles])
        print("RADIX_FOLDER_MERGE_SETUP nodes=\(baseline.nodeCount) replacement_nodes=\(replacement.nodeCount) resident=\(BenchmarkMemorySampler.currentResidentMemoryBytes()) peak_rss=\(BenchmarkSupport.peakResidentBytes())")
        var measured: [Double] = []
        for iteration in 0..<4 {
            let startRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
            let sampler = BenchmarkMemorySampler(initialRSS: startRSS)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "radix.merge-benchmark.memory"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { sampler.sample() }
            timer.resume()
            let started = ContinuousClock.now
            let updated = try #require(try baseline.replacingSubtree(id: subtreeID, with: replacement, cancellationCheck: {}))
            let elapsed = BenchmarkSupport.durationSeconds(started.duration(to: .now))
            sampler.sample()
            timer.cancel()
            #expect(updated.nodeCount == baseline.nodeCount + 1)
            #expect(updated.root.allocatedSize == baseline.root.allocatedSize + 4_096)
            let endRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
            print("RADIX_FOLDER_MERGE_RESULT phase=\(iteration == 0 ? "warmup" : "measure") iteration=\(iteration) nodes=\(baseline.nodeCount) seconds=\(BenchmarkSupport.format(elapsed)) start_rss=\(startRSS) end_rss=\(endRSS) sampled_peak_rss=\(sampler.peak()) process_peak_rss=\(BenchmarkSupport.peakResidentBytes())")
            if iteration > 0 { measured.append(elapsed) }
            withExtendedLifetime(updated) {}
        }
        print("RADIX_FOLDER_MERGE_SUMMARY nodes=\(baseline.nodeCount) median_seconds=\(BenchmarkSupport.format(BenchmarkSupport.median(measured)!)) peak_rss=\(BenchmarkSupport.peakResidentBytes())")
    }

    private func buildTree(directories: Int, filesPerDirectory: Int) -> FileTreeStore {
        let files = directories * filesPerDirectory
        let count = files + directories + 1
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        var nodes = [node(path: "/benchmark", directory: true, bytes: Int64(files) * 4_096, files: files)]
        nodes.reserveCapacity(count)
        var children = [[FileTreeNodeIndex]](repeating: [], count: count)
        var parents = [FileTreeNodeIndex?](repeating: nil, count: count)
        for directory in 0..<directories {
            let path = "/benchmark/directory-\(directory)"
            let index = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(node(path: path, directory: true, bytes: Int64(filesPerDirectory) * 4_096, files: filesPerDirectory))
            parents[Int(index.rawValue)] = rootIndex
            children[0].append(index)
            children[Int(index.rawValue)].reserveCapacity(filesPerDirectory)
            for file in 0..<filesPerDirectory {
                let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                nodes.append(node(path: path + "/file-\(file).bin", directory: false, bytes: 4_096, files: 1))
                parents[Int(fileIndex.rawValue)] = index
                children[Int(index.rawValue)].append(fileIndex)
            }
        }
        return FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: children,
            parentIndices: parents,
            orderedNodeIndices: nodes.indices.map { FileTreeNodeIndex(rawValue: UInt32($0)) },
            aggregateStats: ScanAggregateStats(totalAllocatedSize: Int64(files) * 4_096, totalLogicalSize: Int64(files) * 4_096,
                fileCount: files, directoryCount: directories + 1, accessibleItemCount: count, inaccessibleItemCount: 0)
        )
    }

    private func node(path: String, directory: Bool, bytes: Int64, files: Int) -> FileNodeRecord {
        FileNodeRecord(id: path, url: URL(filePath: path, directoryHint: directory ? .isDirectory : .notDirectory),
            name: URL(filePath: path).lastPathComponent, isDirectory: directory, isSymbolicLink: false,
            allocatedSize: bytes, logicalSize: bytes, descendantFileCount: files, lastModified: nil,
            isPackage: false, isAccessible: true, isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false)
    }
}
