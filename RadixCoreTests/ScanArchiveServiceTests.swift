import CryptoKit
import Foundation
import Testing

@testable import RadixCore

struct ScanArchiveServiceTests {
    private let temporaryFiles = TemporaryTestFiles()

    @Test
    func testExportImportRoundTripsLogicalScopeWithNonDenseNodeIndices() async throws {
        let service = ScanArchiveService()
        let containingSnapshot = makeArchiveSnapshot()
        let target = ScanTarget(url: URL(filePath: "/archive/folder", directoryHint: .isDirectory))
        let snapshot = try #require(containingSnapshot.scoped(to: target))
        let archiveURL = try makeTemporaryArchiveURL()

        #expect(snapshot.treeStore.nodeCount < containingSnapshot.treeStore.nodeCount)
        #expect(snapshot.treeStore.rootID == target.id)
        #expect(snapshot.treeStore.node(id: containingSnapshot.treeStore.rootID) == nil)

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(importedSnapshot.target.id == target.id)
        #expect(importedSnapshot.treeStore.root == snapshot.treeStore.root)
        #expect(importedSnapshot.treeStore.nodeCount == snapshot.treeStore.nodeCount)
        #expect(importedSnapshot.treeStore.indexedNodeIDs() == snapshot.treeStore.indexedNodeIDs())
        #expect(importedSnapshot.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
        #expect(importedSnapshot.aggregateStats.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize)
        #expect(importedSnapshot.scanWarnings.map(\.path) == snapshot.scanWarnings.map(\.path))
    }

    @Test
    func testExportImportRoundTripsTinyScopeWithoutDenseBackingOrdinalMap() async throws {
        let service = ScanArchiveService()
        let siblings = (0..<4_096).map { offset in
            makeTestFileNode(
                id: "/root/file-\(offset).bin",
                name: "file-\(offset).bin",
                size: 2
            )
        }
        let targetRoot = makeTestSummarizedDirectoryNode(
            id: "/root/Target",
            name: "Target",
            size: 1,
            descendantFileCount: 10
        )
        let root = makeTestDirectoryNode(
            id: "/root",
            name: "root",
            children: siblings + [targetRoot]
        )
        let containingSnapshot = makeTestSnapshot(
            root: root,
            store: FileTreeStore(root: root, childrenByID: [root.id: siblings + [targetRoot]])
        )
        let snapshot = try #require(containingSnapshot.scoped(to: ScanTarget(url: targetRoot.url)))
        let archiveURL = try makeTemporaryArchiveURL()

        #expect(snapshot.treeStore.nodeCount == 1)
        #expect(snapshot.treeStore.backingNodeCapacity > 4_096)

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(importedSnapshot.treeStore.root == targetRoot)
        #expect(importedSnapshot.treeStore.nodeCount == 1)
        #expect(importedSnapshot.aggregateStats.fileCount == 10)
    }

    @Test
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

        #expect(exportResult.archiveURL == archiveURL)
        #expect(!(exportResult.nodeChecksum.isEmpty))
        #expect(importedSnapshot.id == snapshot.id)
        #expect(importedSnapshot.target.displayName == snapshot.target.displayName)
        #expect(importedSnapshot.treeStore.nodeCount == snapshot.treeStore.nodeCount)
        #expect(importedSnapshot.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
        #expect(importedSnapshot.aggregateStats.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize)
        #expect(importedSnapshot.scanWarnings.map(\.path) == snapshot.scanWarnings.map(\.path))
        #expect(importedSnapshot.scanOptions == snapshot.scanOptions)
        #expect(importedSnapshot.volumeCapacity == snapshot.volumeCapacity)
        #expect(importResult.manifest.formatVersion == 5)
        #expect(importResult.manifest.createdBy.swiftSchema == "ScanArchiveV5")
        #expect(importResult.manifest.sectionEncodings == .versionFive)
        #expect(importResult.manifest.integrity.domain == .decodedSectionBytes)
        #expect(importResult.manifest.integrity.topology != nil)
        #expect(importResult.manifest.integrity.warnings != nil)
        #expect(importResult.manifest.integrity.stats != nil)
        #expect(importResult.manifest.snapshot.scanOptions == snapshot.scanOptions)
        #expect(importResult.manifest.snapshot.scanOptionsFingerprint != nil)

        guard case .imported(let context) = importedSnapshot.source else {
            Issue.record("Imported snapshot source missing.")
            return
        }
        #expect(context.sourceURL == archiveURL)
        #expect(context.pathMode == .absolute)
        #expect(context.liveActionCapability == .pathValidation)

        let hardLinkedNode = try #require(importedSnapshot.treeStore.node(id: "/archive/folder/hard-link-a.bin"))
        #expect(hardLinkedNode.unduplicatedAllocatedSize == 40)
        #expect(hardLinkedNode.fileIdentity == FileIdentity(device: 10, inode: 20))
        #expect(hardLinkedNode.linkCount == 2)
        #expect(hardLinkedNode.lastModified == Date(timeIntervalSince1970: 100))

        let resourceNode = try #require(importedSnapshot.treeStore.node(id: "/archive/folder/résource-文件-🙂.bin"))
        #expect(resourceNode.fileIdentity == FileIdentity(resourceIdentifier: Data([1, 2, 3, 4])))
        #expect(resourceNode.cloneIdentity == CloneIdentity(device: 10, cloneID: 30))
        #expect(resourceNode.mayShareDataBlocks)
        #expect(resourceNode.dataAllocatedSize == 64)
        #expect(resourceNode.lastModified == Date(timeIntervalSince1970: 200))

        let summarizedNode = try #require(importedSnapshot.treeStore.node(id: "/archive/folder/tiny-cache"))
        #expect(summarizedNode.isAutoSummarized)
        #expect(summarizedNode.descendantFileCount == 400)

