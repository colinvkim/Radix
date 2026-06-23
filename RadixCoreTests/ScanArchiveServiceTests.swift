import XCTest
@testable import RadixCore

final class ScanArchiveServiceTests: XCTestCase {
    func testExportImportRoundTripsSnapshotGraphAndTrustContext() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()

        let exportResult = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let importResult = try await service.importSnapshot(from: archiveURL)
        let importedSnapshot = importResult.snapshot

        XCTAssertEqual(exportResult.archiveURL, archiveURL)
        XCTAssertFalse(exportResult.nodeChecksum.isEmpty)
        XCTAssertEqual(importedSnapshot.id, snapshot.id)
        XCTAssertEqual(importedSnapshot.target.displayName, snapshot.target.displayName)
        XCTAssertEqual(importedSnapshot.treeStore.nodeCount, snapshot.treeStore.nodeCount)
        XCTAssertEqual(importedSnapshot.treeStore.childIDsByID, snapshot.treeStore.childIDsByID)
        XCTAssertEqual(importedSnapshot.aggregateStats.totalAllocatedSize, snapshot.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(importedSnapshot.scanWarnings.map(\.path), snapshot.scanWarnings.map(\.path))
        XCTAssertNotNil(importResult.manifest.snapshot.scanOptionsFingerprint)

        guard case .imported(let context) = importedSnapshot.source else {
            return XCTFail("Imported snapshot source missing.")
        }
        XCTAssertEqual(context.sourceURL, archiveURL)
        XCTAssertEqual(context.pathMode, .absolute)
        XCTAssertEqual(context.liveActionCapability, .pathValidation)

        let hardLinkedNode = try XCTUnwrap(importedSnapshot.treeStore.node(id: "/archive/folder/hard-link-a.bin"))
        XCTAssertEqual(hardLinkedNode.unduplicatedAllocatedSize, 40)
        XCTAssertEqual(hardLinkedNode.fileIdentity, FileIdentity(device: 10, inode: 20))
        XCTAssertEqual(hardLinkedNode.linkCount, 2)

        let resourceNode = try XCTUnwrap(importedSnapshot.treeStore.node(id: "/archive/folder/resource-id.bin"))
        XCTAssertEqual(resourceNode.fileIdentity, FileIdentity(resourceIdentifier: Data([1, 2, 3, 4])))

        let summarizedNode = try XCTUnwrap(importedSnapshot.treeStore.node(id: "/archive/folder/tiny-cache"))
        XCTAssertTrue(summarizedNode.isAutoSummarized)
        XCTAssertEqual(summarizedNode.descendantFileCount, 400)

        let availability = FileNodeActionAvailability(
            node: hardLinkedNode,
            activeTarget: importedSnapshot.target,
            snapshotSource: importedSnapshot.source
        )
        XCTAssertTrue(availability.canOpen)
        XCTAssertTrue(availability.canCopyPath)
        XCTAssertFalse(availability.canMoveToTrash)
    }

    func testPreviewReadsManifestAndStatsMetadata() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let preview = try await service.previewSnapshot(from: archiveURL)

        XCTAssertEqual(preview.archiveURL, archiveURL)
        XCTAssertEqual(preview.appVersion, "Tests")
        XCTAssertEqual(preview.formatVersion, ScanArchiveService.currentFormatVersion)
        XCTAssertEqual(preview.target.path, snapshot.target.url.path)
        XCTAssertEqual(preview.target.displayName, snapshot.target.displayName)
        XCTAssertEqual(preview.startedAt, snapshot.startedAt)
        XCTAssertEqual(preview.finishedAt, snapshot.finishedAt)
        XCTAssertEqual(preview.nodeCount, snapshot.treeStore.nodeCount)
        XCTAssertEqual(preview.warningCount, snapshot.scanWarnings.count)
        XCTAssertEqual(preview.pathMode, .absolute)
        XCTAssertEqual(preview.totalAllocatedSize, snapshot.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(preview.totalLogicalSize, snapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(preview.fileCount, snapshot.aggregateStats.fileCount)
        XCTAssertEqual(preview.directoryCount, snapshot.aggregateStats.directoryCount)
    }

    func testExportReplacesExistingArchiveAfterSuccessfulWrite() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Old")
        )
        let oldOnlyURL = archiveURL.appending(path: "old-only.txt", directoryHint: .notDirectory)
        try Data("old".utf8).write(to: oldOnlyURL)

