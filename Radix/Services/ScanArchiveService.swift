//
//  ScanArchiveService.swift
//  Radix
//
//  Created by Codex on 6/22/26.
//

import CryptoKit
import Foundation

nonisolated protocol ScanArchiveServicing: Sendable {
    func export(
        snapshot: ScanSnapshot,
        to destinationURL: URL,
        options: ScanArchiveExportOptions
    ) async throws -> ScanArchiveExportResult

    func previewSnapshot(from sourceURL: URL) async throws -> ScanArchivePreview

    func importSnapshot(
        from sourceURL: URL,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> ScanArchiveImportResult
}

extension ScanArchiveServicing {
    func importSnapshot(from sourceURL: URL) async throws -> ScanArchiveImportResult {
        try await importSnapshot(from: sourceURL, progressReporter: nil)
    }
}

nonisolated struct ScanArchiveExportOptions: Sendable {
    var pathMode: ScanArchivePathMode
    var appVersion: String?
    var formatVersion: Int
    var progressReporter: ScanArchiveProgressReporter?

    nonisolated init(
        pathMode: ScanArchivePathMode = .absolute,
        appVersion: String? = nil,
        formatVersion: Int = ScanArchiveService.currentFormatVersion,
        progressReporter: ScanArchiveProgressReporter? = nil
    ) {
        self.pathMode = pathMode
        self.appVersion = appVersion
        self.formatVersion = formatVersion
        self.progressReporter = progressReporter
    }
}

nonisolated struct ScanArchiveExportResult: Sendable {
    let archiveURL: URL
    let nodeChecksum: String
}

nonisolated struct ScanArchiveImportResult: Sendable {
    let archiveURL: URL
    let snapshot: ScanSnapshot
    let manifest: ScanArchiveDocument
}

nonisolated enum ScanArchiveProgressPhase: String, Sendable {
    case preparing
    case writingNodes
    case writingTopology
    case writingMetadata
    case readingManifest
    case readingNodes
    case readingTopology
    case validatingTopology
    case readingMetadata
    case rebuildingSnapshot
    case openingSnapshot
}

nonisolated enum ScanArchiveImportProfilePhase: String, CaseIterable, Sendable {
    case readArchiveMetadata = "read_archive_metadata"
    case prepareTopology = "prepare_topology"
    case readAndMaterializeNodes = "read_and_materialize_nodes"
    case nodeIOWork = "node_io_work"
    case nodeDecodeWork = "node_decode_work"
    case nodeDecodeWait = "node_decode_wait"
    case nodeMaterializationWork = "node_materialization_work"
    case finalizeTreeStore = "finalize_tree_store"
    case finishSnapshot = "finish_snapshot"
}

nonisolated struct ScanArchiveProgress: Equatable, Sendable {
    let phase: ScanArchiveProgressPhase
    let completedUnitCount: Int
    let totalUnitCount: Int?
    let message: String

    nonisolated init(
        phase: ScanArchiveProgressPhase,
        completedUnitCount: Int = 0,
        totalUnitCount: Int? = nil,
        message: String
    ) {
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.message = message
    }

    var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }
}

