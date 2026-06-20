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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.isDirectory)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Host.app" }))

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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Deep.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 1_024)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 1_024)
    }

    func testPackageRootHardLinksOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Linked.app", directoryHint: .isDirectory)
        let originalURL = packageURL.appending(path: "Contents/Resources/original.bin")
        let linkedURL = packageURL.appending(path: "Contents/Resources/linked.bin")

        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCA, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions()
        )

        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 8_192)
        XCTAssertGreaterThan(snapshot.root.allocatedSize, 0)
        XCTAssertLessThan(snapshot.root.allocatedSize, snapshot.root.logicalSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testParallelPackageSummaryMatchesSerialSummary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Parallel.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Parallel")
        let resourceURL = packageURL.appending(path: "Contents/Resources/Data/blob.dat")
        let hiddenURL = packageURL.appending(path: "Contents/Resources/.hidden")
        let nestedPackageBinaryURL = packageURL
            .appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Nested")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: binaryURL)
        try Data(repeating: 0x2, count: 256).write(to: resourceURL)
        try Data(repeating: 0x3, count: 512).write(to: hiddenURL)
        try Data(repeating: 0x4, count: 1_024).write(to: nestedPackageBinaryURL)

        var serialOptions = ScanOptions()
        serialOptions.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.atomicSummaryWorkerLimit = 2

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try XCTUnwrap(rootChildren(in: serialSnapshot).first(where: { $0.name == "Parallel.app" }))
        let parallelPackageNode = try XCTUnwrap(rootChildren(in: parallelSnapshot).first(where: { $0.name == "Parallel.app" }))

        XCTAssertEqual(parallelPackageNode.descendantFileCount, serialPackageNode.descendantFileCount)
        XCTAssertEqual(parallelPackageNode.logicalSize, serialPackageNode.logicalSize)
        XCTAssertEqual(parallelPackageNode.allocatedSize, serialPackageNode.allocatedSize)
        XCTAssertEqual(parallelPackageNode.isAccessible, serialPackageNode.isAccessible)
        XCTAssertEqual(parallelPackageNode.isSelfAccessible, serialPackageNode.isSelfAccessible)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(containsChildren(packageNode, in: snapshot))
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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked.app" }))

        XCTAssertFalse(packageNode.isAccessible)
        XCTAssertFalse(snapshot.scanWarnings.isEmpty)
        XCTAssertTrue(snapshot.scanWarnings.contains(where: { $0.path.contains("Locked.app") }))
    }

    func testUnreadableOrdinaryDirectoryProducesWarningAndContinuesScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableFileURL = rootURL.appending(path: "visible.txt")
        let unreadableDirectoryURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "secret.txt")

        try Data("visible".utf8).write(to: readableFileURL)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: unreadableFileURL)
        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url.lastPathComponent == "Locked" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedNode.url.path }))

        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isPackage)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertEqual(lockedNode.allocatedSize, 0)
        XCTAssertEqual(lockedNode.logicalSize, 0)
        XCTAssertEqual(lockedNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testLocalizedChildEnumerationFailureKeepsReadableSiblings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableDirectoryURL = rootURL.appending(path: "Readable", directoryHint: .isDirectory)
        let readableFileURL = readableDirectoryURL.appending(path: "nested.txt")
        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let lockedURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: readableDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: readableFileURL)
        try Data("visible".utf8).write(to: visibleFileURL)

        let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [readableDirectoryURL, visibleFileURL],
                    localizedFailures: [
                        ScanEngine.DirectoryEnumerationFailure(
                            url: lockedURL,
                            error: permissionError,
                            isDirectoryHint: true
                        )
                    ]
                )
            }

            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
            return ScanEngine.DirectoryEnumerationResult(urls: urls)
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )

        let rootChildNames = rootChildren(in: snapshot).map(\.name)
        let readableNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Readable" }))
        let visibleNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let lockedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let warning = try XCTUnwrap(snapshot.scanWarnings.first(where: { $0.path == lockedURL.path }))

        XCTAssertEqual(Set(rootChildNames), Set(["Locked", "Readable", "visible.txt"]))
        XCTAssertEqual(children(of: readableNode, in: snapshot).map(\.name), ["nested.txt"])
        XCTAssertTrue(visibleNode.isAccessible)
        XCTAssertTrue(lockedNode.isDirectory)
        XCTAssertFalse(lockedNode.isAccessible)
        XCTAssertFalse(containsChildren(lockedNode, in: snapshot))
        XCTAssertEqual(warning.category, .permissionDenied)
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
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
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertGreaterThanOrEqual(packageNode.allocatedSize, 128)
    }

    func testExcludesBasenameDirectoryLikeNodeModules() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let nodeModulesFileURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: "left-pad/index.js")

        try FileManager.default.createDirectory(at: nodeModulesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 16).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 128).write(to: nodeModulesFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 16)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testExcludesFilesByGlob() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 32)
            .write(to: rootURL.appending(path: "notes.txt"))
        try Data(repeating: 0x2, count: 256)
            .write(to: rootURL.appending(path: "debug.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["notes.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesDirectoryOnlyPatternsWithoutExcludingSameNamedFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 256).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 32).write(to: rootURL.appending(path: "build"))

        var options = ScanOptions()
        options.exclusionPatterns = ["build/"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let nestedNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "nested" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["build", "nested"])
        XCTAssertTrue(children(of: nestedNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 32)
    }

    func testExcludesPathGlobPatternsRelativeToScanRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let libraryCacheFileURL = rootURL
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: "ignored.bin")
        let topLevelCacheFileURL = rootURL
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "kept.bin")

        try FileManager.default.createDirectory(at: libraryCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topLevelCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: libraryCacheFileURL)
        try Data(repeating: 0x2, count: 64).write(to: topLevelCacheFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["Library/Caches/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let cachesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Caches" }))
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(children(of: cachesNode, in: snapshot).map(\.name), ["kept.bin"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testExcludesDoubleStarPathGlobPatterns() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "project/build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        let keptFileURL = rootURL
            .appending(path: "project/Sources", directoryHint: .isDirectory)
            .appending(path: "main.swift")

        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 128).write(to: keptFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["**/build/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let projectNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "project" }))

        XCTAssertEqual(children(of: projectNode, in: snapshot).map(\.name), ["Sources"])
        XCTAssertEqual(projectNode.descendantFileCount, 1)
        XCTAssertEqual(projectNode.logicalSize, 128)
    }

    func testExcludesDSStoreEvenWhenHiddenFilesAreIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 24)
            .write(to: rootURL.appending(path: "visible.txt"))
        try Data(repeating: 0x2, count: 512)
            .write(to: rootURL.appending(path: ".DS_Store"))

        var options = ScanOptions(includeHiddenFiles: true)
        options.exclusionPatterns = [".DS_Store"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["visible.txt"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 24)
    }

    func testSkipsCloudStorageFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "GoogleDrive-example", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testCloudStorageFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let cloudStorageNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "CloudStorage" }))
        let providerNode = try XCTUnwrap(children(of: cloudStorageNode, in: snapshot).first(where: { $0.name == "Dropbox" }))

        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testSkipsICloudDriveFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name).sorted(), ["Library", "local.txt"])
        XCTAssertTrue(children(of: libraryNode, in: snapshot).isEmpty)
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 64)
    }

    func testICloudDriveFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let iCloudDriveNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Mobile Documents" }))
        let providerNode = try XCTUnwrap(children(of: iCloudDriveNode, in: snapshot).first(where: { $0.name == "com~apple~CloudDocs" }))

        XCTAssertEqual(children(of: providerNode, in: snapshot).map(\.name), ["remote.bin"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 2)
        XCTAssertEqual(snapshot.root.logicalSize, 576)
    }

    func testUsersCloudStorageWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage"), isDirectory: true))
        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false))
        XCTAssertFalse(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorageBackup"), isDirectory: true))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/CloudStorage",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        XCTAssertFalse(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false))
    }

    func testUsersICloudDriveWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents"), isDirectory: true))
        XCTAssertTrue(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))
        XCTAssertFalse(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents Backup"), isDirectory: true))

        let includingMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: true,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertFalse(includingMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/Mobile Documents",
            includeCloudStorage: false,
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        XCTAssertFalse(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))
    }

    func testExplicitCloudStorageFolderScanIsAllowedByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: cloudStorageURL),
            options: options
        )

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["Dropbox"])
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 512)
    }

    func testVolumeScanWithExclusionsDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 128)
            .write(to: rootURL.appending(path: "visible.txt"))

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        XCTAssertFalse(rootChildren(in: snapshot).contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testVolumeScanWithCloudStorageExclusionDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")

        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        XCTAssertFalse(rootChildren(in: snapshot).contains(where: \.isSynthetic))
        XCTAssertEqual(snapshot.root.descendantFileCount, 1)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
    }

    func testExcludedFilesDoNotContributeToParentSizeTotals() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataURL = rootURL.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 10)
            .write(to: dataURL.appending(path: "keep.bin"))
        try Data(repeating: 0x2, count: 90)
            .write(to: dataURL.appending(path: "ignored.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let dataNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Data" }))

        XCTAssertEqual(children(of: dataNode, in: snapshot).map(\.name), ["keep.bin"])
        XCTAssertEqual(dataNode.descendantFileCount, 1)
        XCTAssertEqual(dataNode.logicalSize, 10)
        XCTAssertEqual(snapshot.root.logicalSize, 10)
    }

    func testExcludedFilesDoNotContributeThroughPackageSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let keptFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let excludedFileURL = packageURL.appending(path: "Contents/Resources/debug.log")

        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludedFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: keptFileURL)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 128)
        XCTAssertEqual(snapshot.root.logicalSize, 128)
    }

    func testExcludedPackageContentsStillEmitSummaryProgress() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let excludedFileURL = packageURL.appending(path: "debug.log")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let engine = ScanEngine()
        var progressPaths: [String] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressPaths.append(metrics.currentPath)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let packageNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        XCTAssertEqual(packageNode.descendantFileCount, 0)
        XCTAssertFalse(containsChildren(packageNode, in: snapshot))
        XCTAssertTrue(
            progressPaths.contains(where: { $0.hasSuffix("/Sample.app/debug.log") }),
            "Expected package summary progress to include excluded file path"
        )
    }

    func testExcludedFilesDoNotContributeThroughAutoSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<10 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "keep.tmp"))
            try Data(repeating: 0x7F, count: 4_096)
                .write(to: shardURL.appending(path: "ignored.log"))
        }

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 10)
        XCTAssertEqual(cacheNode.logicalSize, 10 * 32)
    }

    func testCancellingScanStopsPackageLeafSummaryWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let packageContentsURL = rootURL
            .appending(path: "Large.app", directoryHint: .isDirectory)
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageContentsURL, withIntermediateDirectories: true)

        for index in 0..<8_000 {
            let fileURL = packageContentsURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await scanTask.value

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testCancellingScanStopsWideDirectoryEnumerationWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        for index in 0..<10_000 {
            let fileURL = rootURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(followUpFinished)
    }

    func testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let probe = BlockingDirectoryContentsProbe(blockedURL: rootURL)
        let engine = ScanEngine(directoryContents: { url, _, _, _ in
            try probe.contents(for: url)
        })
        let blockedScanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return didFinish
        }
        defer {
            probe.release()
            blockedScanTask.cancel()
        }

        try await probe.waitUntilBlocked()
        blockedScanTask.cancel()

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        probe.release()
        let blockedScanFinished = await blockedScanTask.value

        XCTAssertTrue(followUpFinished)
        XCTAssertFalse(blockedScanFinished)
    }

    func testEnumeratedDirectoryContentsChecksCancellationBeforeMaterializingAllURLs() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cancellation = DirectoryEnumerationCancellation()
        let enumerator = SlowDirectoryObjectEnumerator(rootURL: rootURL, totalCount: 10_000)
        let enumerationTask = Task {
            try ScanEngine.enumeratedDirectoryContents(
                url: rootURL,
                keys: nil,
                options: [],
                cancellationCheck: { try cancellation.check() },
                makeEnumerator: { _, _, _ in enumerator }
            )
        }

        try await enumerator.waitUntilProduced(64)
        cancellation.cancel()

        do {
            _ = try await withTimeout(.seconds(1)) {
                try await enumerationTask.value
            }
            XCTFail("Expected directory enumeration to stop after cancellation.")
        } catch is CancellationError {
            XCTAssertLessThan(enumerator.producedCount, enumerator.totalCount)
        }
    }

    func testCancellingScanStopsInjectedDirectoryEnumerationBeforeMaterialization() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probe = CancellableDirectoryContentsProbe(totalCount: 10_000)
        let engine = ScanEngine(directoryContents: { url, _, _, cancellationCheck in
            guard url == rootURL else { return [] }
            return try probe.contents(for: url, cancellationCheck: cancellationCheck)
        })
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await probe.waitUntilProduced(64)
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(1)) {
            try await scanTask.value
        }

        XCTAssertFalse(didFinishCancelledScan)
        XCTAssertLessThan(probe.producedCount, probe.totalCount)
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
        let aliasNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alias" }))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertFalse(containsChildren(aliasNode, in: snapshot))
        XCTAssertEqual(aliasNode.itemKind, "Alias")
        XCTAssertEqual(aliasNode.descendantFileCount, 0)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 1)
    }

    func testHardLinkedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")

        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
        XCTAssertEqual(children.map(\.logicalSize).reduce(0, +), 8_192)
        XCTAssertEqual(allocatedSizes.filter { $0 > 0 }.count, 1)
        XCTAssertEqual(snapshot.root.allocatedSize, allocatedSizes.reduce(0, +))
        XCTAssertTrue(children.allSatisfy { $0.fileIdentity != nil })
        XCTAssertEqual(children.map(\.linkCount), [2, 2])
        XCTAssertEqual(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count, 1)
        XCTAssertTrue(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })
    }

    func testParallelTraversalAssignsHardLinkStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaLinkURL = alphaDirectoryURL.appending(path: "linked.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4B, count: 4_096).write(to: betaOriginalURL)
        try FileManager.default.linkItem(at: betaOriginalURL, to: alphaLinkURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaLinkURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.directoryTraversalWorkerLimit = 2
        options.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try XCTUnwrap(children(of: alphaNode, in: snapshot).first)
        let betaFile = try XCTUnwrap(children(of: betaNode, in: snapshot).first)

        XCTAssertGreaterThan(alphaFile.allocatedSize, 0)
        XCTAssertEqual(betaFile.allocatedSize, 0)
        XCTAssertEqual(alphaNode.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(betaNode.allocatedSize, 0)
        XCTAssertEqual(snapshot.root.allocatedSize, alphaFile.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, 2)
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

    func testScanTargetResolvesSymlinkRoots() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let symlinkURL = rootURL.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let target = ScanTarget(url: symlinkURL)

        XCTAssertEqual(target.url.path, realDirectory.path)
        XCTAssertEqual(target.id, realDirectory.path)
    }

    func testStartupVolumeScanExcludesSyntheticAndDuplicateNamespaces() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.nofollow", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )
        )
        XCTAssertFalse(
            ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
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
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
        XCTAssertTrue(
            ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            )
        )
    }

    func testVolumeSnapshotAddsSystemAndUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let engine = ScanEngine()
        let target = ScanTarget(url: rootURL, kind: .volume)
        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: target, options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let syntheticNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: \.isSynthetic))

        XCTAssertEqual(syntheticNode.name, "System & Unattributed")
        XCTAssertTrue(syntheticNode.isAccessible)
        XCTAssertTrue(snapshot.root.isAccessible)
        XCTAssertFalse(syntheticNode.supportsFileActions)
        XCTAssertEqual(snapshot.aggregateStats.totalAllocatedSize, snapshot.root.allocatedSize)
        XCTAssertGreaterThanOrEqual(snapshot.aggregateStats.totalAllocatedSize, rootChildren(in: snapshot).filter { !$0.isSynthetic }.reduce(0) { $0 + $1.allocatedSize })
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

        XCTAssertEqual(rootChildren(in: snapshot).map(\.name), ["alpha.txt", "zeta.txt"])
    }

    func testParallelDirectoryClassificationMatchesSerialClassification() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "file-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: (index % 7) + 1).write(to: fileURL)
        }

        for index in 0..<16 {
            let directoryURL = rootURL.appending(path: String(format: "folder-%03d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 9).write(to: directoryURL.appending(path: "payload.txt"))
        }

        try Data(repeating: 0xA, count: 64).write(to: rootURL.appending(path: "excluded.log"))

        var serialOptions = ScanOptions()
        serialOptions.exclusionPatterns = ["*.log"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.exclusionPatterns = ["*.log"]
        parallelOptions.directoryTraversalWorkerLimit = 1
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertFalse(rootChildren(in: parallelSnapshot).contains(where: { $0.name == "excluded.log" }))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
    }

    func testParallelDirectoryTraversalAndClassificationMatchSerialScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "root-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: 8 + (index % 11)).write(to: fileURL)
        }

        for directoryIndex in 0..<8 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<160 {
                let fileURL = directoryURL.appending(path: String(format: "payload-%03d.bin", fileIndex))
                try Data(repeating: UInt8((directoryIndex + fileIndex) % 256), count: 4 + (fileIndex % 5)).write(to: fileURL)
            }

            try Data(repeating: 0xD, count: 32).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4
        parallelOptions.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
        }
    }

    func testParallelDirectoryTraversalMatchesSerialTraversal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<12 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<6 {
                let fileURL = directoryURL.appending(path: String(format: "direct-%02d.dat", fileIndex))
                try Data(repeating: UInt8(directoryIndex + fileIndex), count: 32 + directoryIndex + fileIndex).write(to: fileURL)
            }

            for nestedIndex in 0..<4 {
                let nestedURL = directoryURL.appending(path: String(format: "nested-%02d", nestedIndex), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

                for fileIndex in 0..<3 {
                    let fileURL = nestedURL.appending(path: String(format: "payload-%02d.bin", fileIndex))
                    try Data(repeating: UInt8(nestedIndex + fileIndex), count: 17 + nestedIndex + fileIndex).write(to: fileURL)
                }
            }

            try Data(repeating: 0xC, count: 128).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.directoryTraversalWorkerLimit = 1
        serialOptions.directoryClassificationWorkerLimit = 1
        serialOptions.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.directoryTraversalWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        XCTAssertEqual(rootChildren(in: parallelSnapshot).map(\.name), rootChildren(in: serialSnapshot).map(\.name))
        XCTAssertEqual(parallelSnapshot.root.descendantFileCount, serialSnapshot.root.descendantFileCount)
        XCTAssertEqual(parallelSnapshot.root.logicalSize, serialSnapshot.root.logicalSize)
        XCTAssertEqual(parallelSnapshot.root.allocatedSize, serialSnapshot.root.allocatedSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.fileCount, serialSnapshot.aggregateStats.fileCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.directoryCount, serialSnapshot.aggregateStats.directoryCount)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalLogicalSize, serialSnapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(parallelSnapshot.aggregateStats.totalAllocatedSize, serialSnapshot.aggregateStats.totalAllocatedSize)

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try XCTUnwrap(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            XCTAssertEqual(children(of: parallelChild, in: parallelSnapshot).map(\.name), children(of: serialChild, in: serialSnapshot).map(\.name))
        }
        XCTAssertFalse(parallelSnapshot.treeStore.nodesByID.keys.contains { $0.hasSuffix("ignored.skip") })
    }

    func testDuplicateAssemblyChildrenAreCollapsedBeforeDirectoryTotals() {
        let kept = makeScanEngineFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeScanEngineFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let sibling = makeScanEngineFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 7)

        let uniqueChildren = ScanEngine.uniqueNodesForAssembly([kept, dropped, sibling])
        let directory = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: uniqueChildren,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        XCTAssertEqual(uniqueChildren.map(\.name), ["kept.txt", "sibling.txt"])
        XCTAssertEqual(directory.allocatedSize, 12)
        XCTAssertEqual(directory.logicalSize, 12)
        XCTAssertEqual(directory.descendantFileCount, 2)
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

    func testFinalizationProgressIsEmittedDuringAssembly() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<700 {
            let directoryURL = rootURL.appending(path: "Folder-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let engine = ScanEngine()
        var finalizingProgress: [ScanMetrics] = []
        var didFinish = false

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            switch event {
            case .progress(let metrics) where metrics.isFinalizing:
                finalizingProgress.append(metrics)
            case .finished:
                didFinish = true
            case .progress, .warning:
                break
            }
        }

        XCTAssertTrue(didFinish)
        XCTAssertGreaterThanOrEqual(finalizingProgress.count, 2)

        for pair in zip(finalizingProgress, finalizingProgress.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.progressFraction, pair.0.progressFraction)
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
        XCTAssertTrue(rootChildren(in: snapshot).isEmpty)
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

        let emptyNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Empty" }))
        XCTAssertTrue(emptyNode.isDirectory)
        XCTAssertTrue(children(of: emptyNode, in: snapshot).isEmpty)
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

    func testTraversalWeightDrivesProgressWithoutByteEstimate() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 10
        metrics.completedTraversalWeight = 0.5

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, 0.5 * 0.95, accuracy: 0.0001)
    }

    func testDirectoryScanProgressStaysLowWhenLittleWeightIsCompleted() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 5_000
        metrics.discoveredItems = 5_200
        metrics.completedItems = 5_000
        metrics.bytesDiscovered = 50_000_000_000
        metrics.completedTraversalWeight = 0.02

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.05)
    }

    func testFrontierExtrapolationCapsProgressInSkewedTrees() {
        var metrics = ScanMetrics()
        // 2,000 flat files completed; one giant unexplored sibling directory remains.
        // The weight model alone would report ~99% here.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.35)
    }

    func testItemCountCapAppliesWhenFrontierDrainsButFilesRemain() {
        var metrics = ScanMetrics()
        // 1,000 sibling files completed, then one directory was enumerated and yielded
        // 5,000 flat files (no subdirectories), draining the frontier to zero. Most of the
        // discovered files are still unprocessed, but the weight model alone reports ~94%
        // because the 1,000 completed files held nearly all of the root's split weight.
        metrics.filesVisited = 1_000
        metrics.discoveredItems = 6_001
        metrics.completedItems = 1_000
        metrics.enumeratedDirectoryCount = 2
        metrics.pendingDirectoryCount = 0
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 1_000.0 / 1_008.0

        metrics.recalculateProgress()

        // The item-count cap, (completed + enumerated) / discovered ≈ 0.167, must hold the
        // bar near the true ~17% rather than letting the weight estimate jump to ~94%.
        XCTAssertLessThan(metrics.progressFraction, 0.30)
    }

    func testVolumeByteEstimateBlendsWithTraversalWeight() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.estimatedTotalBytes = 1_000
        metrics.bytesDiscovered = 500
        metrics.completedTraversalWeight = 0.3

        metrics.recalculateProgress()

        XCTAssertEqual(metrics.progressFraction, ((0.3 + 0.5) / 2) * 0.95, accuracy: 0.0001)
    }

    func testFinalizationProgressMapsAboveTraversalSpan() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.completedTraversalWeight = 1
        metrics.recalculateProgress()

        metrics.isFinalizing = true
        metrics.finalizationFraction = 0.5
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.97, accuracy: 0.0001)

        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        XCTAssertEqual(metrics.progressFraction, 0.99, accuracy: 0.0001)

        metrics.recalculateProgress(isComplete: true)
        XCTAssertEqual(metrics.progressFraction, 1, accuracy: 0.0001)
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
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with only 100 files should not be auto-summarized")
        XCTAssertTrue(cacheNode.isDirectory)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
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

        let fileNode = try XCTUnwrap(rootChildren(in: snapshot).first)
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
        let cacheNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 100)
    }

    func testCoreSimulatorDirectoryIsAutoSummarizedDespiteSparseImmediateChildren() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let coreSimulatorURL = rootURL.appending(
            path: "Library/Developer/CoreSimulator",
            directoryHint: .isDirectory
        )
        let appDataURL = coreSimulatorURL
            .appending(path: "Devices/00000000-0000-0000-0000-000000000001/data/Containers/Data/Application")
            .appending(path: "Example.appdata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)

        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 128)
                .write(to: appDataURL.appending(path: "payload-\(index).bin"))
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let libraryNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let developerNode = try XCTUnwrap(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Developer" }))
        let coreSimulatorNode = try XCTUnwrap(children(of: developerNode, in: snapshot).first(where: { $0.name == "CoreSimulator" }))

        XCTAssertTrue(coreSimulatorNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(coreSimulatorNode, in: snapshot))
        XCTAssertEqual(coreSimulatorNode.descendantFileCount, 3)
        XCTAssertGreaterThanOrEqual(coreSimulatorNode.logicalSize, 384)
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

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized, "Directory should be auto-summarized with low thresholds")
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot), "Auto-summarized directory should have no children")
        XCTAssertEqual(cacheNode.descendantFileCount, 20, "Should report correct file count")
        XCTAssertEqual(cacheNode.itemKind, "Summarized")
        XCTAssertEqual(cacheNode.secondaryStatusText, "Summarized (20 files)")
    }

    func testDeepTinyFileDirectoryIsAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
    }

    func testNodeModulesPnpmStoreAutoSummarizesAtShallowDepth() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/left-pad@1.3.0/node_modules/left-pad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: packageURL.appending(path: "file-\(index).js"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testScopedNodePackageContainerAutoSummarizesAtShallowDepth() async throws {
        let nodeModulesURL = try makeTemporaryDirectory().appending(path: "node_modules", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: nodeModulesURL.deletingLastPathComponent()) }

        let packageURL = nodeModulesURL
            .appending(path: "@radix-ui/colors/dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 24)
                .write(to: packageURL.appending(path: "token-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: nodeModulesURL),
            options: options
        )

        let scopeNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "@radix-ui" }))
        XCTAssertTrue(scopeNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(scopeNode, in: snapshot))
        XCTAssertEqual(scopeNode.descendantFileCount, 20)
    }

    func testNestedNodeModulesForestAutoSummarizesThroughSparseParent() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nodeModulesURL = rootURL
            .appending(path: "workspace/packages/app/node_modules", directoryHint: .isDirectory)
        let packageURL = nodeModulesURL
            .appending(path: "vite/dist/client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 40)
                .write(to: packageURL.appending(path: "chunk-\(index).js"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let workspaceNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "workspace" }))
        let packagesNode = try XCTUnwrap(children(of: workspaceNode, in: snapshot).first(where: { $0.name == "packages" }))
        let appNode = try XCTUnwrap(children(of: packagesNode, in: snapshot).first(where: { $0.name == "app" }))
        let nodeModulesNode = try XCTUnwrap(children(of: appNode, in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertTrue(nodeModulesNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(nodeModulesNode, in: snapshot))
        XCTAssertEqual(nodeModulesNode.descendantFileCount, 20)
    }

    func testSparseAncestorDefersAutoSummarizationToDenseDescendant() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        let denseURL = cacheURL.appending(path: "dense", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: denseURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: denseURL.appending(path: "payload-\(index).tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        let denseNode = try XCTUnwrap(children(of: cacheNode, in: snapshot).first(where: { $0.name == "dense" }))

        XCTAssertFalse(cacheNode.isAutoSummarized)
        XCTAssertTrue(denseNode.isAutoSummarized)
        XCTAssertFalse(containsChildren(denseNode, in: snapshot))
        XCTAssertEqual(denseNode.descendantFileCount, 20)
    }

    func testAutoSummarizedDirectoryIncludesPackageLeafContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        let packageBinaryURL = cacheURL
            .appending(path: "Tool.app", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Tool")
        try FileManager.default.createDirectory(at: packageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: packageBinaryURL)

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 13)
        XCTAssertGreaterThanOrEqual(cacheNode.logicalSize, (12 * 32) + 2_048)
    }

    func testAutoSummarizedDirectoryCountsAsSingleVisitedDirectory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var finalMetrics = ScanMetrics()

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .progress(let metrics) = event {
                finalMetrics = metrics
            }
        }

        XCTAssertEqual(finalMetrics.directoriesVisited, 3)
        XCTAssertEqual(finalMetrics.filesVisited, 20)
    }

    func testAutoSummarizedDirectoryReleasesChildDirectoryDiscoveryCounts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.autoSummarizeMinFileCount = 10
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var progressSnapshots: [ScanMetrics] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressSnapshots.append(metrics)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning:
                break
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        let finalMetrics = try XCTUnwrap(progressSnapshots.last)
        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(finalMetrics.enumeratedDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.discoveredDirectoryCount, 3)
        XCTAssertEqual(finalMetrics.pendingDirectoryCount, 0)
        XCTAssertEqual(finalMetrics.progressFraction, 1, accuracy: 0.0001)
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

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertFalse(cacheNode.isAutoSummarized, "Directory with large files should not be auto-summarized")
        XCTAssertTrue(containsChildren(cacheNode, in: snapshot))
        XCTAssertEqual(children(of: cacheNode, in: snapshot).count, 20)
    }

    func testNodeDependencyLayoutNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/large-payload@1.0.0/node_modules/large-payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: packageURL.appending(path: "asset-\(index).dat"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.autoSummarizeMinFileCount = 20
        options.autoSummarizeMaxAverageFileSize = 256
        options.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        XCTAssertFalse(nodeModulesNode.isAutoSummarized)
        XCTAssertTrue(containsChildren(nodeModulesNode, in: snapshot))
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

        let projectsNode = try XCTUnwrap(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try XCTUnwrap(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        XCTAssertTrue(cacheNode.isAutoSummarized)
        XCTAssertEqual(cacheNode.descendantFileCount, 12)
        XCTAssertEqual(cacheNode.logicalSize, 12 * 32)
    }
}

private func finishedSnapshot(
    target: ScanTarget,
    options: ScanOptions,
    engine: ScanEngine = ScanEngine()
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    XCTFail("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func rootChildren(in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: snapshot.root.id)
}

private func children(of node: FileNodeRecord, in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: node.id)
}

private func containsChildren(_ node: FileNodeRecord, in snapshot: ScanSnapshot) -> Bool {
    snapshot.treeStore.containsChildren(id: node.id)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeScanEngineFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private enum AsyncTestTimeout: Error {
    case timedOut
}

private final class DirectoryEnumerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = isCancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class SlowDirectoryObjectEnumerator: ScanEngine.DirectoryObjectEnumerating, @unchecked Sendable {
    let totalCount: Int
    private let rootURL: URL
    private let lock = NSLock()
    private var nextIndex = 0

    init(rootURL: URL, totalCount: Int) {
        self.rootURL = rootURL
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func nextObject() -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < totalCount else { return nil }
        let childURL = rootURL.appending(path: "payload-\(nextIndex).tmp")
        nextIndex += 1
        Thread.sleep(forTimeInterval: 0.0005)
        return childURL
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory object enumeration.", file: file, line: line)
    }
}

private final class CancellableDirectoryContentsProbe: @unchecked Sendable {
    let totalCount: Int
    private let lock = NSLock()
    private var produced = 0

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return produced
    }

    func contents(
        for url: URL,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(totalCount)

        for index in 0..<totalCount {
            if index.isMultiple(of: 8) {
                try cancellationCheck()
            }
            recordProducedChild()
            Thread.sleep(forTimeInterval: 0.0005)
            urls.append(url.appending(path: "payload-\(index).tmp"))
        }

        return urls
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents production.", file: file, line: line)
    }

    private func recordProducedChild() {
        lock.lock()
        produced += 1
        lock.unlock()
    }
}

private final class BlockingDirectoryContentsProbe: @unchecked Sendable {
    private let blockedURL: URL
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    init(blockedURL: URL) {
        self.blockedURL = blockedURL
    }

    func contents(for url: URL) throws -> [URL] {
        guard url == blockedURL else { return [] }

        condition.lock()
        defer { condition.unlock() }
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        return []
    }

    func waitUntilBlocked(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if blocked {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for directory contents blocking.", file: file, line: line)
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private var blocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: duration)
            throw AsyncTestTimeout.timedOut
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeout.timedOut
        }
        group.cancelAll()
        return result
    }
}
