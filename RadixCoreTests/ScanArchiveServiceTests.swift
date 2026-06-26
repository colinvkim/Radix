import CryptoKit
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
        XCTAssertEqual(importedSnapshot.scanOptions, snapshot.scanOptions)
        XCTAssertEqual(importResult.manifest.createdBy.swiftSchema, "ScanArchiveV3")
        XCTAssertEqual(importResult.manifest.snapshot.scanOptions, snapshot.scanOptions)
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
        XCTAssertEqual(hardLinkedNode.lastModified, Date(timeIntervalSince1970: 100))

        let resourceNode = try XCTUnwrap(importedSnapshot.treeStore.node(id: "/archive/folder/resource-id.bin"))
        XCTAssertEqual(resourceNode.fileIdentity, FileIdentity(resourceIdentifier: Data([1, 2, 3, 4])))
        XCTAssertEqual(resourceNode.lastModified, Date(timeIntervalSince1970: 200))

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

    func testImportSupportsArchiveWithoutScanOptionsPayload() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var snapshot = object["snapshot"] as? [String: Any] ?? [:]
            snapshot.removeValue(forKey: "scanOptions")
            object["snapshot"] = snapshot
        }

        let importResult = try await service.importSnapshot(from: archiveURL)

        XCTAssertNil(importResult.manifest.snapshot.scanOptions)
        XCTAssertNil(importResult.snapshot.scanOptions)
        XCTAssertNotNil(importResult.manifest.snapshot.scanOptionsFingerprint)
    }

    func testImportRejectsScanOptionsFingerprintMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var snapshot = object["snapshot"] as? [String: Any] ?? [:]
            var scanOptions = snapshot["scanOptions"] as? [String: Any] ?? [:]
            scanOptions["includeHiddenFiles"] = false
            snapshot["scanOptions"] = scanOptions
            object["snapshot"] = snapshot
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject mismatched scan options.")
        } catch ScanArchiveError.integrity(let detail) {
            XCTAssertTrue(detail.contains("scan options"))
        }
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
        let expectedArchiveSize = try [
            "manifest.json",
            "nodes.jsonl",
            "topology.json",
            "warnings.json",
            "stats.json"
        ].reduce(into: Int64(0)) { totalSize, fileName in
            let fileURL = archiveURL.appending(path: fileName, directoryHint: .notDirectory)
            totalSize += Int64(try Data(contentsOf: fileURL).count)
        }

        let preview = try await service.previewSnapshot(from: archiveURL)

        XCTAssertEqual(preview.archiveURL, archiveURL)
        XCTAssertEqual(preview.archiveSize, expectedArchiveSize)
        XCTAssertEqual(preview.appVersion, "Tests")
        XCTAssertEqual(preview.target.path, snapshot.target.url.path)
        XCTAssertEqual(preview.target.displayName, snapshot.target.displayName)
        XCTAssertEqual(preview.startedAt, snapshot.startedAt)
        XCTAssertEqual(preview.finishedAt, snapshot.finishedAt)
        XCTAssertEqual(preview.nodeCount, snapshot.treeStore.nodeCount)
        XCTAssertEqual(preview.warningCount, snapshot.scanWarnings.count)
        XCTAssertEqual(preview.totalAllocatedSize, snapshot.aggregateStats.totalAllocatedSize)
        XCTAssertEqual(preview.totalLogicalSize, snapshot.aggregateStats.totalLogicalSize)
        XCTAssertEqual(preview.fileCount, snapshot.aggregateStats.fileCount)
        XCTAssertEqual(preview.directoryCount, snapshot.aggregateStats.directoryCount)
    }

    func testExportWritesOrdinalTopology() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())

        let topologyURL = archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
        let topologyData = try Data(contentsOf: topologyURL)
        let topologyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: topologyData) as? [String: Any])
        let childMap = try XCTUnwrap(topologyObject["c"] as? [String: Any])
        let encodedTopology = try XCTUnwrap(String(data: topologyData, encoding: .utf8))

        XCTAssertEqual(topologyObject["r"] as? Int, 0)
        XCTAssertNotNil(childMap["0"] as? [Int])
        XCTAssertNil(topologyObject["rootID"])
        XCTAssertNil(topologyObject["childIDsByID"])
        XCTAssertFalse(encodedTopology.contains("/archive"))
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

    func testExportRejectsWrongArchiveExtension() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        let wrongExtensionURL = archiveURL.deletingPathExtension().appendingPathExtension("foo")

        do {
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: wrongExtensionURL,
                options: ScanArchiveExportOptions()
            )
            XCTFail("Export should reject destinations without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            XCTAssertTrue(detail.contains(".radixscan"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongExtensionURL.path))
    }

    func testImportRejectsWrongArchiveExtension() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())
        let wrongExtensionURL = archiveURL.deletingPathExtension().appendingPathExtension("foo")
        try FileManager.default.moveItem(at: archiveURL, to: wrongExtensionURL)

        do {
            _ = try await service.previewSnapshot(from: wrongExtensionURL)
            XCTFail("Preview should reject packages without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            XCTAssertTrue(detail.contains(".radixscan"))
        }

        do {
            _ = try await service.importSnapshot(from: wrongExtensionURL)
            XCTFail("Import should reject packages without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            XCTAssertTrue(detail.contains(".radixscan"))
        }
    }

    func testImportRejectsEmptyArchivePackage() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            XCTFail("Preview should reject empty archive packages.")
        } catch ScanArchiveError.manifest(let detail) {
            XCTAssertFalse(detail.isEmpty)
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject empty archive packages.")
        } catch ScanArchiveError.manifest(let detail) {
            XCTAssertFalse(detail.isEmpty)
        }
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

    func testImportRejectsMissingNodeSectionAsArchiveError() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())
        try FileManager.default.removeItem(at: archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory))

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject missing node sections as archive node errors.")
        } catch ScanArchiveError.nodes(let detail) {
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testImportRejectsNodePayloadExceedingManifestCountEarly() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let checksum = try appendArchiveNode([
            "i": "/archive/extra.txt",
            "n": "extra.txt",
            "a": 1,
        ], in: archiveURL)
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject node payloads that exceed the manifest count while reading.")
        } catch ScanArchiveError.nodes(let detail) {
            XCTAssertTrue(detail.contains("more nodes"))
        }
    }

    func testImportRejectsOversizedNodeLineBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        try Data(repeating: 0x7B, count: 2 * 1024 * 1024).write(to: nodesURL, options: [.atomic])

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject oversized node lines before decoding JSON.")
        } catch ScanArchiveError.nodes(let detail) {
            XCTAssertTrue(detail.contains("too large"))
        }
    }

    func testImportRejectsMalformedTopology() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let validTopology = try ScanArchiveTopology(snapshot.treeStore)
        let rootKey = String(validTopology.rootOrdinal)
        let rootChildren = try XCTUnwrap(validTopology.childOrdinalsByOrdinal[rootKey])
        let firstChildOrdinal = try XCTUnwrap(rootChildren.first)
        let nodeCount = snapshot.treeStore.nodeCount
        let cases: [(name: String, topology: ScanArchiveTopology, expectedDetail: String)] = [
            (
                "missing root",
                ScanArchiveTopology(rootOrdinal: nodeCount, childOrdinalsByOrdinal: [:]),
                "root ordinal"
            ),
            (
                "out-of-range child",
                ScanArchiveTopology(
                    rootOrdinal: validTopology.rootOrdinal,
                    childOrdinalsByOrdinal: [rootKey: [nodeCount]]
                ),
                "child ordinal"
            ),
            (
                "duplicate child",
                ScanArchiveTopology(
                    rootOrdinal: validTopology.rootOrdinal,
                    childOrdinalsByOrdinal: [rootKey: [firstChildOrdinal, firstChildOrdinal]]
                ),
                "duplicate"
            ),
            (
                "self cycle",
                ScanArchiveTopology(
                    rootOrdinal: validTopology.rootOrdinal,
                    childOrdinalsByOrdinal: [rootKey: [validTopology.rootOrdinal]]
                ),
                "references itself"
            ),
            (
                "unreachable",
                ScanArchiveTopology(
                    rootOrdinal: validTopology.rootOrdinal,
                    childOrdinalsByOrdinal: [:]
                ),
                "not reachable"
            ),
        ]

        for testCase in cases {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())
            try encodeArchiveJSON(
                testCase.topology,
                to: archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
            )

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                XCTFail("Import should reject malformed topology: \(testCase.name).")
            } catch ScanArchiveError.topology(let detail) {
                XCTAssertTrue(
                    detail.contains(testCase.expectedDetail),
                    "Expected \(testCase.expectedDetail) for \(testCase.name), got \(detail)."
                )
            }
        }
    }

    func testImportRejectsNodePathMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
            if archiveNodeID(node) == "/archive/folder/hard-link-a.bin" {
                setArchiveNodePath("/tmp/other.txt", in: &node)
            }
        }
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject node path mismatches.")
        } catch ScanArchiveError.nodes(let detail) {
            XCTAssertTrue(detail.contains("path"))
        }
    }

    func testImportRejectsTargetRootPathMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var snapshot = object["snapshot"] as? [String: Any] ?? [:]
            var target = snapshot["target"] as? [String: Any] ?? [:]
            target["path"] = "/other"
            snapshot["target"] = target
            object["snapshot"] = snapshot
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject target/root mismatches.")
        } catch ScanArchiveError.manifest(let detail) {
            XCTAssertTrue(detail.contains("root"))
        }
    }

    func testImportRejectsChildOutsideParentPath() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let oldID = "/archive/folder/hard-link-a.bin"
        let newID = "/tmp/other.txt"
        let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
            if archiveNodeID(node) == oldID {
                setArchiveNodeID(newID, in: &node)
                setArchiveNodePath(newID, in: &node)
                setArchiveNodeName("other.txt", in: &node)
            }
        }
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject children outside the parent path.")
        } catch ScanArchiveError.topology(let detail) {
            XCTAssertTrue(detail.contains("path"))
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

    func testImportRejectsOldFormatVersion() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            object["formatVersion"] = 2
        }

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            XCTFail("Preview should reject old format versions.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 2)
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject old format versions.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 2)
        }
    }

    func testImportRejectsMinimalFutureVersionManifest() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        let manifestData = Data("""
        {
          "format": "\(ScanArchiveService.formatIdentifier)",
          "formatVersion": 99
        }
        """.utf8)
        try manifestData.write(
            to: archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory),
            options: [.atomic]
        )

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            XCTFail("Preview should reject future versions before decoding the archive body.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 99)
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            XCTFail("Import should reject future versions before decoding the archive body.")
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

    func testDeepTopologyImportDoesNotOverflowStack() async throws {
        let service = ScanArchiveService()
        let depth = 12_000
        let snapshot = makeDeepArchiveSnapshot(depth: depth)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        XCTAssertEqual(importedSnapshot.treeStore.nodeCount, snapshot.treeStore.nodeCount)
        XCTAssertEqual(importedSnapshot.treeStore.childIDsByID, snapshot.treeStore.childIDsByID)
        XCTAssertEqual(importedSnapshot.aggregateStats.fileCount, 1)
        XCTAssertEqual(importedSnapshot.treeStore.path(to: makeDeepArchiveNodeID(depth)).count, depth + 1)
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

    private func makeDeepArchiveSnapshot(depth: Int) -> ScanSnapshot {
        precondition(depth > 0)

        let rootID = "/deep"
        var nodesByID: [String: FileNodeRecord] = [
            rootID: makeDeepArchiveDirectoryNode(id: rootID, name: "deep")
        ]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var parentID = rootID

        for index in 1...depth {
            let nodeID = makeDeepArchiveNodeID(index)
            let nodeName = "node-\(String(format: "%05d", index))"
            let node = index == depth
                ? makeTestFileNode(id: nodeID, name: nodeName, size: 64)
                : makeDeepArchiveDirectoryNode(id: nodeID, name: nodeName)

            nodesByID[nodeID] = node
            childIDsByID[parentID] = [nodeID]
            parentIDByID[nodeID] = parentID
            parentID = nodeID
        }

        let store = FileTreeStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
        return makeTestSnapshot(root: store.root, store: store)
    }

    private func makeDeepArchiveDirectoryNode(id: String, name: String) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func makeDeepArchiveNodeID(_ index: Int) -> String {
        "/deep/node-\(String(format: "%05d", index))"
    }

    private func archiveNodeID(_ node: [String: Any]) -> String? {
        node["id"] as? String ?? node["i"] as? String
    }

    private func setArchiveNodeID(_ id: String, in node: inout [String: Any]) {
        if node["id"] != nil {
            node["id"] = id
        } else {
            node["i"] = id
        }
    }

    private func setArchiveNodePath(_ path: String, in node: inout [String: Any]) {
        if node["path"] != nil {
            node["path"] = path
        } else {
            node["p"] = path
        }
    }

    private func setArchiveNodeName(_ name: String, in node: inout [String: Any]) {
        if node["name"] != nil {
            node["name"] = name
        } else {
            node["n"] = name
        }
    }

    private func encodeArchiveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private func rewriteArchiveNodes(
        in archiveURL: URL,
        mutate: (inout [String: Any]) -> Void
    ) throws -> String {
        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        let data = try Data(contentsOf: nodesURL)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var rewrittenData = Data()

        for line in lines where !line.isEmpty {
            let lineData = Data(line.utf8)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            mutate(&object)
            let encodedLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            rewrittenData.append(encodedLine)
            rewrittenData.append(Data("\n".utf8))
        }

        try rewrittenData.write(to: nodesURL, options: [.atomic])
        return Data(SHA256.hash(data: rewrittenData)).base64EncodedString()
    }

    private func appendArchiveNode(_ node: [String: Any], in archiveURL: URL) throws -> String {
        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        var data = try Data(contentsOf: nodesURL)
        if data.last != 0x0A {
            data.append(Data("\n".utf8))
        }
        let encodedLine = try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
        data.append(encodedLine)
        data.append(Data("\n".utf8))
        try data.write(to: nodesURL, options: [.atomic])
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func rewriteManifestNodeChecksum(_ checksum: String, in archiveURL: URL) throws {
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var integrity = object["integrity"] as? [String: Any] ?? [:]
            integrity["nodes"] = checksum
            object["integrity"] = integrity
        }
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