        let availability = FileNodeActionAvailability(
            node: hardLinkedNode,
            activeTarget: importedSnapshot.target,
            snapshotSource: importedSnapshot.source
        )
        #expect(availability.canOpen)
        #expect(availability.canCopyPath)
        #expect(!(availability.canMoveToTrash))
    }

    @Test
    func testVersionFiveUsesCompressedBodySectionsAndReadableManifest() async throws {
        let service = ScanArchiveService()
        let snapshot = makeLargeArchiveSnapshot(childCount: 1_000)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let manifestURL = archiveURL.appending(path: "manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ScanArchiveService.makeJSONDecoder().decode(
            ScanArchiveDocument.self,
            from: manifestData
        )
        let nodesData = try Data(contentsOf: archiveURL.appending(path: manifest.sections.nodes))
        let topologyData = try Data(
            contentsOf: archiveURL.appending(path: manifest.sections.topology)
        )

        #expect(manifest.formatVersion == 5)
        #expect(manifest.createdBy.swiftSchema == "ScanArchiveV5")
        #expect(manifest.sectionEncodings == .versionFive)
        #expect(manifest.sectionByteCounts != nil)
        #expect(manifest.sections.nodes == "nodes.jsonl.lzfse")
        #expect(manifest.sections.topology == "topology.json.lzfse")
        #expect(String(decoding: manifestData, as: UTF8.self).contains("\"formatVersion\":5"))
        #expect(nodesData.first != 0x7B)
        #expect(topologyData.first != 0x7B)
    }

    @Test
    func testVersionFivePreviewDoesNotReadCompressedTreeSections() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let manifest = try readManifest(from: archiveURL)
        try FileManager.default.removeItem(
            at: archiveURL.appending(path: manifest.sections.nodes)
        )
        try FileManager.default.removeItem(
            at: archiveURL.appending(path: manifest.sections.topology)
        )

        let preview = try await service.previewSnapshot(from: archiveURL)

        #expect(preview.appVersion == "Tests")
        #expect(preview.nodeCount == snapshot.treeStore.nodeCount)
        #expect(preview.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize)
    }

    @Test
    func testVersionFourAndFiveRoundTripsAreSemanticallyEquivalent() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let versionFourURL = try makeTemporaryArchiveURL()
        let versionFiveURL = try makeTemporaryArchiveURL()

        let versionFourExport = try await service.export(
            snapshot: snapshot,
            to: versionFourURL,
            options: versionFourOptions(appVersion: "Tests")
        )
        let versionFiveExport = try await service.export(
            snapshot: snapshot,
            to: versionFiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let versionFour = try await service.importSnapshot(from: versionFourURL)
        let versionFive = try await service.importSnapshot(from: versionFiveURL)

        #expect(versionFour.manifest.formatVersion == 4)
        #expect(versionFive.manifest.formatVersion == 5)
        #expect(!(versionFourExport.nodeChecksum.isEmpty))
        #expect(!(versionFiveExport.nodeChecksum.isEmpty))
        assertEquivalentSnapshots(versionFour.snapshot, versionFive.snapshot)

        let forward = try await ScanComparisonService().compare(
            before: versionFour.snapshot,
            after: versionFive.snapshot
        )
        let reverse = try await ScanComparisonService().compare(
            before: versionFive.snapshot,
            after: versionFour.snapshot
        )

        #expect(forward.rows.isEmpty)
        #expect(reverse.rows.isEmpty)
        #expect(forward.summary.allocatedDelta == 0)
        #expect(reverse.summary.allocatedDelta == 0)
        #expect(forward.summary.fileCountDelta == 0)
        #expect(reverse.summary.fileCountDelta == 0)
        #expect(forward.coverage == reverse.coverage)
        #expect(forward.changeTree == reverse.changeTree)
        #expect(forward.topLevelChanges == reverse.topLevelChanges)
    }

    @Test
    func testCrossVersionComparisonMatchesSameVersionBaseline() async throws {
        let service = ScanArchiveService()
        let beforeSnapshot = makeArchiveSnapshot()
        let removedID = "/archive/folder/résource-文件-🙂.bin"
        let afterSnapshot = try #require(beforeSnapshot.removingNode(id: removedID))

        let beforeFour = try await exportAndImport(
            beforeSnapshot,
            formatVersion: 4,
            service: service
        )
        let afterFour = try await exportAndImport(
            afterSnapshot,
            formatVersion: 4,
            service: service
        )
        let beforeFive = try await exportAndImport(
            beforeSnapshot,
            formatVersion: 5,
            service: service
        )
        let afterFive = try await exportAndImport(
            afterSnapshot,
            formatVersion: 5,
            service: service
        )

        let baseline = try await ScanComparisonService().compare(
            before: beforeFour,
            after: afterFour
        )
        let fourToFive = try await ScanComparisonService().compare(
            before: beforeFour,
            after: afterFive
        )
        let fiveToFour = try await ScanComparisonService().compare(
            before: beforeFive,
            after: afterFour
        )

        #expect(fourToFive.rows == baseline.rows)
        #expect(fiveToFour.rows == baseline.rows)
        #expect(fourToFive.summary == baseline.summary)
        #expect(fiveToFour.summary == baseline.summary)
        #expect(fourToFive.coverage == baseline.coverage)
        #expect(fiveToFour.coverage == baseline.coverage)
        #expect(fourToFive.changeTree == baseline.changeTree)
        #expect(fiveToFour.changeTree == baseline.changeTree)
        #expect(fourToFive.topLevelChanges == baseline.topLevelChanges)
        #expect(fiveToFour.topLevelChanges == baseline.topLevelChanges)
    }

    @Test
    func testLZFSESectionStreamRoundTripsChunkedDecodedBytes() throws {
        var pseudoRandomState: UInt64 = 0xD1CE_BA5E_F00D_CAFE
        let incompressiblePayload = Data(
            (0..<(2 * 1_024 * 1_024)).map { _ in
                pseudoRandomState = pseudoRandomState &* 6_364_136_223_846_793_005 &+ 1
                return UInt8(truncatingIfNeeded: pseudoRandomState >> 32)
            })
        let payloads = [
            Data(),
            Data([0]),
            Data(repeating: 0x41, count: 2 * 1_024 * 1_024),
            incompressiblePayload,
            Data("résource-文件-🙂".utf8),
        ]

        for payload in payloads {
            let fileURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
            temporaryFiles.track(fileURL)
            #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: fileURL)
            var writer = try ScanArchiveSectionWriter(
                fileHandle: handle,
                encoding: .lzfse
            )
            for offset in stride(from: 0, to: payload.count, by: 777) {
                let end = min(offset + 777, payload.count)
                try writer.append(payload.subdata(in: offset..<end))
            }
            let checksum = try writer.finish()
            try handle.close()

            let reader = try ScanArchiveSectionReader(url: fileURL, encoding: .lzfse)
            defer { reader.close() }
            var decoded = Data()
            while true {
                let chunk = try reader.read(upToCount: 509)
                guard !chunk.isEmpty else { break }
                decoded.append(chunk)
            }

            #expect(decoded == payload)
            #expect(checksum == Data(SHA256.hash(data: payload)).base64EncodedString())
        }
    }

    @Test
    func testVersionFiveRejectsCorruptedTruncatedAndTrailingNodeStreams() async throws {
        enum Mutation {
            case corrupt
            case truncate
            case append
        }
        let service = ScanArchiveService()

        for mutation in [Mutation.corrupt, .truncate, .append] {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeLargeArchiveSnapshot(childCount: 1_000),
                to: archiveURL,
                options: ScanArchiveExportOptions()
            )
            let manifest = try readManifest(from: archiveURL)
            let nodesURL = archiveURL.appending(path: manifest.sections.nodes)
            var data = try Data(contentsOf: nodesURL)
            switch mutation {
            case .corrupt:
                data[data.count / 2] ^= 0xFF
            case .truncate:
                data.removeLast()
            case .append:
                data.append(0)
            }
            try data.write(to: nodesURL, options: [.atomic])

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject a \(mutation) v5 node stream.")
            } catch ScanArchiveError.nodes(let detail) {
                #expect(!(detail.isEmpty))
            } catch ScanArchiveError.integrity(let detail) {
                #expect(detail.contains("nodes"))
            }
        }
    }

    @Test
    func testVersionFiveImportRejectsMissingCompressedTreeSections() async throws {
        let service = ScanArchiveService()

        for section in ["nodes", "topology"] {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: archiveURL,
                options: ScanArchiveExportOptions()
            )
            let manifest = try readManifest(from: archiveURL)
            let sectionName =
                section == "nodes"
                ? manifest.sections.nodes
                : manifest.sections.topology
            try FileManager.default.removeItem(
                at: archiveURL.appending(path: sectionName)
            )

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject a missing v5 \(section) section.")
            } catch ScanArchiveError.integrity(let detail) {
                #expect(detail.contains(section))
            }
        }
    }

    @Test
    func testVersionFiveRejectsCorruptedAndTruncatedTopologyStreams() async throws {
        let service = ScanArchiveService()
        for shouldTruncate in [false, true] {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeLargeArchiveSnapshot(childCount: 1_000),
                to: archiveURL,
                options: ScanArchiveExportOptions()
            )
            let manifest = try readManifest(from: archiveURL)
            let topologyURL = archiveURL.appending(path: manifest.sections.topology)
            var data = try Data(contentsOf: topologyURL)
            if shouldTruncate {
                data.removeLast()
            } else {
                data[data.count / 2] ^= 0xFF
            }
            try data.write(to: topologyURL, options: [.atomic])

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject a damaged v5 topology stream.")
            } catch ScanArchiveError.topology(let detail) {
                #expect(!(detail.isEmpty))
            } catch ScanArchiveError.integrity(let detail) {
                #expect(detail.contains("topology"))
            }
        }
    }

    @Test
    func testVersionFivePreviewAndImportVerifyStatsChecksum() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let statsURL = archiveURL.appending(path: "stats.json")
        try rewriteJSONObject(at: statsURL) { object in
            object["totalAllocatedSize"] = 1
        }

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            Issue.record("Preview should verify the v5 stats checksum.")
        } catch ScanArchiveError.integrity(let detail) {
            #expect(detail.contains("stats"))
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should verify the v5 stats checksum.")
        } catch ScanArchiveError.integrity(let detail) {
            #expect(detail.contains("stats"))
        }
    }

    @Test
    func testVersionFiveRejectsMissingOrIncorrectSectionEncodings() async throws {
        let service = ScanArchiveService()
        for mutation in 0...1 {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: archiveURL,
                options: ScanArchiveExportOptions()
            )
            let manifestURL = archiveURL.appending(path: "manifest.json")
            try rewriteJSONObject(at: manifestURL) { object in
                if mutation == 0 {
                    object.removeValue(forKey: "sectionEncodings")
                } else {
                    var encodings = object["sectionEncodings"] as? [String: Any] ?? [:]
                    encodings["nodes"] = "identity"
                    object["sectionEncodings"] = encodings
                }
            }

            do {
                _ = try await service.previewSnapshot(from: archiveURL)
                Issue.record("Preview should reject invalid v5 section encodings.")
            } catch ScanArchiveError.manifest(let detail) {
                #expect(detail.contains("encodings"))
            }
        }
    }

    @Test
    func testVersionFiveRequiresCompleteIntegrityAndStoredByteCounts() async throws {
        let service = ScanArchiveService()
        for mutation in 0...3 {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: archiveURL,
                options: ScanArchiveExportOptions()
            )
            let manifestURL = archiveURL.appending(path: "manifest.json")
            try rewriteJSONObject(at: manifestURL) { object in
                switch mutation {
                case 0:
                    var integrity = object["integrity"] as? [String: Any] ?? [:]
                    integrity["nodes"] = ""
                    object["integrity"] = integrity
                case 1:
                    var integrity = object["integrity"] as? [String: Any] ?? [:]
                    integrity.removeValue(forKey: "topology")
                    object["integrity"] = integrity
                case 2:
                    object.removeValue(forKey: "sectionByteCounts")
                default:
                    var counts = object["sectionByteCounts"] as? [String: Any] ?? [:]
                    counts["nodes"] = -1
                    object["sectionByteCounts"] = counts
                }
            }

            do {
                _ = try await service.previewSnapshot(from: archiveURL)
                Issue.record("Preview should reject incomplete v5 integrity metadata.")
            } catch ScanArchiveError.integrity(let detail) {
                #expect(!(detail.isEmpty))
            }
        }
    }

    @Test
    func testVersionFiveImportVerifiesWarningsChecksum() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let warningsURL = archiveURL.appending(path: "warnings.json")
        let originalData = try Data(contentsOf: warningsURL)
        let originalText = String(decoding: originalData, as: UTF8.self)
        let modifiedText = originalText.replacingOccurrences(
            of: "Permission denied",
            with: "Permission DenieD"
        )
        #expect(modifiedText.utf8.count == originalData.count)
        try Data(modifiedText.utf8).write(to: warningsURL, options: [.atomic])

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should verify the v5 warnings transport and checksum.")
        } catch ScanArchiveError.integrity(let detail) {
            #expect(detail.contains("warnings"))
        }
    }

    @Test
    func testVersionFiveDecodedTopologyLimitAppliesAfterDecompression() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let manifest = try readManifest(from: archiveURL)
        let topologyURL = archiveURL.appending(path: manifest.sections.topology)
        let oversizedDecodedData = Data(repeating: 0x20, count: 128 * 1_024)
        let checksum = try writeSection(
            oversizedDecodedData,
            to: topologyURL,
            encoding: .lzfse
        )
        try rewriteManifestChecksum(checksum, key: "topology", in: archiveURL)
        try rewriteManifestByteCount(
            Int64(try topologyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            key: "topology",
            in: archiveURL
        )

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should bound decoded v5 topology bytes.")
        } catch ScanArchiveError.topology(let detail) {
            #expect(detail.contains("supported size"))
        }
    }

    @Test
    func testVersionFiveDecodedNodeLineLimitAppliesAfterDecompression() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let manifest = try readManifest(from: archiveURL)
        let nodesURL = archiveURL.appending(path: manifest.sections.nodes)
        let oversizedDecodedLine = Data(repeating: 0x7B, count: 2 * 1_024 * 1_024)
        let checksum = try writeSection(
            oversizedDecodedLine,
            to: nodesURL,
            encoding: .lzfse
        )
        try rewriteManifestChecksum(checksum, key: "nodes", in: archiveURL)
        try rewriteManifestByteCount(
            Int64(try nodesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            key: "nodes",
            in: archiveURL
        )

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should bound decoded v5 node-line bytes.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(detail.contains("too large"))
        }
    }

    @Test
    func testVersionFourNodePayloadIsSmallerThanLegacyFullPathRecords() async throws {
        let service = ScanArchiveService()
        let snapshot = makeLargeArchiveSnapshot(childCount: 1_000)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: versionFourOptions(appVersion: "Tests")
        )

        let compactData = try Data(contentsOf: archiveURL.appending(path: "nodes.jsonl"))
        let legacyData = try legacyNodeData(for: snapshot)

        #expect(compactData.count < legacyData.count)
        #expect(Double(compactData.count) < Double(legacyData.count) * 0.8)
        #expect(!(String(decoding: compactData, as: UTF8.self).contains("/large/")))
    }

    @Test
    func testImportPreservesNodeOrderAcrossDecodeBatches() async throws {
        let service = ScanArchiveService()
        let snapshot = makeLargeArchiveSnapshot(childCount: 40_000)
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let imported = try await service.importSnapshot(from: archiveURL)

        #expect(imported.snapshot.treeStore.indexedNodeIDs() == snapshot.treeStore.indexedNodeIDs())
    }

    @Test
    func testImportSupportsCompactNodesStoredBeforeTheirParents() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: versionFourOptions(appVersion: "Tests")
        )

        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        let nodeLines = try Data(contentsOf: nodesURL).split(separator: 0x0A)
        var reversedNodes = Data()
        for line in nodeLines.reversed() {
            reversedNodes.append(contentsOf: line)
            reversedNodes.append(0x0A)
        }
        try reversedNodes.write(to: nodesURL, options: [.atomic])
        try rewriteManifestNodeChecksum(
            Data(SHA256.hash(data: reversedNodes)).base64EncodedString(),
            in: archiveURL
        )

        let topologyURL = archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
        let topology = try JSONDecoder().decode(
            ScanArchiveTopology.self,
            from: Data(contentsOf: topologyURL)
        )
        let lastOrdinal = nodeLines.count - 1
        let reversedChildren = Dictionary(
            uniqueKeysWithValues:
                topology.childOrdinalsByOrdinal.map { parentKey, children in
                    (String(lastOrdinal - Int(parentKey)!), children.map { lastOrdinal - $0 })
                }
        )
        try encodeArchiveJSON(
            ScanArchiveTopology(
                rootOrdinal: lastOrdinal - topology.rootOrdinal,
                childOrdinalsByOrdinal: reversedChildren
            ),
            to: topologyURL
        )

        let imported = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(imported.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
        #expect(imported.aggregateStats.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize)
        #expect(imported.aggregateStats.fileCount == snapshot.aggregateStats.fileCount)
    }

    @Test
    func testImportSupportsLegacyVersionThreeFullPathNodes() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: versionFourOptions()
        )
        try rewriteArchiveAsLegacyVersionThree(snapshot: snapshot, archiveURL: archiveURL)

        let result = try await service.importSnapshot(from: archiveURL)

        #expect(result.manifest.formatVersion == 3)
        #expect(result.manifest.createdBy.swiftSchema == "ScanArchiveV3")
        let importedNodeIDs = result.snapshot.treeStore.indexedNodeIDs()
        let expectedNodeIDs = snapshot.treeStore.indexedNodeIDs()
        #expect(Set(importedNodeIDs) == Set(expectedNodeIDs))
        for nodeID in expectedNodeIDs {
            let imported = try #require(result.snapshot.treeStore.node(id: nodeID))
            let expected = try #require(snapshot.treeStore.node(id: nodeID))
            #expect(imported.id == expected.id)
            #expect(imported.url.path == expected.url.path)
            #expect(imported.name == expected.name)
            #expect(imported.allocatedSize == expected.allocatedSize)
            #expect(imported.logicalSize == expected.logicalSize)
            #expect(imported.fileIdentity == expected.fileIdentity)
        }
        #expect(result.snapshot.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
    }

    @Test
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

        #expect(importResult.manifest.snapshot.scanOptions == nil)
        #expect(importResult.snapshot.scanOptions == nil)
        #expect(importResult.manifest.snapshot.scanOptionsFingerprint != nil)
    }

    @Test
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
            Issue.record("Import should reject mismatched scan options.")
        } catch ScanArchiveError.integrity(let detail) {
            #expect(detail.contains("scan options"))
        }
    }

    @Test
    func testImportPreservesLegacyCloudOptionsFingerprint() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )

        let legacyOptionsJSON = """
            {
              "autoSummarizeDirectories" : true,
              "cloudStorageRootPath" : "/Users/legacy/Library/CloudStorage",
              "exclusionPatterns" : [
                "*.tmp"
              ],
              "iCloudDriveRootPath" : "/Users/legacy/Library/Mobile Documents",
              "includeCloudStorage" : false,
              "includeHiddenFiles" : true,
              "treatPackagesAsDirectories" : true
            }
            """
        let legacyOptionsData = Data(legacyOptionsJSON.utf8)
        let legacyFingerprint = Data(SHA256.hash(data: legacyOptionsData)).base64EncodedString()
        #expect(legacyFingerprint == "mm+r4ABNaL/7D66PDeo294NIIBeqAdsGH7crblteDRE=")

        let legacyOptionsObject = try #require(JSONSerialization.jsonObject(with: legacyOptionsData) as? [String: Any])
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var snapshot = object["snapshot"] as? [String: Any] ?? [:]
            snapshot["scanOptions"] = legacyOptionsObject
            snapshot["scanOptionsFingerprint"] = legacyFingerprint
            object["snapshot"] = snapshot
        }

        let importResult = try await service.importSnapshot(from: archiveURL)
        let importedOptions = try #require(importResult.snapshot.scanOptions)

        #expect(try ScanArchiveService.scanOptionsFingerprint(importedOptions) == legacyFingerprint)
        #expect(importedOptions != makeArchiveSnapshot().scanOptions)
    }

    @Test
    func testCurrentScanOptionsEncodingOmitsRetiredCloudKeys() throws {
        let data = try JSONEncoder().encode(ScanOptions())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["includeCloudStorage"] == nil)
        #expect(object["cloudStorageRootPath"] == nil)
        #expect(object["iCloudDriveRootPath"] == nil)
    }

    @Test
    func testCurrentScanOptionsFingerprintRemainsStable() throws {
        #expect(
            try ScanArchiveService.scanOptionsFingerprint(makeArchiveSnapshot().scanOptions)
                == "vrZHfBWHKFSVW/Wj90PXwF3ZDHHCphJAdnb1LmzfeT0=")
    }

    @Test
    func testPreviewReadsManifestAndStatsMetadata() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(appVersion: "Tests")
        )
        let expectedArchiveSize = try FileManager.default
            .subpathsOfDirectory(atPath: archiveURL.path)
            .reduce(into: Int64(0)) { totalSize, relativePath in
                let fileURL = archiveURL.appending(path: relativePath)
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                if values.isRegularFile == true {
                    totalSize += Int64(values.fileSize ?? 0)
                }
            }

        let preview = try await service.previewSnapshot(from: archiveURL)

        #expect(preview.archiveURL == archiveURL)
        #expect(preview.archiveSize == expectedArchiveSize)
        #expect(preview.appVersion == "Tests")
        #expect(preview.target.path == snapshot.target.url.path)
        #expect(preview.target.displayName == snapshot.target.displayName)
        #expect(preview.startedAt == snapshot.startedAt)
        #expect(preview.finishedAt == snapshot.finishedAt)
        #expect(preview.nodeCount == snapshot.treeStore.nodeCount)
        #expect(preview.warningCount == snapshot.scanWarnings.count)
        #expect(preview.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize)
        #expect(preview.totalLogicalSize == snapshot.aggregateStats.totalLogicalSize)
        #expect(preview.fileCount == snapshot.aggregateStats.fileCount)
        #expect(preview.directoryCount == snapshot.aggregateStats.directoryCount)
        #expect(preview.scanOptions == snapshot.scanOptions)
    }

    @Test
    func testPreviewAndImportRejectNegativeStats() async throws {
        let service = ScanArchiveService()
        let fields = [
            "totalAllocatedSize",
            "totalLogicalSize",
            "fileCount",
            "directoryCount",
            "accessibleItemCount",
            "inaccessibleItemCount",
        ]

        for field in fields {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: archiveURL,
                options: versionFourOptions()
            )
            let statsURL = archiveURL.appending(path: "stats.json", directoryHint: .notDirectory)
            try rewriteJSONObject(at: statsURL) { object in
                object[field] = -1
            }

            do {
                _ = try await service.previewSnapshot(from: archiveURL)
                Issue.record("Preview should reject negative \(field).")
            } catch ScanArchiveError.stats(let detail) {
                #expect(detail.contains("negative"), "Unexpected detail for \(field): \(detail)")
            }

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject negative \(field).")
            } catch ScanArchiveError.stats(let detail) {
                #expect(detail.contains("negative"), "Unexpected detail for \(field): \(detail)")
            }
        }
    }

    @Test
    func testPreviewAndImportRejectOversizedStatsBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )
        let statsURL = archiveURL.appending(path: "stats.json", directoryHint: .notDirectory)
        try Data(repeating: 0x20, count: (256 * 1_024) + 1).write(to: statsURL, options: [.atomic])

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            Issue.record("Preview should reject an oversized stats section.")
        } catch ScanArchiveError.stats(let detail) {
            #expect(detail.contains("supported size"))
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject an oversized stats section.")
        } catch ScanArchiveError.stats(let detail) {
            #expect(detail.contains("supported size"))
        }
    }

    @Test
    func testImportRejectsOversizedTopologyBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )
        let topologyURL = archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
        try Data(repeating: 0x20, count: 128 * 1_024).write(to: topologyURL, options: [.atomic])

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject an oversized topology section.")
        } catch ScanArchiveError.topology(let detail) {
            #expect(detail.contains("supported size"))
        }
    }

    @Test
    func testImportRejectsOversizedWarningsBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )
        let warningsURL = archiveURL.appending(path: "warnings.json", directoryHint: .notDirectory)
        try Data(repeating: 0x20, count: 192 * 1_024).write(to: warningsURL, options: [.atomic])

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject an oversized warnings section.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(detail.contains("supported size"))
        }
    }

    @Test
    func testPreviewRejectsOversizedManifestBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try Data(repeating: 0x20, count: (1 * 1_024 * 1_024) + 1).write(
            to: manifestURL,
            options: [.atomic]
        )

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            Issue.record("Preview should reject an oversized manifest.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(detail.contains("supported size"))
        }
    }

    @Test
    func testImportHandlesUntrustedHugeManifestNodeCountWithoutPreallocatingIt() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            var snapshot = object["snapshot"] as? [String: Any] ?? [:]
            snapshot["nodeCount"] = Int.max
            object["snapshot"] = snapshot
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject a manifest node count that does not match its payload.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(detail.contains("manifest expected"))
        }
    }

    @Test
    func testExportWritesOrdinalTopology() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: versionFourOptions()
        )

        let topologyURL = archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
        let topologyData = try Data(contentsOf: topologyURL)
        let topologyObject = try #require(JSONSerialization.jsonObject(with: topologyData) as? [String: Any])
        let childMap = try #require(topologyObject["c"] as? [String: Any])
        let encodedTopology = try #require(String(data: topologyData, encoding: .utf8))

        #expect(topologyObject["r"] as? Int == 0)
        #expect(childMap["0"] as? [Int] != nil)
        #expect(topologyObject["rootID"] == nil)
        #expect(topologyObject["childIDsByID"] == nil)
        #expect(!(encodedTopology.contains("/archive")))
    }

    @Test
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

        #expect(!(FileManager.default.fileExists(atPath: oldOnlyURL.path)))
        let preview = try await service.previewSnapshot(from: archiveURL)
        #expect(preview.appVersion == "New")
        #expect(preview.nodeCount == replacementSnapshot.treeStore.nodeCount)
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot
        #expect(importedSnapshot.treeStore.nodeCount == replacementSnapshot.treeStore.nodeCount)
    }

    @Test
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
            Issue.record("Export should reject destinations without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            #expect(detail.contains(".radixscan"))
        }

        #expect(!(FileManager.default.fileExists(atPath: wrongExtensionURL.path)))
    }

    @Test
    func testExportRejectsUnsupportedInternalFormatVersions() async throws {
        let service = ScanArchiveService()

        for formatVersion in [3, 6] {
            let archiveURL = try makeTemporaryArchiveURL()

            do {
                _ = try await service.export(
                    snapshot: makeArchiveSnapshot(),
                    to: archiveURL,
                    options: ScanArchiveExportOptions(formatVersion: formatVersion)
                )
                Issue.record("Export should reject unsupported version \(formatVersion).")
            } catch ScanArchiveError.unsupportedVersion(let rejectedVersion) {
                #expect(rejectedVersion == formatVersion)
            }

            #expect(!(FileManager.default.fileExists(atPath: archiveURL.path)))
        }
    }

    @Test
    func testImportRejectsWrongArchiveExtension() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())
        let wrongExtensionURL = archiveURL.deletingPathExtension().appendingPathExtension("foo")
        try FileManager.default.moveItem(at: archiveURL, to: wrongExtensionURL)

        do {
            _ = try await service.previewSnapshot(from: wrongExtensionURL)
            Issue.record("Preview should reject packages without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            #expect(detail.contains(".radixscan"))
        }

        do {
            _ = try await service.importSnapshot(from: wrongExtensionURL)
            Issue.record("Import should reject packages without the .radixscan extension.")
        } catch ScanArchiveError.invalidArchivePackage(let detail) {
            #expect(detail.contains(".radixscan"))
        }
    }

    @Test
    func testImportRejectsEmptyArchivePackage() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            Issue.record("Preview should reject empty archive packages.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(!(detail.isEmpty))
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject empty archive packages.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(!(detail.isEmpty))
        }
    }

    @Test
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
            Issue.record("Cancelled export should not replace existing archive.")
        } catch is CancellationError {
        }

        let preview = try await service.previewSnapshot(from: archiveURL)
        #expect(preview.appVersion == "Original")
        #expect(preview.nodeCount == originalSnapshot.treeStore.nodeCount)
        #expect(try temporaryArchiveSiblings(for: archiveURL).isEmpty)
    }

    @Test
    func testCancelledImportStopsBeforePublishingSnapshot() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeLargeArchiveSnapshot(childCount: 100_000),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )

        let progressReporter = ScanArchiveProgressReporter()
        let importTask = Task {
            try await service.importSnapshot(
                from: archiveURL,
                progressReporter: progressReporter
            )
        }
        defer {
            progressReporter.finish()
            importTask.cancel()
        }

        try await waitForProgressPhase(.readingNodes, from: progressReporter)
        importTask.cancel()

        do {
            _ = try await importTask.value
            Issue.record("Cancelled import should not publish a snapshot.")
        } catch is CancellationError {
        }
    }

    @Test
    func testImportRejectsNodesChecksumMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        let handle = try FileHandle(forWritingTo: nodesURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject modified node payload.")
        } catch ScanArchiveError.integrity(let detail) {
            #expect(detail.contains("checksum"))
        }
    }

    @Test
    func testImportRejectsMissingNodeSectionAsArchiveError() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )
        try FileManager.default.removeItem(at: archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory))

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject missing node sections as archive node errors.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(!(detail.isEmpty))
        }
    }

    @Test
    func testPreviewAndImportRejectSectionSymlinkEscapingArchive() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )

        let statsURL = archiveURL.appending(path: "stats.json", directoryHint: .notDirectory)
        let externalStatsURL = archiveURL.deletingLastPathComponent()
            .appending(path: "external-stats.json", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: statsURL, to: externalStatsURL)
        try FileManager.default.createSymbolicLink(at: statsURL, withDestinationURL: externalStatsURL)

        do {
            _ = try await service.previewSnapshot(from: archiveURL)
            Issue.record("Preview should reject section symlinks that escape the archive.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(detail.contains("stats"))
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject section symlinks that escape the archive.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(detail.contains("stats"))
        }
    }

    @Test
    func testImportRejectsNodePayloadExceedingManifestCountEarly() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let checksum = try appendArchiveNode(
            [
                "x": "extra.txt",
                "v": ["a": 1],
            ], in: archiveURL)
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject node payloads that exceed the manifest count while reading.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(detail.contains("more nodes"))
        }
    }

    @Test
    func testImportRejectsOversizedNodeLineBeforeDecoding() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let nodesURL = archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory)
        try Data(repeating: 0x7B, count: 2 * 1024 * 1024).write(to: nodesURL, options: [.atomic])

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject oversized node lines before decoding JSON.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(detail.contains("too large"))
        }
    }

    @Test
    func testImportRejectsMalformedTopology() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let validTopology = try ScanArchiveTopology(snapshot.treeStore)
        let rootKey = String(validTopology.rootOrdinal)
        let rootChildren = try #require(validTopology.childOrdinalsByOrdinal[rootKey])
        let firstChildOrdinal = try #require(rootChildren.first)
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
            _ = try await service.export(
                snapshot: snapshot,
                to: archiveURL,
                options: versionFourOptions()
            )
            try encodeArchiveJSON(
                testCase.topology,
                to: archiveURL.appending(path: "topology.json", directoryHint: .notDirectory)
            )

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject malformed topology: \(testCase.name).")
            } catch ScanArchiveError.topology(let detail) {
                #expect(
                    detail.contains(testCase.expectedDetail),
                    "Expected \(testCase.expectedDetail) for \(testCase.name), got \(detail).")
            }
        }
    }

    @Test
    func testImportRejectsNodePathMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
            if archiveNodeName(node) == "hard-link-a.bin" {
                setArchiveNodePath("/tmp/other.txt", in: &node)
            }
        }
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject node path mismatches.")
        } catch ScanArchiveError.nodes(let detail) {
            #expect(detail.contains("path"))
        }
    }

    @Test
    func testImportRejectsUnsafeRelativePathComponents() async throws {
        let service = ScanArchiveService()
        for component in ["..", "unsafe\0name"] {
            let archiveURL = try makeTemporaryArchiveURL()
            _ = try await service.export(
                snapshot: makeArchiveSnapshot(),
                to: archiveURL,
                options: versionFourOptions()
            )

            let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
                if archiveNodeName(node) == "hard-link-a.bin" {
                    node["x"] = component
                }
            }
            try rewriteManifestNodeChecksum(checksum, in: archiveURL)

            do {
                _ = try await service.importSnapshot(from: archiveURL)
                Issue.record("Import should reject unsafe relative path component \(component.debugDescription).")
            } catch ScanArchiveError.nodes(let detail) {
                #expect(detail.contains("relative path"))
            }
        }
    }

    @Test
    func testImportRejectsTargetRootPathMismatch() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())

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
            Issue.record("Import should reject target/root mismatches.")
        } catch ScanArchiveError.manifest(let detail) {
            #expect(detail.contains("root"))
        }
    }

    @Test
    func testImportRejectsChildOutsideParentPath() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let newID = "/tmp/other.txt"
        let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
            if archiveNodeName(node) == "hard-link-a.bin" {
                setArchiveNodeID(newID, in: &node)
                setArchiveNodePath(newID, in: &node)
                setArchiveNodeName("other.txt", in: &node)
            }
        }
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject children outside the parent path.")
        } catch ScanArchiveError.topology(let detail) {
            #expect(detail.contains("path"))
        }
    }

    @Test
    func testImportRejectsRelativeChildOfSyntheticParentOutsideTarget() async throws {
        let child = makeTestFileNode(
            id: "/tmp/archive-synthetic/child.bin",
            name: "child.bin",
            size: 1
        )
        let syntheticParent = FileNodeRecord(
            id: "/archive#synthetic-directory",
            url: URL(filePath: "/tmp/archive-synthetic", directoryHint: .isDirectory),
            name: "Synthetic Directory",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let root = makeTestDirectoryNode(id: "/archive", name: "archive", children: [syntheticParent])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [syntheticParent],
                syntheticParent.id: [child],
            ])
        let archiveURL = try makeTemporaryArchiveURL()
        let service = ScanArchiveService()
        _ = try await service.export(
            snapshot: makeTestSnapshot(root: root, store: store),
            to: archiveURL,
            options: ScanArchiveExportOptions()
        )

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject relative children outside the target.")
        } catch ScanArchiveError.topology(let detail) {
            #expect(detail.contains("outside target"))
        }
    }

    @Test(arguments: [2, 99])
    func testPreviewAndImportRejectUnsupportedVersions(version: Int) async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(), to: archiveURL, options: ScanArchiveExportOptions())
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { $0["formatVersion"] = version }

        await #expect(throws: ScanArchiveError.unsupportedVersion(version)) {
            try await service.previewSnapshot(from: archiveURL)
        }
        await #expect(throws: ScanArchiveError.unsupportedVersion(version)) {
            try await service.importSnapshot(from: archiveURL)
        }
    }

    @Test
    func testImportRejectsMinimalFutureVersionManifest() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        let manifestData = Data(
            """
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
            Issue.record("Preview should reject future versions before decoding the archive body.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            #expect(version == 99)
        }

        do {
            _ = try await service.importSnapshot(from: archiveURL)
            Issue.record("Import should reject future versions before decoding the archive body.")
        } catch ScanArchiveError.unsupportedVersion(let version) {
            #expect(version == 99)
        }
    }

    @Test
    func testImportRepairsMismatchedStatsAndRecordsWarning() async throws {
        let service = ScanArchiveService()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: makeArchiveSnapshot(),
            to: archiveURL,
            options: versionFourOptions()
        )

        let statsURL = archiveURL.appending(path: "stats.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: statsURL) { object in
            object["totalAllocatedSize"] = 1
        }

        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(importedSnapshot.aggregateStats.totalAllocatedSize == importedSnapshot.root.allocatedSize)
        #expect(
            importedSnapshot.scanWarnings.contains { warning in
                warning.message.contains("repaired totals")
            })
    }

    @Test
    func testImportRepairsMismatchedMaterializedDirectoryTotals() async throws {
        let service = ScanArchiveService()
        let snapshot = makeArchiveSnapshot()
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: versionFourOptions()
        )
        let expectedFolder = try #require(snapshot.treeStore.node(id: "/archive/folder"))

        let checksum = try rewriteArchiveNodes(in: archiveURL) { node in
            if archiveNodeName(node) == "folder" {
                setArchiveNodeAllocatedSize(1, in: &node)
            }
        }
        try rewriteManifestNodeChecksum(checksum, in: archiveURL)

        let imported = try await service.importSnapshot(from: archiveURL).snapshot
        let importedFolder = try #require(imported.treeStore.node(id: expectedFolder.id))

        #expect(importedFolder.allocatedSize == expectedFolder.allocatedSize)
        #expect(importedFolder.logicalSize == expectedFolder.logicalSize)
        #expect(importedFolder.descendantFileCount == expectedFolder.descendantFileCount)
    }

    @Test
    func testLargeTopologyRoundTripsDeterministicOrder() async throws {
        let service = ScanArchiveService()
        let snapshot = makeLargeArchiveSnapshot(childCount: 1_500)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(importedSnapshot.treeStore.nodeCount == snapshot.treeStore.nodeCount)
        #expect(
            importedSnapshot.treeStore.children(of: snapshot.root.id).map(\.id)
                == snapshot.treeStore.children(of: snapshot.root.id).map(\.id))
        #expect(importedSnapshot.aggregateStats.fileCount == 1_500)
    }

    @Test
    func testDeepTopologyImportDoesNotOverflowStack() async throws {
        let service = ScanArchiveService()
        let depth = 12_000
        let snapshot = makeDeepArchiveSnapshot(depth: depth)
        let archiveURL = try makeTemporaryArchiveURL()

        _ = try await service.export(snapshot: snapshot, to: archiveURL, options: ScanArchiveExportOptions())
        let importedSnapshot = try await service.importSnapshot(from: archiveURL).snapshot

        #expect(importedSnapshot.treeStore.nodeCount == snapshot.treeStore.nodeCount)
        #expect(importedSnapshot.treeStore.childIDsByID == snapshot.treeStore.childIDsByID)
        #expect(importedSnapshot.aggregateStats.fileCount == 1)
        #expect(importedSnapshot.treeStore.path(to: makeDeepArchiveNodeID(depth)).count == depth + 1)
    }

    private func makeTemporaryArchiveURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryFiles.track(directoryURL)
        return directoryURL.appending(path: "Export.radixscan", directoryHint: .isDirectory)
    }

    private func versionFourOptions(
        appVersion: String? = nil,
        progressReporter: ScanArchiveProgressReporter? = nil
    ) -> ScanArchiveExportOptions {
        ScanArchiveExportOptions(
            appVersion: appVersion,
            formatVersion: 4,
            progressReporter: progressReporter
        )
    }

    private func exportAndImport(
        _ snapshot: ScanSnapshot,
        formatVersion: Int,
        service: ScanArchiveService
    ) async throws -> ScanSnapshot {
        let archiveURL = try makeTemporaryArchiveURL()
        _ = try await service.export(
            snapshot: snapshot,
            to: archiveURL,
            options: ScanArchiveExportOptions(formatVersion: formatVersion)
        )
        return try await service.importSnapshot(from: archiveURL).snapshot
    }

    private func assertEquivalentSnapshots(
        _ lhs: ScanSnapshot,
        _ rhs: ScanSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(lhs.id == rhs.id, sourceLocation: sourceLocation)
        #expect(lhs.target == rhs.target, sourceLocation: sourceLocation)
        #expect(lhs.startedAt == rhs.startedAt, sourceLocation: sourceLocation)
        #expect(lhs.finishedAt == rhs.finishedAt, sourceLocation: sourceLocation)
        #expect(lhs.isComplete == rhs.isComplete, sourceLocation: sourceLocation)
        #expect(lhs.scanOptions == rhs.scanOptions, sourceLocation: sourceLocation)
        #expect(lhs.volumeCapacity == rhs.volumeCapacity, sourceLocation: sourceLocation)
        #expect(lhs.scanWarnings.map(\.path) == rhs.scanWarnings.map(\.path), sourceLocation: sourceLocation)
        #expect(lhs.scanWarnings.map(\.message) == rhs.scanWarnings.map(\.message), sourceLocation: sourceLocation)
        #expect(lhs.scanWarnings.map(\.category) == rhs.scanWarnings.map(\.category), sourceLocation: sourceLocation)
        let lhsNodeIDs = lhs.treeStore.indexedNodeIDs()
        let rhsNodeIDs = rhs.treeStore.indexedNodeIDs()
        #expect(lhsNodeIDs == rhsNodeIDs, sourceLocation: sourceLocation)
        #expect(lhs.treeStore.rootID == rhs.treeStore.rootID, sourceLocation: sourceLocation)
        #expect(lhs.treeStore.childIDsByID == rhs.treeStore.childIDsByID, sourceLocation: sourceLocation)
        for nodeID in lhsNodeIDs {
            #expect(
                lhs.treeStore.node(id: nodeID) == rhs.treeStore.node(id: nodeID), "Node mismatch at \(nodeID)",
                sourceLocation: sourceLocation)
        }
        #expect(
            lhs.aggregateStats.totalAllocatedSize == rhs.aggregateStats.totalAllocatedSize,
            sourceLocation: sourceLocation)
        #expect(
            lhs.aggregateStats.totalLogicalSize == rhs.aggregateStats.totalLogicalSize, sourceLocation: sourceLocation)
        #expect(lhs.aggregateStats.fileCount == rhs.aggregateStats.fileCount, sourceLocation: sourceLocation)
        #expect(lhs.aggregateStats.directoryCount == rhs.aggregateStats.directoryCount, sourceLocation: sourceLocation)
        #expect(
            lhs.aggregateStats.accessibleItemCount == rhs.aggregateStats.accessibleItemCount,
            sourceLocation: sourceLocation)
        #expect(
            lhs.aggregateStats.inaccessibleItemCount == rhs.aggregateStats.inaccessibleItemCount,
            sourceLocation: sourceLocation)
        if case .imported(let lhsContext) = lhs.source,
            case .imported(let rhsContext) = rhs.source
        {
            #expect(lhsContext.pathMode == rhsContext.pathMode, sourceLocation: sourceLocation)
            #expect(lhsContext.liveActionCapability == rhsContext.liveActionCapability, sourceLocation: sourceLocation)
        } else {
            Issue.record("Expected imported snapshot sources.", sourceLocation: sourceLocation)
        }
    }

    private func readManifest(from archiveURL: URL) throws -> ScanArchiveDocument {
        try ScanArchiveService.makeJSONDecoder().decode(
            ScanArchiveDocument.self,
            from: Data(contentsOf: archiveURL.appending(path: "manifest.json"))
        )
    }

    private func writeSection(
        _ data: Data,
        to url: URL,
        encoding: ScanArchiveSectionEncoding
    ) throws -> String {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var writer = try ScanArchiveSectionWriter(
            fileHandle: handle,
            encoding: encoding
        )
        try writer.append(data)
        return try writer.finish()
    }

    private func rewriteManifestChecksum(
        _ checksum: String,
        key: String,
        in archiveURL: URL
    ) throws {
        let manifestURL = archiveURL.appending(path: "manifest.json")
        try rewriteJSONObject(at: manifestURL) { object in
            var integrity = object["integrity"] as? [String: Any] ?? [:]
            integrity[key] = checksum
            object["integrity"] = integrity
        }
    }

    private func rewriteManifestByteCount(
        _ byteCount: Int64,
        key: String,
        in archiveURL: URL
    ) throws {
        let manifestURL = archiveURL.appending(path: "manifest.json")
        try rewriteJSONObject(at: manifestURL) { object in
            var counts = object["sectionByteCounts"] as? [String: Any] ?? [:]
            counts[key] = byteCount
            object["sectionByteCounts"] = counts
        }
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
            id: "/archive/folder/résource-文件-🙂.bin",
            url: URL(filePath: "/archive/folder/résource-文件-🙂.bin"),
            name: "résource-文件-🙂.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 80,
            dataAllocatedSize: 64,
            logicalSize: 80,
            descendantFileCount: 1,
            lastModified: Date(timeIntervalSince1970: 200),
            fileIdentity: FileIdentity(resourceIdentifier: Data([1, 2, 3, 4])),
            linkCount: 1,
            cloneIdentity: CloneIdentity(device: 10, cloneID: 30),
            mayShareDataBlocks: true,
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
        let store = FileTreeStore(
            root: root,
            childrenByID: [
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
            isComplete: true,
            scanOptions: scanOptions,
            volumeCapacity: VolumeCapacitySnapshot(totalCapacity: 1_000, availableCapacity: 400)
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
        var parentID = rootID

        for index in 1...depth {
            let nodeID = makeDeepArchiveNodeID(index)
            let nodeName = "node-\(String(format: "%05d", index))"
            let node =
                index == depth
                ? makeTestFileNode(id: nodeID, name: nodeName, size: 64)
                : makeDeepArchiveDirectoryNode(id: nodeID, name: nodeName)

            nodesByID[nodeID] = node
            childIDsByID[parentID] = [nodeID]
            parentID = nodeID
        }

        let store = FileTreeStore(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
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

    private func archiveNodeName(_ node: [String: Any]) -> String? {
        if let payload = node["v"] as? [String: Any] {
            return payload["n"] as? String ?? node["x"] as? String
        }
        return node["name"] as? String ?? node["n"] as? String
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
        if var payload = node["v"] as? [String: Any] {
            payload["n"] = name
            node["v"] = payload
            return
        }
        if node["name"] != nil {
            node["name"] = name
        } else {
            node["n"] = name
        }
    }

    private func setArchiveNodeAllocatedSize(_ size: Int64, in node: inout [String: Any]) {
        if var payload = node["v"] as? [String: Any] {
            payload["a"] = size
            node["v"] = payload
        } else {
            node["a"] = size
        }
    }

    private func legacyNodeData(for snapshot: ScanSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for nodeID in snapshot.treeStore.indexedNodeIDs() {
            let node = try #require(snapshot.treeStore.node(id: nodeID))
            data.append(try encoder.encode(ScanArchiveNode(node)))
            data.append(Data("\n".utf8))
        }
        return data
    }

    private func rewriteArchiveAsLegacyVersionThree(
        snapshot: ScanSnapshot,
        archiveURL: URL
    ) throws {
        let nodeData = try legacyNodeData(for: snapshot)
        try nodeData.write(
            to: archiveURL.appending(path: "nodes.jsonl", directoryHint: .notDirectory),
            options: [.atomic]
        )
        let checksum = Data(SHA256.hash(data: nodeData)).base64EncodedString()
        let manifestURL = archiveURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try rewriteJSONObject(at: manifestURL) { object in
            object["formatVersion"] = 3
            var createdBy = object["createdBy"] as? [String: Any] ?? [:]
            createdBy["swiftSchema"] = "ScanArchiveV3"
            object["createdBy"] = createdBy
            var integrity = object["integrity"] as? [String: Any] ?? [:]
            integrity["nodes"] = checksum
            object["integrity"] = integrity
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
            var object = try #require(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
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
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        let rewrittenData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewrittenData.write(to: url, options: [.atomic])
    }
}

private enum AsyncWaitError: Error {
    case streamFinished
    case timedOut
}
