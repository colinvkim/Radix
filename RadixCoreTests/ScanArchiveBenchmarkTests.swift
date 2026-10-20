import Foundation
import Testing

@testable import RadixCore

struct ScanArchiveBenchmarkTests {
    private let temporaryFiles = TemporaryTestFiles()

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_ARCHIVE"] == "1",
            "Set RADIX_BENCH_ARCHIVE=1 to run archive export/import benchmarks."))
    func testArchiveExportImportBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment

        let iterations = Self.integer(from: environment["RADIX_BENCH_ARCHIVE_ITERATIONS"], defaultValue: 3)
        let cases = Self.benchmarkCases(environment: environment)
        let service = ScanArchiveService()
        let formatVersions =
            environment["RADIX_BENCH_ARCHIVE_COMPARE_FORMATS"] == "1"
            ? [4, ScanArchiveService.currentFormatVersion]
            : [ScanArchiveService.currentFormatVersion]

        for benchmarkCase in cases {
            let snapshot = benchmarkCase.makeSnapshot()

            for formatVersion in formatVersions {
                for iteration in 1...iterations {
                    let archiveURL = try makeTemporaryArchiveURL(
                        caseName: "\(benchmarkCase.name)-v\(formatVersion)",
                        iteration: iteration
                    )
                    let exportMeasurement = try await Self.measureMemoryAndTime {
                        try await service.export(
                            snapshot: snapshot,
                            to: archiveURL,
                            options: ScanArchiveExportOptions(
                                appVersion: "ArchiveBenchmark",
                                formatVersion: formatVersion
                            )
                        )
                    }
                    let archiveSize = try Self.directoryLogicalSize(archiveURL)
                    let sectionSizes = try Self.sectionSizes(archiveURL)

                    let importMeasurement = try await Self.measureMemoryAndTime {
                        try await service.importSnapshot(from: archiveURL)
                    }

                    let importedSnapshot = importMeasurement.value.snapshot
                    #expect(importedSnapshot.treeStore.nodeCount == snapshot.treeStore.nodeCount)
                    #expect(importedSnapshot.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
                    #expect(
                        importedSnapshot.aggregateStats.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize
                    )
                    #expect(importedSnapshot.aggregateStats.fileCount == snapshot.aggregateStats.fileCount)

                    print(
                        Self.resultLine(
                            benchmarkCase: benchmarkCase,
                            formatVersion: formatVersion,
                            iteration: iteration,
                            snapshot: snapshot,
                            export: exportMeasurement,
                            imported: importMeasurement,
                            archiveSize: archiveSize,
                            sectionSizes: sectionSizes
                        ))
                }
            }
        }
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_IMPORT_PATH"] != nil,
            "Set RADIX_BENCH_IMPORT_PATH to profile a real snapshot import."))
    func testRealSnapshotImportCostProfileBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let archivePath = environment["RADIX_BENCH_IMPORT_PATH"] else {
            throw TestFixtureError("Set RADIX_BENCH_IMPORT_PATH to profile a real snapshot import.")
        }

        let archiveURL = URL(filePath: archivePath, directoryHint: .isDirectory)
        let importPhases = ImportPhaseRecorder()
        let service = ScanArchiveService { phase, duration in
            importPhases.record(phase, duration: duration)
        }
        let imported = try await Self.measureMemoryAndTime {
            try await service.importSnapshot(from: archiveURL)
        }
        guard imported.value.manifest.formatVersion >= 4 else {
            throw TestFixtureError("Real snapshot import profiling requires a compact v4 or newer archive.")
        }

        #expect(imported.value.snapshot.treeStore.nodeCount == imported.value.manifest.snapshot.nodeCount)
        let phaseSummary = importPhases.measurements().map { phase, duration in
            "\(phase.rawValue)=\(Self.secondsString(BenchmarkSupport.durationSeconds(duration)))"
        }.joined(separator: " ")
        print(
            """
            RADIX_IMPORT_PROFILE_RESULT nodes=\(imported.value.manifest.snapshot.nodeCount) \
            import_seconds=\(Self.secondsString(imported.elapsedSeconds)) \
            import_peak_rss_delta=\(imported.peakDeltaRSS) \(phaseSummary)
            """
        )
    }

    @Test(
        .tags(.benchmark),
        .enabled(
            if: ProcessInfo.processInfo.environment["RADIX_BENCH_COMPARISON_BEFORE"] != nil,
            "Set RADIX_BENCH_COMPARISON_BEFORE and RADIX_BENCH_COMPARISON_AFTER to benchmark real snapshot comparison.")
    )
    func testRealSnapshotComparisonBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let beforePath = environment["RADIX_BENCH_COMPARISON_BEFORE"],
            let afterPath = environment["RADIX_BENCH_COMPARISON_AFTER"]
        else {
            throw TestFixtureError(
                "Set RADIX_BENCH_COMPARISON_BEFORE and RADIX_BENCH_COMPARISON_AFTER to benchmark real snapshot comparison."
            )
        }

        let service = ScanArchiveService()
        let beforeURL = URL(filePath: beforePath, directoryHint: .isDirectory)
        let afterURL = URL(filePath: afterPath, directoryHint: .isDirectory)
        let concurrentImports = environment["RADIX_BENCH_COMPARISON_CONCURRENT_IMPORTS"] == "1"
        let imports = try await Self.measureMemoryAndTime {
            if concurrentImports {
                async let before = service.importSnapshot(from: beforeURL)
                async let after = service.importSnapshot(from: afterURL)
                return try await (before, after)
            }
            let before = try await service.importSnapshot(from: beforeURL)
            let after = try await service.importSnapshot(from: afterURL)
            return (before, after)
        }
        let comparisonPhases = ComparisonPhaseRecorder()
        let comparisonService = ScanComparisonService { phase, duration in
            comparisonPhases.record(phase, duration: duration)
        }
        let comparison = try await Self.measureMemoryAndTime {
            try await comparisonService.compare(
                before: imports.value.0.snapshot,
                after: imports.value.1.snapshot
            )
        }

        #expect(comparison.value.summary.beforeFileCount == imports.value.0.snapshot.aggregateStats.fileCount)
        #expect(comparison.value.summary.afterFileCount == imports.value.1.snapshot.aggregateStats.fileCount)
        #expect(
            comparison.value.rows.count == comparison.value.summary.addedCount
                + comparison.value.summary.removedCount
                + comparison.value.summary.grewCount
                + comparison.value.summary.shrankCount
                + comparison.value.summary.movedCount)

        print(
            """
            RADIX_COMPARISON_BENCH_RESULT before_nodes=\(imports.value.0.snapshot.treeStore.nodeCount) \
            after_nodes=\(imports.value.1.snapshot.treeStore.nodeCount) rows=\(comparison.value.rows.count) \
            concurrent_imports=\(concurrentImports ? 1 : 0) \
            import_seconds=\(Self.secondsString(imports.elapsedSeconds)) \
            import_peak_rss_delta=\(imports.peakDeltaRSS) \
            comparison_seconds=\(Self.secondsString(comparison.elapsedSeconds)) \
            comparison_peak_rss_delta=\(comparison.peakDeltaRSS)
            """
        )
        let phaseSummary = comparisonPhases.measurements().map { phase, duration in
            "\(phase.rawValue)=\(Self.secondsString(BenchmarkSupport.durationSeconds(duration)))"
        }.joined(separator: " ")
        print("RADIX_COMPARISON_PROFILE_RESULT \(phaseSummary)")
    }

    private struct BenchmarkCase {
        let name: String
        let detail: String
        let makeSnapshot: () -> ScanSnapshot
    }

    private struct Measurement<Value> {
        let value: Value
        let elapsedSeconds: Double
        let startRSS: UInt64
        let endRSS: UInt64
        let peakRSS: UInt64

        var peakDeltaRSS: UInt64 {
            peakRSS > startRSS ? peakRSS - startRSS : 0
        }
    }

    private final class ComparisonPhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var durationsByPhase: [ScanComparisonProfilePhase: Duration] = [:]

        func record(_ phase: ScanComparisonProfilePhase, duration: Duration) {
            lock.lock()
            durationsByPhase[phase, default: .zero] += duration
            lock.unlock()
        }

        func measurements() -> [(ScanComparisonProfilePhase, Duration)] {
            lock.lock()
            defer { lock.unlock() }
            return ScanComparisonProfilePhase.allCases.compactMap { phase in
                durationsByPhase[phase].map { (phase, $0) }
            }
        }
    }

    private final class ImportPhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var durationsByPhase: [ScanArchiveImportProfilePhase: Duration] = [:]

        func record(_ phase: ScanArchiveImportProfilePhase, duration: Duration) {
            lock.lock()
            durationsByPhase[phase, default: .zero] += duration
            lock.unlock()
        }

        func measurements() -> [(ScanArchiveImportProfilePhase, Duration)] {
            lock.lock()
            defer { lock.unlock() }
            return ScanArchiveImportProfilePhase.allCases.compactMap { phase in
                durationsByPhase[phase].map { (phase, $0) }
            }
        }
    }

    private static func measureMemoryAndTime<Value>(
        _ operation: @escaping () async throws -> Value
    ) async rethrows -> Measurement<Value> {
        let startRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        let sampler = BenchmarkMemorySampler(initialRSS: startRSS)
        let samplerTask = Task {
            while !Task.isCancelled {
                sampler.sample()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let start = ContinuousClock.now
        let value = try await operation()
        let elapsed = start.duration(to: .now)
        samplerTask.cancel()
        _ = await samplerTask.result
        sampler.sample()
        let endRSS = BenchmarkMemorySampler.currentResidentMemoryBytes()
        return Measurement(
            value: value,
            elapsedSeconds: BenchmarkSupport.durationSeconds(elapsed),
            startRSS: startRSS,
            endRSS: endRSS,
            peakRSS: max(sampler.peak(), endRSS)
        )
    }

    private static func benchmarkCases(environment: [String: String]) -> [BenchmarkCase] {
        [
            smallCase(),
            wideCase(environment: environment),
            deepCase(environment: environment),
            largeCase(environment: environment),
        ]
    }

    private static func smallCase() -> BenchmarkCase {
        BenchmarkCase(name: "small", detail: "nodes=7") {
            makeSmallSnapshot()
        }
    }

    private static func wideCase(environment: [String: String]) -> BenchmarkCase {
        let fileCount = integer(from: environment["RADIX_BENCH_ARCHIVE_WIDE_FILES"], defaultValue: 10_000)
        return BenchmarkCase(name: "wide", detail: "files=\(fileCount)") {
            makeWideSnapshot(fileCount: fileCount)
        }
    }

    private static func deepCase(environment: [String: String]) -> BenchmarkCase {
        let depth = integer(from: environment["RADIX_BENCH_ARCHIVE_DEEP_DEPTH"], defaultValue: 12_000)
        return BenchmarkCase(name: "deep", detail: "depth=\(depth)") {
            makeDeepSnapshot(depth: depth)
        }
    }

    private static func largeCase(environment: [String: String]) -> BenchmarkCase {
        let directoryCount = integer(from: environment["RADIX_BENCH_ARCHIVE_LARGE_DIRS"], defaultValue: 64)
        let filesPerDirectory = integer(
            from: environment["RADIX_BENCH_ARCHIVE_LARGE_FILES_PER_DIR"], defaultValue: 1_000)
        return BenchmarkCase(name: "large", detail: "dirs=\(directoryCount),files_per_dir=\(filesPerDirectory)") {
            makeLargeFanoutSnapshot(directoryCount: directoryCount, filesPerDirectory: filesPerDirectory)
        }
    }

    private static func makeSmallSnapshot() -> ScanSnapshot {
        let fileA = makeBenchmarkFile(id: "/archive/folder/hard-link-a.bin", size: 100, unduplicatedSize: 40)
        let fileB = makeBenchmarkFile(id: "/archive/folder/resource-id.bin", size: 80)
        let inaccessible = FileNodeRecord(
            id: "/archive/folder/private.txt",
            url: URL(filePath: "/archive/folder/private.txt"),
            name: "private.txt",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 50,
            logicalSize: 50,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let summarized = FileNodeRecord(
            id: "/archive/folder/tiny-cache",
            url: URL(filePath: "/archive/folder/tiny-cache", directoryHint: .isDirectory),
            name: "tiny-cache",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 30,
            logicalSize: 35,
            descendantFileCount: 400,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let folder = FileNodeRecord.directory(
            id: "/archive/folder",
            url: URL(filePath: "/archive/folder", directoryHint: .isDirectory),
            name: "folder",
            children: [fileA, fileB, inaccessible, summarized],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let synthetic = FileNodeRecord(
            id: "/archive#system-unattributed",
            url: URL(filePath: "/archive", directoryHint: .isDirectory),
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 10,
            logicalSize: 10,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let root = FileNodeRecord.directory(
            id: "/archive",
            url: URL(filePath: "/archive", directoryHint: .isDirectory),
            name: "Archive",
            children: [folder, synthetic],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, synthetic],
                folder.id: [fileA, fileB, inaccessible, summarized],
            ])
        return makeSnapshot(root: root, store: store, warningPath: inaccessible.id)
    }

    private static func makeWideSnapshot(fileCount: Int) -> ScanSnapshot {
        let children = (0..<fileCount).map { index in
            makeBenchmarkFile(
                id: "/wide/file-\(String(format: "%08d", index)).dat",
                size: Int64(fileCount - index)
            )
        }
        let root = FileNodeRecord.directory(
            id: "/wide",
            url: URL(filePath: "/wide", directoryHint: .isDirectory),
            name: "wide",
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        return makeSnapshot(root: root, store: store)
    }

    private static func makeDeepSnapshot(depth: Int) -> ScanSnapshot {
        precondition(depth > 0)

        let rootID = "/deep"
        var nodesByID: [String: FileNodeRecord] = [
            rootID: makeBenchmarkDirectory(id: rootID, size: 64, descendantFileCount: 1)
        ]
        var childIDsByID: [String: [String]] = [:]
        var parentID = rootID

        for index in 1...depth {
            let nodeID = "/deep/node-\(String(format: "%05d", index))"
            let node =
                index == depth
                ? makeBenchmarkFile(id: nodeID, size: 64)
                : makeBenchmarkDirectory(id: nodeID, size: 64, descendantFileCount: 1)
            nodesByID[nodeID] = node
            childIDsByID[parentID] = [nodeID]
            parentID = nodeID
        }

        let store = FileTreeStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        return makeSnapshot(root: store.root, store: store)
    }

    private static func makeLargeFanoutSnapshot(directoryCount: Int, filesPerDirectory: Int) -> ScanSnapshot {
        var childrenByID: [String: [FileNodeRecord]] = [:]
        var directories: [FileNodeRecord] = []
        directories.reserveCapacity(directoryCount)

        for directoryIndex in 0..<directoryCount {
            let directoryID = "/large/group-\(String(format: "%04d", directoryIndex))"
            let files = (0..<filesPerDirectory).map { fileIndex in
                makeBenchmarkFile(
                    id: "\(directoryID)/file-\(String(format: "%08d", fileIndex)).dat",
                    size: Int64((directoryCount - directoryIndex) + (filesPerDirectory - fileIndex))
                )
            }
            let directory = FileNodeRecord.directory(
                id: directoryID,
                url: URL(filePath: directoryID, directoryHint: .isDirectory),
                name: "group-\(String(format: "%04d", directoryIndex))",
                children: files,
                lastModified: nil,
                isPackage: false,
                isAccessible: true
            )
            directories.append(directory)
            childrenByID[directoryID] = files
        }

        let root = FileNodeRecord.directory(
            id: "/large",
            url: URL(filePath: "/large", directoryHint: .isDirectory),
            name: "large",
            children: directories,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        childrenByID[root.id] = directories
        let store = FileTreeStore(root: root, childrenByID: childrenByID)
        return makeSnapshot(root: root, store: store)
    }

    private static func makeBenchmarkFile(
        id: String,
        size: Int64,
        unduplicatedSize: Int64? = nil
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: size,
            unduplicatedAllocatedSize: unduplicatedSize,
            logicalSize: size,
            descendantFileCount: 1,
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            fileIdentity: nil,
            linkCount: 1,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private static func makeBenchmarkDirectory(
        id: String,
        size: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: URL(filePath: id, directoryHint: .isDirectory).lastPathComponent,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: size,
            logicalSize: size,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private static func makeSnapshot(root: FileNodeRecord, store: FileTreeStore, warningPath: String? = nil)
        -> ScanSnapshot
    {
        let warnings =
            warningPath.map {
                [ScanWarning(path: $0, message: "Permission denied", category: .permissionDenied)]
            } ?? []
        return ScanSnapshot(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            target: ScanTarget(id: root.id, url: root.url, displayName: root.name, kind: .folder),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_005),
            scanWarnings: warnings,
            isComplete: true,
            scanOptions: ScanOptions()
        )
    }

    private func makeTemporaryArchiveURL(caseName: String, iteration: Int) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "radix-archive-bench-\(caseName)-\(iteration)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryFiles.track(directoryURL)
        return directoryURL.appending(path: "Export.radixscan", directoryHint: .isDirectory)
    }

    private static func directoryLogicalSize(_ directoryURL: URL) throws -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    private static func sectionSizes(_ archiveURL: URL) throws -> [String: UInt64] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: archiveURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        var result: [String: UInt64] = [:]
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            result[url.lastPathComponent] = UInt64(values.fileSize ?? 0)
        }
        return result
    }

    private static func resultLine(
        benchmarkCase: BenchmarkCase,
        formatVersion: Int,
        iteration: Int,
        snapshot: ScanSnapshot,
        export: Measurement<ScanArchiveExportResult>,
        imported: Measurement<ScanArchiveImportResult>,
        archiveSize: UInt64,
        sectionSizes: [String: UInt64]
    ) -> String {
        let sections =
            sectionSizes
            .sorted { $0.key < $1.key }
            .map { "section_\($0.key.replacingOccurrences(of: ".", with: "_"))=\($0.value)" }
            .joined(separator: " ")
        return """
            RADIX_ARCHIVE_BENCH_RESULT case=\(benchmarkCase.name) format_version=\(formatVersion) \
            detail=\(benchmarkCase.detail) iteration=\(iteration) \
            nodes=\(snapshot.treeStore.nodeCount) files=\(snapshot.aggregateStats.fileCount) directories=\(snapshot.aggregateStats.directoryCount) \
            warnings=\(snapshot.scanWarnings.count) export=\(secondsString(export.elapsedSeconds)) import=\(secondsString(imported.elapsedSeconds)) \
            package_bytes=\(archiveSize) export_peak_rss_delta=\(export.peakDeltaRSS) import_peak_rss_delta=\(imported.peakDeltaRSS) \(sections)
            """
    }

    private static func integer(from value: String?, defaultValue: Int) -> Int {
        value.flatMap(Int.init).map { max(1, $0) } ?? defaultValue
    }

    private static func secondsString(_ seconds: Double) -> String {
        BenchmarkSupport.format(seconds)
    }
}