nonisolated final class ScanArchiveProgressReporter: @unchecked Sendable {
    let updates: AsyncStream<ScanArchiveProgress>
    private let continuation: AsyncStream<ScanArchiveProgress>.Continuation

    nonisolated init() {
        let streamPair = AsyncStream.makeStream(
            of: ScanArchiveProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = streamPair.stream
        self.continuation = streamPair.continuation
    }

    func report(_ progress: ScanArchiveProgress) {
        continuation.yield(progress)
    }

    func finish() {
        continuation.finish()
    }
}

nonisolated struct ScanArchivePreview: Identifiable, Sendable {
    let archiveURL: URL
    let archiveSize: Int64
    let exportedAt: Date
    let appVersion: String
    let target: ScanArchiveTargetV1
    let startedAt: Date
    let finishedAt: Date?
    let isComplete: Bool
    let nodeCount: Int
    let warningCount: Int
    let totalAllocatedSize: Int64
    let totalLogicalSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let accessibleItemCount: Int
    let inaccessibleItemCount: Int
    let scanOptions: ScanOptions?

    var id: URL {
        archiveURL
    }

    init(
        archiveURL: URL,
        archiveSize: Int64,
        manifest: ScanArchiveDocument,
        stats: ScanArchiveStatsV1
    ) {
        self.archiveURL = archiveURL
        self.archiveSize = archiveSize
        self.exportedAt = manifest.exportedAt
        self.appVersion = manifest.createdBy.appVersion
        self.target = manifest.snapshot.target
        self.startedAt = manifest.snapshot.startedAt
        self.finishedAt = manifest.snapshot.finishedAt
        self.isComplete = manifest.snapshot.isComplete
        self.nodeCount = manifest.snapshot.nodeCount
        self.warningCount = manifest.snapshot.warningCount
        self.totalAllocatedSize = stats.totalAllocatedSize
        self.totalLogicalSize = stats.totalLogicalSize
        self.fileCount = stats.fileCount
        self.directoryCount = stats.directoryCount
        self.accessibleItemCount = stats.accessibleItemCount
        self.inaccessibleItemCount = stats.inaccessibleItemCount
        self.scanOptions = manifest.snapshot.scanOptions
    }
}

nonisolated enum ScanArchiveError: LocalizedError, Equatable {
    case incompleteSnapshot
    case invalidArchivePackage(String)
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case manifest(String)
    case nodes(String)
    case topology(String)
    case integrity(String)
    case stats(String)

    static func invalidArchivePackage(localized detail: LocalizedStringResource) -> Self {
        .invalidArchivePackage(String(localized: detail))
    }

    static func manifest(localized detail: LocalizedStringResource) -> Self {
        .manifest(String(localized: detail))
    }

    static func nodes(localized detail: LocalizedStringResource) -> Self {
        .nodes(String(localized: detail))
    }

    static func topology(localized detail: LocalizedStringResource) -> Self {
        .topology(String(localized: detail))
    }

    static func integrity(localized detail: LocalizedStringResource) -> Self {
        .integrity(String(localized: detail))
    }

    static func stats(localized detail: LocalizedStringResource) -> Self {
        .stats(String(localized: detail))
    }

    var errorDescription: String? {
        switch self {
        case .incompleteSnapshot:
            return String(localized: "Only complete scans can be exported.", comment: "Error shown when exporting a scan that is still in progress.")
        case .invalidArchivePackage(let detail):
            return String(localized: "The Radix scan snapshot package is invalid: \(detail)", comment: "Error shown when an imported snapshot package is malformed.")
        case .unsupportedFormat(let format):
            return String(localized: "Unsupported Radix scan snapshot format: \(format).", comment: "Error shown when an imported snapshot uses an unknown format.")
        case .unsupportedVersion(let version):
            return String(localized: "Unsupported Radix scan snapshot version: \(version).", comment: "Error shown when an imported snapshot uses an unsupported version.")
        case .manifest(let detail):
            return String(localized: "Radix could not read the scan snapshot manifest: \(detail)", comment: "Error shown when an imported snapshot manifest cannot be read.")
        case .nodes(let detail):
            return String(localized: "Radix could not read the scan snapshot node payload: \(detail)", comment: "Error shown when imported snapshot node data cannot be read.")
        case .topology(let detail):
            return String(localized: "Radix could not read the scan snapshot topology: \(detail)", comment: "Error shown when imported snapshot tree topology cannot be read.")
        case .integrity(let detail):
            return String(localized: "Radix scan snapshot integrity check failed: \(detail)", comment: "Error shown when an imported snapshot fails its integrity check.")
        case .stats(let detail):
            return String(localized: "Radix could not read the scan snapshot stats: \(detail)", comment: "Error shown when imported snapshot statistics cannot be read.")
        }
    }
}

nonisolated struct ScanArchiveService: ScanArchiveServicing {
    nonisolated static let fileExtension = "radixscan"
    nonisolated static let formatIdentifier = "dev.colinkim.radix.scan"
    nonisolated static let currentFormatVersion = 5
    private nonisolated static let oldestSupportedFormatVersion = 3

    private nonisolated static let manifestFileName = "manifest.json"
    private nonisolated static let nodesFileName = "nodes.jsonl"
    private nonisolated static let compressedNodesFileName = "nodes.jsonl.lzfse"
    private nonisolated static let topologyFileName = "topology.json"
    private nonisolated static let compressedTopologyFileName = "topology.json.lzfse"
    private nonisolated static let warningsFileName = "warnings.json"
    private nonisolated static let statsFileName = "stats.json"

    private nonisolated static let maximumManifestByteCount = 1 * 1_024 * 1_024
    private nonisolated static let maximumStatsByteCount = 256 * 1_024
    private nonisolated static let maximumTopologyByteCount = 512 * 1_024 * 1_024
    private nonisolated static let maximumWarningsByteCount = 64 * 1_024 * 1_024
    private nonisolated static let sectionReadChunkByteCount = 64 * 1_024

    private let importProfileReporter: (@Sendable (ScanArchiveImportProfilePhase, Duration) -> Void)?

    init(
        fileManager: FileManager = .default,
        importProfileReporter: (@Sendable (ScanArchiveImportProfilePhase, Duration) -> Void)? = nil
    ) {
        _ = fileManager
        self.importProfileReporter = importProfileReporter
    }

    private var fileManager: FileManager {
        .default
    }

    func importProfileStart() -> ContinuousClock.Instant? {
        importProfileReporter == nil ? nil : ContinuousClock.now
    }

    func finishImportProfile(
        _ phase: ScanArchiveImportProfilePhase,
        startedAt: ContinuousClock.Instant?
    ) {
        guard let importProfileReporter, let startedAt else { return }
        importProfileReporter(phase, startedAt.duration(to: .now))
    }

    func export(
        snapshot: ScanSnapshot,
        to destinationURL: URL,
        options: ScanArchiveExportOptions = ScanArchiveExportOptions()
    ) async throws -> ScanArchiveExportResult {
        try Task.checkCancellation()
        guard snapshot.isComplete else {
            throw ScanArchiveError.incompleteSnapshot
        }
        let sectionEncodings: ScanArchiveSectionEncodings
        switch options.formatVersion {
        case 4:
            sectionEncodings = .identity
        case 5:
            sectionEncodings = .versionFive
        default:
            throw ScanArchiveError.unsupportedVersion(options.formatVersion)
        }
        try validateArchiveExtension(destinationURL)

        let archiveURL = try createTemporaryArchiveDirectory(for: destinationURL)
        var didInstallArchive = false
        defer {
            if !didInstallArchive {
                try? fileManager.removeItem(at: archiveURL)
            }
        }

        let isVersionFive = options.formatVersion == 5
        let archiveSections = ScanArchiveSections(
            nodes: sectionEncodings.nodes == .lzfse
                ? Self.compressedNodesFileName
                : Self.nodesFileName,
            topology: sectionEncodings.topology == .lzfse
                ? Self.compressedTopologyFileName
                : Self.topologyFileName,
            warnings: Self.warningsFileName,
            stats: Self.statsFileName
        )
        let nodesURL = archiveURL.appending(path: archiveSections.nodes, directoryHint: .notDirectory)
        let topologyURL = archiveURL.appending(path: archiveSections.topology, directoryHint: .notDirectory)
        let warningsURL = archiveURL.appending(path: archiveSections.warnings, directoryHint: .notDirectory)
        let statsURL = archiveURL.appending(path: archiveSections.stats, directoryHint: .notDirectory)
        let manifestURL = archiveURL.appending(path: Self.manifestFileName, directoryHint: .notDirectory)

        options.progressReporter?.report(ScanArchiveProgress(
            phase: .preparing,
            message: String(localized: "Preparing archive", comment: "Progress message while preparing a scan archive.")
        ))
        let nodeChecksum = try await writeNodes(
            snapshot.treeStore,
            to: nodesURL,
            encoding: sectionEncodings.nodes,
            progressReporter: options.progressReporter
        )
        try Task.checkCancellation()

        options.progressReporter?.report(ScanArchiveProgress(
            phase: .writingTopology,
            message: String(localized: "Writing topology", comment: "Progress message while writing scan tree topology.")
        ))
        let topologyChecksum = try await writeTopology(
            snapshot.treeStore,
            to: topologyURL,
            encoding: sectionEncodings.topology,
            progressReporter: options.progressReporter
        )

        options.progressReporter?.report(ScanArchiveProgress(
            phase: .writingMetadata,
            message: String(localized: "Writing metadata", comment: "Progress message while writing scan metadata.")
        ))
        let warningsChecksum = try writeJSON(
            snapshot.scanWarnings.map(ScanArchiveWarningV1.init),
            to: warningsURL
        )
        let statsChecksum = try writeJSON(
            ScanArchiveStatsV1(snapshot.aggregateStats),
            to: statsURL
        )
        let sectionByteCounts: ScanArchiveSectionByteCounts?
        if isVersionFive {
            sectionByteCounts = try ScanArchiveSectionByteCounts(
                nodes: fileByteCount(at: nodesURL),
                topology: fileByteCount(at: topologyURL),
                warnings: fileByteCount(at: warningsURL),
                stats: fileByteCount(at: statsURL)
            )
        } else {
            sectionByteCounts = nil
        }

        let manifest = try ScanArchiveDocument(
            exportedAt: Date(),
            appVersion: options.appVersion ?? Self.currentAppVersion(),
            snapshot: snapshot,
            pathMode: options.pathMode,
            sections: archiveSections,
            nodeChecksum: nodeChecksum,
            topologyChecksum: isVersionFive ? topologyChecksum : nil,
            warningsChecksum: isVersionFive ? warningsChecksum : nil,
            statsChecksum: isVersionFive ? statsChecksum : nil,
            formatVersion: options.formatVersion,
            sectionEncodings: isVersionFive ? sectionEncodings : nil,
            sectionByteCounts: sectionByteCounts
        )
        _ = try writeJSON(manifest, to: manifestURL)

        try Task.checkCancellation()
        try installArchive(from: archiveURL, to: destinationURL)
        didInstallArchive = true

        return ScanArchiveExportResult(archiveURL: destinationURL, nodeChecksum: nodeChecksum)
    }

    func previewSnapshot(from sourceURL: URL) async throws -> ScanArchivePreview {
        try Task.checkCancellation()
        let manifest = try readValidatedManifest(from: sourceURL)
        let sectionEncodings = try resolvedSectionEncodings(for: manifest)
        let statsURL = try sectionURL(
            named: manifest.sections.stats,
            in: sourceURL,
            sectionDescription: "stats"
        )
        if let sectionByteCounts = manifest.sectionByteCounts {
            try validateSectionByteCount(
                sectionByteCounts.stats,
                at: statsURL,
                sectionDescription: "stats"
            )
        }
        let stats: ScanArchiveStatsV1 = try readJSON(
            ScanArchiveStatsV1.self,
            from: statsURL,
            maximumByteCount: Self.maximumStatsByteCount,
            encoding: sectionEncodings.stats,
            expectedChecksum: manifest.integrity.stats,
            sectionDescription: "stats"
        ) { detail in
            ScanArchiveError.stats(detail)
        }
        try stats.validate()
        let archiveSize = try archiveLogicalSize(at: sourceURL)
        return ScanArchivePreview(
            archiveURL: sourceURL,
            archiveSize: archiveSize,
            manifest: manifest,
            stats: stats
        )
    }

    func importSnapshot(
        from sourceURL: URL,
        progressReporter: ScanArchiveProgressReporter? = nil
    ) async throws -> ScanArchiveImportResult {
        let metadataStartedAt = importProfileStart()
        try Task.checkCancellation()
        progressReporter?.report(ScanArchiveProgress(
            phase: .readingManifest,
            message: String(localized: "Reading manifest", comment: "Progress message while reading a scan archive manifest.")
        ))
        let manifest = try readValidatedManifest(from: sourceURL)
        let sectionEncodings = try resolvedSectionEncodings(for: manifest)

        let nodesURL = try sectionURL(
            named: manifest.sections.nodes,
            in: sourceURL,
            sectionDescription: "nodes"
        )
        let topologyURL = try sectionURL(
            named: manifest.sections.topology,
            in: sourceURL,
            sectionDescription: "topology"
        )
        let warningsURL = try sectionURL(
            named: manifest.sections.warnings,
            in: sourceURL,
            sectionDescription: "warnings"
        )
        let statsURL = try sectionURL(
            named: manifest.sections.stats,
            in: sourceURL,
            sectionDescription: "stats"
        )
        if let sectionByteCounts = manifest.sectionByteCounts {
            try validateSectionByteCount(
                sectionByteCounts.nodes,
                at: nodesURL,
                sectionDescription: "nodes"
            )
            try validateSectionByteCount(
                sectionByteCounts.topology,
                at: topologyURL,
                sectionDescription: "topology"
            )
            try validateSectionByteCount(
                sectionByteCounts.warnings,
                at: warningsURL,
                sectionDescription: "warnings"
            )
            try validateSectionByteCount(
                sectionByteCounts.stats,
                at: statsURL,
                sectionDescription: "stats"
            )
        }
        let archivedStats: ScanArchiveStatsV1 = try readJSON(
            ScanArchiveStatsV1.self,
            from: statsURL,
            maximumByteCount: Self.maximumStatsByteCount,
            encoding: sectionEncodings.stats,
            expectedChecksum: manifest.integrity.stats,
            sectionDescription: "stats"
        ) { detail in
            ScanArchiveError.stats(detail)
        }
        try archivedStats.validate()

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingTopology,
            message: String(localized: "Reading topology", comment: "Progress message while reading scan tree topology.")
        ))
        let archivedTopology: ScanArchiveTopology = try readJSON(
            ScanArchiveTopology.self,
            from: topologyURL,
            maximumByteCount: Self.maximumTopologySize(for: manifest.snapshot.nodeCount),
            encoding: sectionEncodings.topology,
            expectedChecksum: manifest.integrity.topology,
            sectionDescription: "topology"
        ) { detail in
            ScanArchiveError.topology(detail)
        }
        finishImportProfile(.readArchiveMetadata, startedAt: metadataStartedAt)

        let compactTreeStore: FileTreeStore?
        let legacyNodePayload: ScanArchiveNodePayload?
        if manifest.formatVersion >= 4 {
            compactTreeStore = try await readCompactTreeStore(
                from: nodesURL,
                expectedChecksum: manifest.integrity.nodes,
                expectedNodeCount: manifest.snapshot.nodeCount,
                encoding: sectionEncodings.nodes,
                topology: archivedTopology,
                expectedRootID: manifest.snapshot.rootID,
                expectedTargetPath: manifest.snapshot.target.path,
                progressReporter: progressReporter
            )
            legacyNodePayload = nil
        } else {
            let nodeReadingStartedAt = importProfileStart()
            legacyNodePayload = try await readLegacyNodes(
                from: nodesURL,
                expectedChecksum: manifest.integrity.nodes,
                expectedNodeCount: manifest.snapshot.nodeCount,
                encoding: sectionEncodings.nodes,
                progressReporter: progressReporter
            )
            finishImportProfile(.readAndMaterializeNodes, startedAt: nodeReadingStartedAt)
            compactTreeStore = nil
        }

        let snapshotFinalizationStartedAt = importProfileStart()

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingMetadata,
            message: String(localized: "Reading metadata", comment: "Progress message while reading scan metadata.")
        ))
        let warnings: [ScanArchiveWarningV1] = try readJSON(
            [ScanArchiveWarningV1].self,
            from: warningsURL,
            maximumByteCount: Self.maximumWarningsSize(for: manifest.snapshot.warningCount),
            encoding: sectionEncodings.warnings,
            expectedChecksum: manifest.integrity.warnings,
            sectionDescription: "warnings"
        ) { detail in
            ScanArchiveError.manifest(localized: "warnings section failed: \(detail)")
        }
        try Task.checkCancellation()
        progressReporter?.report(ScanArchiveProgress(
            phase: .rebuildingSnapshot,
            message: String(localized: "Rebuilding snapshot", comment: "Progress message while rebuilding an imported snapshot.")
        ))

        let treeStore: FileTreeStore
        if let compactTreeStore {
            try validateCounts(
                manifest: manifest,
                nodeCount: compactTreeStore.nodeCount,
                warnings: warnings
            )
            treeStore = compactTreeStore
        } else if let payload = legacyNodePayload {
            let topology = try archivedTopology.resolvedTopology(orderedNodeIDs: payload.orderedNodeIDs)
            try validateCounts(manifest: manifest, nodesByID: payload.nodesByID, warnings: warnings)
            try await validateTopology(
                topology,
                nodesByID: payload.nodesByID,
                expectedRootID: manifest.snapshot.rootID,
                expectedTargetPath: manifest.snapshot.target.path,
                progressReporter: progressReporter
            )
            treeStore = FileTreeStore(
                rootID: topology.rootID,
                nodesByID: payload.nodesByID,
                childIDsByID: topology.childIDsByID
            )
        } else {
            throw ScanArchiveError.nodes(localized: "node payload was not decoded")
        }
        var importedWarnings = try warnings.map { try $0.modelWarning() }
        let computedStats = treeStore.aggregateStats
        if !archivedStats.matches(computedStats) {
            importedWarnings.append(Self.repairedStatsWarning(rootID: treeStore.rootID))
        }

        let snapshot = ScanSnapshot(
            id: manifest.snapshot.id,
            target: manifest.snapshot.target.modelTarget(),
            treeStore: treeStore,
            startedAt: manifest.snapshot.startedAt,
            finishedAt: manifest.snapshot.finishedAt,
            scanWarnings: importedWarnings,
            isComplete: manifest.snapshot.isComplete,
            scanOptions: manifest.snapshot.scanOptions,
            volumeCapacity: manifest.snapshot.volumeCapacity,
            source: .imported(ImportedSnapshotContext(
                sourceURL: sourceURL,
                pathMode: manifest.snapshot.pathMode,
                liveActionCapability: manifest.snapshot.pathMode == .absolute ? .pathValidation : .disabled
            ))
        )

        finishImportProfile(.finishSnapshot, startedAt: snapshotFinalizationStartedAt)

        return ScanArchiveImportResult(archiveURL: sourceURL, snapshot: snapshot, manifest: manifest)
    }

    private func readValidatedManifest(from sourceURL: URL) throws -> ScanArchiveDocument {
        try validatePackage(at: sourceURL)

        let manifestURL = sourceURL.appending(path: Self.manifestFileName, directoryHint: .notDirectory)
        let manifestData = try readData(
            from: manifestURL,
            maximumByteCount: Self.maximumManifestByteCount
        ) { detail in
            ScanArchiveError.manifest(detail)
        }
        let header: ScanArchiveHeader = try decodeJSON(ScanArchiveHeader.self, from: manifestData) { detail in
            ScanArchiveError.manifest(detail)
        }
        try validateManifestHeader(format: header.format, formatVersion: header.formatVersion)
        let manifest: ScanArchiveDocument = try decodeJSON(ScanArchiveDocument.self, from: manifestData) { detail in
            ScanArchiveError.manifest(detail)
        }
        try validateManifest(manifest)
        return manifest
    }

    private func validatePackage(at url: URL) throws {
        try validateArchiveExtension(url)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanArchiveError.invalidArchivePackage(localized: "expected a .\(Self.fileExtension) package directory")
        }
    }

    private func validateArchiveExtension(_ url: URL) throws {
        guard url.pathExtension.lowercased() == Self.fileExtension else {
            throw ScanArchiveError.invalidArchivePackage(localized: "expected a .\(Self.fileExtension) package")
        }
    }

    private func archiveLogicalSize(at archiveURL: URL) throws -> Int64 {
        let relativePaths: [String]
        do {
            relativePaths = try fileManager.subpathsOfDirectory(atPath: archiveURL.path)
        } catch {
            throw ScanArchiveError.invalidArchivePackage(localized:
                "could not calculate snapshot size: \(error.localizedDescription)"
            )
        }

        var totalSize: Int64 = 0
        for relativePath in relativePaths {
            try Task.checkCancellation()
            let itemURL = archiveURL.appending(path: relativePath)
            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw ScanArchiveError.invalidArchivePackage(localized:
                    "could not calculate snapshot size: \(error.localizedDescription)"
                )
            }

            guard values.isRegularFile == true else {
                continue
            }

            let (newTotalSize, overflow) = totalSize.addingReportingOverflow(Int64(values.fileSize ?? 0))
            guard !overflow else {
                throw ScanArchiveError.invalidArchivePackage(localized: "snapshot size exceeds supported range")
            }
            totalSize = newTotalSize
        }
        return totalSize
    }

    private func validateManifest(_ manifest: ScanArchiveDocument) throws {
        try validateManifestHeader(format: manifest.format, formatVersion: manifest.formatVersion)
        guard manifest.snapshot.isComplete else {
            throw ScanArchiveError.manifest(localized: "snapshot is not complete")
        }
        guard manifest.snapshot.nodeCount > 0 else {
            throw ScanArchiveError.manifest(localized: "snapshot has no nodes")
        }
        guard manifest.snapshot.nodeCount <= Int(UInt32.max) else {
            throw ScanArchiveError.nodes(localized:
                "manifest expected \(manifest.snapshot.nodeCount) nodes, exceeding the supported node count"
            )
        }
        guard !manifest.snapshot.rootID.isEmpty,
              manifest.snapshot.rootID == manifest.snapshot.target.path else {
            throw ScanArchiveError.manifest(localized: "snapshot root does not match target path")
        }
        if let scanOptions = manifest.snapshot.scanOptions {
            let fingerprint = try Self.scanOptionsFingerprint(scanOptions)
            guard fingerprint == manifest.snapshot.scanOptionsFingerprint else {
                throw ScanArchiveError.integrity(localized: "scan options fingerprint mismatch")
            }
        }
        guard manifest.integrity.algorithm == "sha256" else {
            throw ScanArchiveError.integrity(localized: "unsupported integrity algorithm \(manifest.integrity.algorithm)")
        }
        if manifest.formatVersion == 5 {
            guard manifest.integrity.domain == .decodedSectionBytes else {
                throw ScanArchiveError.integrity(localized: "unsupported or missing integrity domain")
            }
            guard !manifest.integrity.nodes.isEmpty,
                  let topology = manifest.integrity.topology, !topology.isEmpty,
                  let warnings = manifest.integrity.warnings, !warnings.isEmpty,
                  let stats = manifest.integrity.stats, !stats.isEmpty else {
                throw ScanArchiveError.integrity(localized: "snapshot section checksums are incomplete")
            }
            guard manifest.sectionByteCounts?.areValid == true else {
                throw ScanArchiveError.integrity(localized: "snapshot section byte counts are incomplete or invalid")
            }
        }
    }

    private func validateManifestHeader(format: String, formatVersion: Int) throws {
        guard format == Self.formatIdentifier else {
            throw ScanArchiveError.unsupportedFormat(format)
        }
        guard (Self.oldestSupportedFormatVersion...Self.currentFormatVersion).contains(formatVersion) else {
            throw ScanArchiveError.unsupportedVersion(formatVersion)
        }
    }

    private func resolvedSectionEncodings(
        for manifest: ScanArchiveDocument
    ) throws -> ScanArchiveSectionEncodings {
        switch manifest.formatVersion {
        case 3, 4:
            return .identity
        case 5:
            guard manifest.sectionEncodings == .versionFive else {
                throw ScanArchiveError.manifest(localized:
                    "snapshot section encodings are unsupported or incomplete"
                )
            }
            return .versionFive
        default:
            throw ScanArchiveError.unsupportedVersion(manifest.formatVersion)
        }
    }

    private func validateCounts(
        manifest: ScanArchiveDocument,
        nodesByID: [String: FileNodeRecord],
        warnings: [ScanArchiveWarningV1]
    ) throws {
        try validateCounts(manifest: manifest, nodeCount: nodesByID.count, warnings: warnings)
    }

    private func validateCounts(
        manifest: ScanArchiveDocument,
        nodeCount: Int,
        warnings: [ScanArchiveWarningV1]
    ) throws {
        guard nodeCount == manifest.snapshot.nodeCount else {
            throw ScanArchiveError.nodes(localized: "manifest expected \(manifest.snapshot.nodeCount) nodes, found \(nodeCount)")
        }
        guard warnings.count == manifest.snapshot.warningCount else {
            throw ScanArchiveError.manifest(localized: "manifest expected \(manifest.snapshot.warningCount) warnings, found \(warnings.count)")
        }
    }

    private func sectionURL(named sectionName: String, in archiveURL: URL, sectionDescription: String) throws -> URL {
        guard !sectionName.isEmpty,
              !sectionName.contains("/"),
              !sectionName.contains("\\") else {
            throw ScanArchiveError.manifest(localized: "invalid \(sectionDescription) section path")
        }
        let url = archiveURL.appending(path: sectionName, directoryHint: .notDirectory)
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw ScanArchiveError.manifest(localized: "invalid \(sectionDescription) section path")
        }
        return url
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ScanArchiveError.integrity(localized: "archive section is not a regular file")
        }
        return Int64(values.fileSize ?? 0)
    }

    private func validateSectionByteCount(
        _ expectedByteCount: Int64,
        at url: URL,
        sectionDescription: String
    ) throws {
        let actualByteCount: Int64
        do {
            actualByteCount = try fileByteCount(at: url)
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw ScanArchiveError.integrity(localized:
                "\(sectionDescription) section is missing or unreadable"
            )
        }
        guard actualByteCount == expectedByteCount else {
            throw ScanArchiveError.integrity(localized:
                "\(sectionDescription) stored byte count mismatch"
            )
        }
    }

    private func createTemporaryArchiveDirectory(for destinationURL: URL) throws -> URL {
        let parentURL = destinationURL.deletingLastPathComponent()
        let tempName = ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        let tempURL = parentURL.appending(path: tempName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: false)
        return tempURL
    }

    private func installArchive(from temporaryURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            var resultingURL: NSURL?
            try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    @discardableResult
    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws -> String {
        let data = try Self.makeSectionJSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maximumByteCount: Int,
        encoding: ScanArchiveSectionEncoding = .identity,
        expectedChecksum: String? = nil,
        sectionDescription: String? = nil,
        mapError: (String) -> ScanArchiveError
    ) throws -> T {
        let data: Data
        if encoding == .identity, expectedChecksum == nil {
            data = try readData(
                from: url,
                maximumByteCount: maximumByteCount,
                mapError: mapError
            )
        } else {
            data = try readSectionData(
                from: url,
                maximumByteCount: maximumByteCount,
                encoding: encoding,
                expectedChecksum: expectedChecksum,
                sectionDescription: sectionDescription ?? "section",
                mapError: mapError
            )
        }
        return try decodeJSON(type, from: data, mapError: mapError)
    }

    private func readSectionData(
        from url: URL,
        maximumByteCount: Int,
        encoding: ScanArchiveSectionEncoding,
        expectedChecksum: String?,
        sectionDescription: String,
        mapError: (String) -> ScanArchiveError
    ) throws -> Data {
        do {
            let reader = try ScanArchiveSectionReader(url: url, encoding: encoding)
            defer { reader.close() }

            var data = Data()
            data.reserveCapacity(min(maximumByteCount, Self.sectionReadChunkByteCount))
            var hasher = SHA256()
            while true {
                let remainingByteCount = maximumByteCount - data.count
                let nextReadByteCount = min(
                    Self.sectionReadChunkByteCount,
                    remainingByteCount + 1
                )
                let chunk = try reader.read(upToCount: nextReadByteCount)
                guard !chunk.isEmpty else { break }
                data.append(chunk)
                hasher.update(data: chunk)
                guard data.count <= maximumByteCount else {
                    throw mapError(String(localized: "section exceeds supported size", comment: "Archive error for a section larger than the supported limit."))
                }
            }

            if let expectedChecksum {
                let actualChecksum = Data(hasher.finalize()).base64EncodedString()
                guard actualChecksum == expectedChecksum else {
                    throw ScanArchiveError.integrity(localized:
                        "\(sectionDescription) checksum mismatch"
                    )
                }
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw mapError(error.localizedDescription)
        }
    }

    private func readData(
        from url: URL,
        maximumByteCount: Int,
        mapError: (String) -> ScanArchiveError
    ) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var data = Data()
            data.reserveCapacity(min(maximumByteCount, Self.sectionReadChunkByteCount))
            while true {
                try Task.checkCancellation()
                let remainingByteCount = maximumByteCount - data.count
                let nextReadByteCount = min(
                    Self.sectionReadChunkByteCount,
                    remainingByteCount + 1
                )
                guard let chunk = try handle.read(upToCount: nextReadByteCount),
                      !chunk.isEmpty else {
                    return data
                }
                data.append(chunk)
                guard data.count <= maximumByteCount else {
                    throw mapError(String(localized: "section exceeds supported size", comment: "Archive error for a section larger than the supported limit."))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw mapError(error.localizedDescription)
        }
    }

    private nonisolated static func maximumTopologySize(for nodeCount: Int) -> Int {
        boundedSectionSize(
            itemCount: nodeCount,
            baseByteCount: 64 * 1_024,
            byteCountPerItem: 96,
            absoluteMaximum: maximumTopologyByteCount
        )
    }

    private nonisolated static func maximumWarningsSize(for warningCount: Int) -> Int {
        boundedSectionSize(
            itemCount: warningCount,
            baseByteCount: 64 * 1_024,
            byteCountPerItem: 64 * 1_024,
            absoluteMaximum: maximumWarningsByteCount
        )
    }

    private nonisolated static func boundedSectionSize(
        itemCount: Int,
        baseByteCount: Int,
        byteCountPerItem: Int,
        absoluteMaximum: Int
    ) -> Int {
        guard itemCount > 0 else { return min(baseByteCount, absoluteMaximum) }
        let (itemBytes, multiplicationOverflow) = itemCount.multipliedReportingOverflow(
            by: byteCountPerItem
        )
        guard !multiplicationOverflow else { return absoluteMaximum }
        let (totalBytes, additionOverflow) = baseByteCount.addingReportingOverflow(itemBytes)
        guard !additionOverflow else { return absoluteMaximum }
        return min(totalBytes, absoluteMaximum)
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        mapError: (String) -> ScanArchiveError
    ) throws -> T {
        do {
            return try Self.makeJSONDecoder().decode(type, from: data)
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw mapError(error.localizedDescription)
        }
    }

    private static func makeSectionJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func makeFingerprintJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeJSONLineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated static func scanOptionsFingerprint(_ options: ScanOptions?) throws -> String? {
        guard let options else { return nil }
        let data = try makeFingerprintJSONEncoder().encode(options)
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static func repairedStatsWarning(rootID: String) -> ScanWarning {
        ScanWarning(
            path: rootID,
            message: String(localized: "Archive stats did not match node payload. Radix repaired totals during import.", comment: "Warning shown when imported archive statistics are repaired."),
            category: .fileSystem
        )
    }
}
