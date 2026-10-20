import Foundation
import Testing

@testable import RadixCore

struct ScanProgressCadenceTests {
    @Test
    func testMixedLeafTraversalPublishesProgressWithoutChangingVisibleFileTotals() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "RadixProgressCadence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstFile = rootURL.appending(path: "first.bin")
        let secondFile = rootURL.appending(path: "second.bin")
        try Data(repeating: 0x11, count: 7).write(to: firstFile)
        try Data(repeating: 0x22, count: 11).write(to: secondFile)
        let symlinks = try (0..<1_200).map { index in
            let url = rootURL.appending(path: "link-\(index)")
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "first.bin")
            return url
        }
        let missingURLs = (0..<4).map { rootURL.appending(path: "missing-\($0)", directoryHint: .isDirectory) }
        let orderedURLs = [firstFile, secondFile] + symlinks + missingURLs
        let engine = ScanEngine(
            enumeratedDirectoryContents: { _, _, _, cancellationCheck in
                try cancellationCheck()
                return ScanEngine.DirectoryEnumerationResult(urls: orderedURLs)
            },
            atomicSummaryProgressEmissionInterval: 0
        )
        let options = ScanOptions(
            autoSummarizeDirectories: false,
            directoryClassificationWorkerLimit: 1,
            directoryTraversalWorkerLimit: 1
        )
        var progress: [ScanMetrics] = []
        var snapshot: ScanSnapshot?
        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progress.append(metrics)
            case .finished(let result):
                snapshot = result
            case .warning, .executionMode:
                break
            }
        }

        let intermediate = try #require(progress.first {
            !$0.isFinalizing && $0.completedItems >= 900 && $0.completedItems <= 1_100
        })
        #expect(intermediate.filesVisited == 2)
        #expect(intermediate.directoriesVisited == 1)
        #expect(intermediate.enumeratedDirectoryCount == 1)
        let finished = try #require(snapshot)
        #expect(finished.root.descendantFileCount == 2)
        #expect(finished.aggregateStats.fileCount == 2)
        #expect(finished.aggregateStats.totalLogicalSize == 10_818)
        #expect(finished.scanWarnings.count == 4)
        #expect(Set(finished.scanWarnings.map(\.path)) == Set(missingURLs.map(\.path)))
        #expect(progress.last?.filesVisited == 2)
        #expect(progress.last?.progressFraction == 1)
        for (previous, next) in zip(progress, progress.dropFirst()) {
            #expect(next.progressFraction >= previous.progressFraction)
        }
    }
}
