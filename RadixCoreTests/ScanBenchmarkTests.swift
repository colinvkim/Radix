import XCTest
@testable import RadixCore

final class ScanBenchmarkTests: XCTestCase {
    func testRealWorldScanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH=1 to run the real-world scan benchmark.")
        }

        let benchmarkPath = environment["RADIX_BENCH_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: benchmarkPath, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw XCTSkip("Benchmark path does not exist: \(targetURL.path)")
        }

        let engine = ScanEngine()
        let startedAt = ContinuousClock.now
        var progressEvents = 0
        var warningEvents = 0
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: targetURL), options: ScanOptions()) {
            switch event {
            case .progress:
                progressEvents += 1
            case .warning:
                warningEvents += 1
            case .finished(let snapshot):
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let snapshot = try XCTUnwrap(finalSnapshot)
        let elapsedSeconds = Double(elapsed.components.seconds) + (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)

        print(
            """
            RADIX_BENCH_RESULT path=\(targetURL.path)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            files=\(snapshot.aggregateStats.fileCount)
            folders=\(snapshot.aggregateStats.directoryCount)
            warnings=\(snapshot.scanWarnings.count)
            progress_events=\(progressEvents)
            discovered=\(snapshot.aggregateStats.totalAllocatedSize)
            """
        )
    }

    func testWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_WIDE_DIRECTORY"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_WIDE_DIRECTORY=1 to run the wide-directory benchmark.")
        }

        let fileCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FILE_COUNTS"],
            defaultValues: [128, 1_000, 10_000]
        )
        let iterations = environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers = environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers = environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            )
        ]

        for fileCount in fileCounts {
            let rootURL = try makeWideBenchmarkDirectory(fileCount: fileCount)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            for configuration in configurations {
                _ = try await runWideDirectoryBenchmark(
                    rootURL: rootURL,
                    fileCount: fileCount,
                    configuration: configuration,
                    iteration: 0,
                    isWarmup: true
                )
            }

            var elapsedByConfiguration: [String: [Double]] = [:]
            for iteration in 1...iterations {
                for configuration in configurations {
                    let elapsedSeconds = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: iteration,
                        isWarmup: false
                    )
                    elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                }
            }

            for configuration in configurations {
                let elapsed = elapsedByConfiguration[configuration.name, default: []]
                guard !elapsed.isEmpty else { continue }
                let average = elapsed.reduce(0, +) / Double(elapsed.count)
                print(
                    """
                    RADIX_BENCH_WIDE_SUMMARY files=\(fileCount)
                    config=\(configuration.name)
                    traversal_workers=\(configuration.traversalWorkerDescription)
                    requested_classification_workers=\(configuration.classificationWorkerDescription)
                    iterations=\(elapsed.count)
                    avg_elapsed=\(String(format: "%.3f", average))s
                    min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                    max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                    """
                )
            }
        }
    }

    func testFanoutWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_WIDE_FANOUT"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_WIDE_FANOUT=1 to run the fanout wide-directory benchmark.")
        }

        let childDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_DIR_COUNTS"],
            defaultValues: [8]
        )
        let filesPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_FILES_PER_DIR"],
            defaultValues: [1_000]
        )
        let iterations = environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers = environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers = environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-only",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            )
        ]

        for childDirectoryCount in childDirectoryCounts {
            for filesPerDirectory in filesPerDirectoryCounts {
                let rootURL = try makeFanoutWideBenchmarkDirectory(
                    childDirectoryCount: childDirectoryCount,
                    filesPerDirectory: filesPerDirectory
                )
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let fileCount = childDirectoryCount * filesPerDirectory

                for configuration in configurations {
                    _ = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: 0,
                        isWarmup: true
                    )
                }

                var elapsedByConfiguration: [String: [Double]] = [:]
                for iteration in 1...iterations {
                    for configuration in configurations {
                        let elapsedSeconds = try await runWideDirectoryBenchmark(
                            rootURL: rootURL,
                            fileCount: fileCount,
                            configuration: configuration,
                            iteration: iteration,
                            isWarmup: false
                        )
                        elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                    }
                }

                for configuration in configurations {
                    let elapsed = elapsedByConfiguration[configuration.name, default: []]
                    guard !elapsed.isEmpty else { continue }
                    let average = elapsed.reduce(0, +) / Double(elapsed.count)
                    print(
                        """
                        RADIX_BENCH_WIDE_FANOUT_SUMMARY child_dirs=\(childDirectoryCount)
                        files_per_dir=\(filesPerDirectory)
                        files=\(fileCount)
                        config=\(configuration.name)
                        traversal_workers=\(configuration.traversalWorkerDescription)
                        requested_classification_workers=\(configuration.classificationWorkerDescription)
                        iterations=\(elapsed.count)
                        avg_elapsed=\(String(format: "%.3f", average))s
                        min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                        max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                        """
                    )
                }
            }
        }
    }

    private struct WideDirectoryBenchmarkConfiguration {
        let name: String
        let traversalWorkerLimit: Int?
        let classificationWorkerLimit: Int?

        var traversalWorkerDescription: String {
            traversalWorkerLimit.map(String.init) ?? "default"
        }

        var classificationWorkerDescription: String {
            classificationWorkerLimit.map(String.init) ?? "default"
        }
    }

    private static func integerList(from value: String?, defaultValues: [Int]) -> [Int] {
        guard let value else { return defaultValues }
        let parsed = value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        return parsed.isEmpty ? defaultValues : parsed
    }

    private func makeWideBenchmarkDirectory(fileCount: Int) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for index in 0..<fileCount {
            let fileURL = rootURL.appending(path: String(format: "file-%08d.dat", index))
            try payload.write(to: fileURL, options: .atomic)
        }

        return rootURL
    }

    private func makeFanoutWideBenchmarkDirectory(
        childDirectoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for directoryIndex in 0..<childDirectoryCount {
            let directoryURL = rootURL.appending(path: String(format: "group-%03d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<filesPerDirectory {
                let fileURL = directoryURL.appending(path: String(format: "file-%08d.dat", fileIndex))
                try payload.write(to: fileURL, options: .atomic)
            }
        }

        return rootURL
    }

    private func runWideDirectoryBenchmark(
        rootURL: URL,
        fileCount: Int,
        configuration: WideDirectoryBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        var options = ScanOptions()
        options.directoryTraversalWorkerLimit = configuration.traversalWorkerLimit
        options.directoryClassificationWorkerLimit = configuration.classificationWorkerLimit

        let engine = ScanEngine()
        let startedAt = ContinuousClock.now
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) +
            (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
        let snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, fileCount)
        XCTAssertEqual(snapshot.root.descendantFileCount, fileCount)

        let phase = isWarmup ? "warmup" : "measure"
        print(
            """
            RADIX_BENCH_WIDE_RESULT phase=\(phase)
            files=\(fileCount)
            config=\(configuration.name)
            iteration=\(iteration)
            traversal_workers=\(configuration.traversalWorkerDescription)
            requested_classification_workers=\(configuration.classificationWorkerDescription)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            """
        )

        return elapsedSeconds
    }
}