        let replacementSnapshot = makeLargeArchiveSnapshot(childCount: 3)
        _ = try await service.export(
            snapshot: replacementSnapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "New")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOnlyURL.path))
        let preview = try await service.previewSnapshot(from: archiveURL)
        XCTAssertEqual(preview.appVersion, "New")
        XCTAssertEqual(preview.nodeCount, replacementSnapshot.treeStore.nodeCount)
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot
        XCTAssertEqual(importedSnapshot.treeStore.nodeCount, replacementSnapshot.treeStore.nodeCount)
    }

    func testCancelledExportKeepsExistingArchiveAndRemovesTemporaryPackage() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        let originalSnapshot = makeArchiveSnapshot()
        _ = try await service.export(
            snapshot: originalSnapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Original")
        )

        let progressReporter = ScanArchiveProgressReporter()
        let replacementSnapshot = makeLargeArchiveSnapshot(childCount: 20_000)
        let exportTask = Task {
            try await service.export(
                snapshot: replacementSnapshot,
                to: archiveURL,
                options: ScanArchiveExportOptions(
                    appVersion: "Cancelled",
                    progressReporter: progressReporter
                )
            )
        }
        defer {
            progressReporter.finish()
            exportTask.cancel()
        }

        try await waitForProgressPhase(.writingNodes, from: progressReporter)
        exportTask.cancel()

        do {
            _ = try await exportTask.value
            XCTFail("Cancelled export should not replace existing archive.")
        } catch is CancellationError {
        }

        let preview = try await service.previewSnapshot(from: archiveURL)
        XCTAssertEqual(preview.appVersion, "Original")
        XCTAssertEqual(preview.nodeCount, originalSnapshot.treeStore.nodeCount)
        XCTAssertTrue(try temporaryArchiveSiblings(for: archiveURL).isEmpty)
    }

    func testImportRejectsNodesChecksumMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        let handle = try FileHandle(forWritingTo: nodesURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject modified node payload.")
        } catch ScanArchiveError.integrity(let detail) {
            XCTAssertTrue(detail.contains("checksum"))
        }
    }

    func testImportRejectsMalformedTopology() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())

        let invalidTopology = ScanArchiveTopologyV1(
            rootID: snapshot.root.id,
            childIDsByID: [snapshot.root.id: ["/archive/missing"]],
            parentIDByID: nil
        )
        try encodeArchiveJSON(
            invalidTopology,
            to: archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
        )

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject missing topology nodes.")
        } catch ScanArchiveError.topology(let detail) {
            XCTAssertTrue(detail.contains("missing"))
        }
    }

    func testImportRejectsUnsupportedVersion() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            object["formatVersion"] = 99
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject unsupported versions.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 99)
        }
    }

    func testImportRepairsMismatchedStatsAndRecordsWarning() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let statsURL = archiveURL.appending(path: "stats.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: statsURL) { object in
            object["totalAllocatedSize"] = 1
        }

        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        XCTAssertEqual(importedSnapshot.aggregateStats.totalAllocatedSize, importedSnapshot.root.allocatedSize)
        XCTAssertTrue(importedSnapshot.scanWarnings.contains { warning in
            warning.message.contains("repaired totals")
        })
    }

    func testLargeTopologyRoundTripsDeterministicOrder() async throws {
        let service = ScanArchiveService()
        let snapshot = makeLargeArchiveSnapshot(childCount: 1_500)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        XCTAssertEqual(importedSnapshot.treeStore.nodeCount, snapshot.treeStore.nodeCount)
        XCTAssertEqual(importedSnapshot.treeStore.children(of: snapshot.root.id).map(\.id), snapshot.treeStore.children(of: snapshot.root.id).map(\.id))
        XCTAssertEqual(importedSnapshot.aggregateStats.fileCount, 1_500)
    }

    private func makeTemporaryArchiveURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL.appending(path: "Export.radixscan", directoryHint: .isDirectory)
    }

    private func temporaryArchiveSiblings(for archiveURL: URL) throws -> [URL] {
        let parentURL = archiveURL.deletingLastPathComponent()
        let tempPrefix = ".\(archiveURL.lastPathComponent)."
        return try FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil
        )
        .filter { url in
            url.lastPathComponent.hasPrefix(tempPrefix) && url.lastPathComponent.hasSuffix(".tmp")
        }
    }

    private func waitForProgressPhase(
        _ phase: ScanArchiveProgressPhase,
        from progressReporter: ScanArchiveProgressReporter
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await progress in progressReporter.updates where progress.phase == phase {
                    return
                }
                throw AsyncWaitError.streamFinished
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AsyncWaitError.timedOut
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func makeArchiveSnapshot() -> ScanSnapshot {
        let hardLinkedFile = FileNodeRecord(
            id: "/archive/folder/hard-link-a.bin",
            url: URL(filePath: "/archive/folder/hard-link-a.bin"),
            name: "hard-link-a.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 100,
            unduplicatedAllocatedSize: 40,
            logicalSize: 120,
            descendantFileCount: 1,
            lastModified: Date(timeIntervalSince1970: 100),
            fileIdentity: FileIdentity(device: 10, inode: 20),
            linkCount: 2,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let resourceFile = FileNodeRecord(
            id: "/archive/folder/resource-id.bin",
            url: URL(filePath: "/archive/folder/resource-id.bin"),
            name: "resource-id.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 80,
            logicalSize: 80,
            descendantFileCount: 1,
            lastModified: Date(timeIntervalSince1970: 200),
            fileIdentity: FileIdentity(resourceIdentifier: Data([1, 2, 3, 4])),
            linkCount: 1,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let inaccessibleFile = FileNodeRecord(
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
        let summarizedDirectory = FileNodeRecord(
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
            children: [hardLinkedFile, resourceFile, inaccessibleFile, summarizedDirectory],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let syntheticNode = FileNodeRecord(
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
            children: [folder, syntheticNode],
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folder, syntheticNode],
            folder.id: [hardLinkedFile, resourceFile, inaccessibleFile, summarizedDirectory],
        ])

        var scanOptions = ScanOptions()
        scanOptions.includeHiddenFiles = true
        scanOptions.treatPackagesAsDirectories = true
        scanOptions.exclusionPatterns = ["*.tmp"]

        return ScanSnapshot(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            target: ScanTarget(
                id: root.id,
                url: root.url,
                displayName: "Archive",
                kind: .folder
            ),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20),
            scanWarnings: [
                ScanWarning(
                    path: inaccessibleFile.id,
                    message: "Permission denied",
                    category: .permissionDenied
                )
            ],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            scanOptions: scanOptions
        )
    }

    private func makeLargeArchiveSnapshot(childCount: Int) -> ScanSnapshot {
        let children = (0..<childCount).map { index in
            makeTestFileNode(
                id: "/large/file-\(String(format: "%04d", index)).txt",
                name: "file-\(String(format: "%04d", index)).txt",
                size: Int64(childCount - index)
            )
        }
        let root = makeTestDirectoryNode(id: "/large", name: "large", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        return makeTestSnapshot(root: root, store: store)
    }

    private func encodeArchiveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private func rewriteJSONObject(at url: URL, mutate: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        let rewrittenData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewrittenData.write(to: url, options: [.atomic])
    }
}

private enum AsyncWaitError: Error {
    case streamFinished
    case timedOut
}
