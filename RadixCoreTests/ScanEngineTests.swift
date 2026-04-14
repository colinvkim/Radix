import XCTest
@testable import RadixCore

final class ScanEngineTests: XCTestCase {
    func testPackagesAreLeafNodesByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.isDirectory)
        XCTAssertFalse(packageNode.containsChildren)
        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, Int64("binary".utf8.count))
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testPackageLeafNodesIncludeNestedPackageContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Host.app", directoryHint: .isDirectory)
        let nestedPackageURL = packageURL.appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
        let nestedBinaryURL = nestedPackageURL.appending(path: "Contents/MacOS/NestedBinary")

        try FileManager.default.createDirectory(at: nestedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: nestedBinaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Host.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, 2_048)
    }

    func testPackageLeafSizesIgnoreNestedDirectoryEntries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Deep.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/Frameworks/A.framework/Resources/B.bundle/C.txt")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 1_024).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Deep.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 1_024)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 1_024)
    }

    func testPackagesCanBeExpandedWhenEnabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(treatPackagesAsDirectories: true)
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.containsChildren)
        XCTAssertEqual(packageNode.descendantFileCount, 1)
    }

    func testAtomicPackageAccessFailuresProduceWarnings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Locked.app", directoryHint: .isDirectory)
        let readableFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let unreadableDirectoryURL = packageURL.appending(path: "Contents/Private")
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "Secret.dat")

        try FileManager.default.createDirectory(at: readableFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: readableFileURL)
        try Data("secret".utf8).write(to: unreadableFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDirectoryURL.path)
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Locked.app" }))

        XCTAssertFalse(packageNode.isAccessible)
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertTrue(snapshot.scanWarnings.contains(where: { $0.path.contains("Locked.app") }))
    }

    func testPackageLeafExcludesHiddenContentsWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let visibleFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let hiddenFileURL = packageURL.appending(path: "Contents/Resources/.secret")

        try FileManager.default.createDirectory(at: visibleFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 256).write(to: hiddenFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(includeHiddenFiles: false)
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 128)
    }

    func testSymbolicLinksAreNotTraversed() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let nestedFile = realDirectory.appending(path: "payload.txt")
        let symlinkURL = rootURL.appending(path: "Alias")

        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let aliasNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Alias" }))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertFalse(aliasNode.containsChildren)
        XCTAssertEqual(aliasNode.itemKind, "Alias")
        XCTAssertEqual(aliasNode.descendantFileCount, 0)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testScanTargetNormalizesSyntheticRootAliases() {
        let nofollowTarget = ScanTarget(url: URL(filePath: "/.nofollow/Users/example", directoryHint: .isDirectory))
        let resolveTarget = ScanTarget(url: URL(filePath: "/.resolve/System/Volumes/Data", directoryHint: .isDirectory))
        let rootAliasTarget = ScanTarget(url: URL(filePath: "/.nofollow", directoryHint: .isDirectory))

        XCTAssertEqual(nofollowTarget.url.path, "/Users/example")
        XCTAssertEqual(resolveTarget.url.path, "/System/Volumes/Data")
        XCTAssertEqual(rootAliasTarget.url.path, "/")
        XCTAssertEqual(rootAliasTarget.kind, .volume)
    }

    func testStartupVolumeScanExcludesSyntheticAndDuplicateNamespaces() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.nofollow", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Library", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testVolumeSnapshotAddsSystemAndUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)

        let engine = ScanEngine()
        let target = ScanTarget(url: rootURL, kind: .volume)
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: target, options: ScanOptions()) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let syntheticNode = try XCTUnwrap(snapshot.root.children.first(where: \.isSynthetic))

        XCTAssertEqual(syntheticNode.name, "System & Unattributed")
        XCTAssertTrue(syntheticNode.isAccessible)
        XCTAssertTrue(snapshot.root.isAccessible)
        XCTAssertFalse(syntheticNode.supportsFileActions)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.children.filter { !$0.isSynthetic }.reduce(0) { $0 + $1.allocatedSize })
    }

    func testDirectoryChildrenAreOrderedDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alpha = rootURL.appending(path: "alpha.txt")
        let zeta = rootURL.appending(path: "zeta.txt")

        try Data(repeating: 0x41, count: 16).write(to: zeta)
        try Data(repeating: 0x42, count: 16).write(to: alpha)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertEqual(snapshot.root.children.map(\.name), ["alpha.txt", "zeta.txt"])
    }

    func testProgressFractionIsMonotonicAndCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<3 {
            let directoryURL = rootURL.appending(path: "Folder-\(directoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<4 {
                let fileURL = directoryURL.appending(path: "File-\(fileIndex).txt")
                try Data(repeating: UInt8(fileIndex), count: 1_024).write(to: fileURL)
            }
        }

        let engine = ScanEngine()
        var progressFractions: [Double] = []

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            }
        }

        XCTAssertFalse(progressFractions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressFractions.last), 1, accuracy: 0.0001)

        for pair in zip(progressFractions, progressFractions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
        }
    }

    func testEmptyDirectoryScanProducesEmptyRootNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertTrue(snapshot.root.isDirectory)
        XCTAssertEqual(snapshot.root.url.path, rootURL.path)
        XCTAssertTrue(snapshot.root.children.isEmpty)
        XCTAssertEqual(snapshot.aggregateStats.directoryCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 0)
    }

    func testEmptySubdirectoryIsRetainedInTree() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let emptyDirectoryURL = rootURL.appending(path: "Empty", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.txt")

        try FileManager.default.createDirectory(at: emptyDirectoryURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let emptyNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Empty" }))
        XCTAssertTrue(emptyNode.isDirectory)
        XCTAssertTrue(emptyNode.children.isEmpty)
        XCTAssertEqual(emptyNode.descendantFileCount, 0)
    }

    func testByteEstimatePreventsPrematureFinalizingProgress() {
        var metrics = ScanMetrics()
        metrics.estimatedTotalBytes = 10_000
        metrics.discoveredItems = 6
        metrics.completedItems = 5
        metrics.filesVisited = 500
        metrics.bytesDiscovered = 1_200

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.5)
        XCTAssertFalse(metrics.isFinalizing)
    }

    func testDirectoryBelowThresholdNotAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory with small files — well below the default 5,000-file threshold
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 100 small files — below the default 5,000 threshold
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)  // 64 bytes each
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        // The cache directory should NOT be auto-summarized (only 100 files, below threshold)
        // This test verifies the mechanism doesn't trigger at low file counts
        let cacheNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with only 100 files should not be auto-summarized")
        XCTAssertTrue(cacheNode.isDirectory)
        XCTAssertTrue(cacheNode.containsChildren)
    }

    func testAutoSummarizedDirectoryShowsFileCount() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a regular file for comparison
        let fileURL = rootURL.appending(path: "document.txt")
        try Data("Hello, World!".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let fileNode = try XCTUnwrap(snapshot.root.children.first)
        XCTAssertFalse(fileNode.isAutoSummarized)
        XCTAssertEqual(fileNode.itemKind, "File")
        XCTAssertNil(fileNode.secondaryStatusText)
    }

    func testAutoSummarizeCanBeDisabledViaOptions() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a deep directory structure
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create many small files
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)
        }

        // Scan with autoSummarize disabled
        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        // Even with many files, the directory should NOT be auto-summarized
        let cacheNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(cacheNode.containsChildren)
        XCTAssertEqual(cacheNode.children.count, 100)
    }

    func testDirectoryIsAutoSummarizedWithLowThresholds() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2: rootURL/projects/cache/
        // Depth 0 = rootURL, depth 1 = projects, depth 2 = cache
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 20 small files — enough to trigger with low thresholds
        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)  // 32 bytes each
        }

        // Use low thresholds: min 10 files, max 256 bytes average, min depth 2
        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(projectsNode.children.first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized, "Directory should be auto-summarized with low thresholds")
        XCTAssertFalse(cacheNode.containsChildren, "Auto-summarized directory should have no children")
        XCTAssertEqual(cacheNode.descendantFileCount, 20, "Should report correct file count")
        XCTAssertEqual(cacheNode.itemKind, "Summarized")
        XCTAssertEqual(cacheNode.secondaryStatusText, "Summarized (20 files)")
    }

    func testDirectoryNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2 with 20 LARGE files
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).dat")
            try Data(repeating: UInt8(i % 256), count: 100_000).write(to: fileURL)  // 100 KB each
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 4_096  // 4 KB max average
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(projectsNode.children.first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with large files should not be auto-summarized")
        XCTAssertTrue(cacheNode.containsChildren)
        XCTAssertEqual(cacheNode.children.count, 20)
    }

    func testAutoSummarizedDirectoryExcludesHiddenFilesWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        for i in 0..<3 {
            let hiddenFileURL = cacheURL.appending(path: ".hidden_\(i).tmp")
            try Data(repeating: 0x7F, count: 32).write(to: hiddenFileURL)
        }

        var options = ScanOptions(includeHiddenFiles: false)
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(projectsNode.children.first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
        XCTAssertEqual(cacheNode.logicalSize, 12 * 32)
    }
}

private func finishedSnapshot(target: ScanTarget, options: ScanOptions) async throws -> ScanSnapshot {
    let engine = ScanEngine()

    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    XCTFail("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
