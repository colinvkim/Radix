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
    var progressReporter: ScanArchiveProgressReporter?

    nonisolated init(
        pathMode: ScanArchivePathMode = .absolute,
        appVersion: String? = nil,
        progressReporter: ScanArchiveProgressReporter? = nil
    ) {
        self.pathMode = pathMode
        self.appVersion = appVersion
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

    var errorDescription: String? {
        switch self {
        case .incompleteSnapshot:
            return "Only complete scans can be exported."
        case .invalidArchivePackage(let detail):
            return "The Radix scan snapshot package is invalid: \(detail)"
        case .unsupportedFormat(let format):
            return "Unsupported Radix scan snapshot format: \(format)."
        case .unsupportedVersion(let version):
            return "Unsupported Radix scan snapshot version: \(version)."
        case .manifest(let detail):
            return "Radix could not read the scan snapshot manifest: \(detail)"
        case .nodes(let detail):
            return "Radix could not read the scan snapshot node payload: \(detail)"
        case .topology(let detail):
            return "Radix could not read the scan snapshot topology: \(detail)"
        case .integrity(let detail):
            return "Radix scan snapshot integrity check failed: \(detail)"
        case .stats(let detail):
            return "Radix could not read the scan snapshot stats: \(detail)"
        }
    }
}

nonisolated struct ScanArchiveService: ScanArchiveServicing {
    nonisolated static let fileExtension = "radixscan"
    nonisolated static let formatIdentifier = "dev.colinkim.radix.scan"
    nonisolated static let currentFormatVersion = 3

    private nonisolated static let manifestFileName = "manifest.json"
    private nonisolated static let nodesFileName = "nodes.jsonl"
    private nonisolated static let topologyFileName = "topology.json"
    private nonisolated static let warningsFileName = "warnings.json"
    private nonisolated static let statsFileName = "stats.json"
    private nonisolated static let readChunkSize = 1024 * 1024
    private nonisolated static let maxNodeLineByteCount = 1024 * 1024
    private nonisolated static let progressReportInterval = 512
    private nonisolated static let newlineData = Data([0x0A])

    init(fileManager: FileManager = .default) {
        _ = fileManager
    }

    private var fileManager: FileManager {
        .default
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
        try validateArchiveExtension(destinationURL)

        let archiveURL = try createTemporaryArchiveDirectory(for: destinationURL)
        var didInstallArchive = false
        defer {
            if !didInstallArchive {
                try? fileManager.removeItem(at: archiveURL)
            }
        }

        let archiveSections = ScanArchiveSections(
            nodes: Self.nodesFileName,
            topology: Self.topologyFileName,
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
            message: "Preparing archive"
        ))
        let nodeChecksum = try await writeNodes(
            snapshot.treeStore,
            to: nodesURL,
            progressReporter: options.progressReporter
        )
        try Task.checkCancellation()

        options.progressReporter?.report(ScanArchiveProgress(
            phase: .writingTopology,
            message: "Writing topology"
        ))
        try writeJSON(ScanArchiveTopology(snapshot.treeStore), to: topologyURL)

        options.progressReporter?.report(ScanArchiveProgress(
            phase: .writingMetadata,
            message: "Writing metadata"
        ))
        try writeJSON(snapshot.scanWarnings.map(ScanArchiveWarningV1.init), to: warningsURL)
        try writeJSON(ScanArchiveStatsV1(snapshot.aggregateStats), to: statsURL)

        let manifest = try ScanArchiveDocument(
            exportedAt: Date(),
            appVersion: options.appVersion ?? Self.currentAppVersion(),
            snapshot: snapshot,
            pathMode: options.pathMode,
            sections: archiveSections,
            nodeChecksum: nodeChecksum
        )
        try writeJSON(manifest, to: manifestURL)

        try Task.checkCancellation()
        try installArchive(from: archiveURL, to: destinationURL)
        didInstallArchive = true

        return ScanArchiveExportResult(archiveURL: destinationURL, nodeChecksum: nodeChecksum)
    }

    func previewSnapshot(from sourceURL: URL) async throws -> ScanArchivePreview {
        try Task.checkCancellation()
        let manifest = try readValidatedManifest(from: sourceURL)
        let statsURL = try sectionURL(
            named: manifest.sections.stats,
            in: sourceURL,
            sectionDescription: "stats"
        )
        let stats: ScanArchiveStatsV1 = try readJSON(ScanArchiveStatsV1.self, from: statsURL) { detail in
            ScanArchiveError.stats(detail)
        }
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
        try Task.checkCancellation()
        progressReporter?.report(ScanArchiveProgress(
            phase: .readingManifest,
            message: "Reading manifest"
        ))
        let manifest = try readValidatedManifest(from: sourceURL)

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

        let nodePayload = try await readNodes(
            from: nodesURL,
            expectedChecksum: manifest.integrity.nodes,
            expectedNodeCount: manifest.snapshot.nodeCount,
            progressReporter: progressReporter
        )

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingTopology,
            message: "Reading topology"
        ))
        let archivedTopology: ScanArchiveTopology = try readJSON(ScanArchiveTopology.self, from: topologyURL) { detail in
            ScanArchiveError.topology(detail)
        }
        let topology = try archivedTopology.resolvedTopology(orderedNodeIDs: nodePayload.orderedNodeIDs)

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingMetadata,
            message: "Reading metadata"
        ))
        let warnings: [ScanArchiveWarningV1] = try readJSON([ScanArchiveWarningV1].self, from: warningsURL) { detail in
            ScanArchiveError.manifest("warnings section failed: \(detail)")
        }
        let archivedStats: ScanArchiveStatsV1 = try readJSON(ScanArchiveStatsV1.self, from: statsURL) { detail in
            ScanArchiveError.stats(detail)
        }

        try Task.checkCancellation()
        progressReporter?.report(ScanArchiveProgress(
            phase: .rebuildingSnapshot,
            message: "Rebuilding snapshot"
        ))
        try validateCounts(manifest: manifest, nodesByID: nodePayload.nodesByID, warnings: warnings)
        let rebuiltParentIDs = try await validateTopology(
            topology,
            nodesByID: nodePayload.nodesByID,
            expectedRootID: manifest.snapshot.rootID,
            expectedTargetPath: manifest.snapshot.target.path,
            progressReporter: progressReporter
        )
        let treeStore = FileTreeStore(
            rootID: topology.rootID,
            nodesByID: nodePayload.nodesByID,
            childIDsByID: topology.childIDsByID,
            parentIDByID: rebuiltParentIDs
        )
        var importedWarnings = try warnings.map { try $0.modelWarning() }
        let computedStats = treeStore.aggregateStats
        if !archivedStats.matches(computedStats) {
            importedWarnings.append(Self.repairedStatsWarning(rootID: topology.rootID))
        }

        let snapshot = ScanSnapshot(
            id: manifest.snapshot.id,
            target: manifest.snapshot.target.modelTarget(),
            treeStore: treeStore,
            startedAt: manifest.snapshot.startedAt,
            finishedAt: manifest.snapshot.finishedAt,
            scanWarnings: importedWarnings,
            aggregateStats: computedStats,
            isComplete: manifest.snapshot.isComplete,
            scanOptions: manifest.snapshot.scanOptions,
            source: .imported(ImportedSnapshotContext(
                sourceURL: sourceURL,
                pathMode: manifest.snapshot.pathMode,
                liveActionCapability: manifest.snapshot.pathMode == .absolute ? .pathValidation : .disabled
            ))
        )

        return ScanArchiveImportResult(archiveURL: sourceURL, snapshot: snapshot, manifest: manifest)
    }

    private func readValidatedManifest(from sourceURL: URL) throws -> ScanArchiveDocument {
        try validatePackage(at: sourceURL)

        let manifestURL = sourceURL.appending(path: Self.manifestFileName, directoryHint: .notDirectory)
        let manifestData = try readData(from: manifestURL) { detail in
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
            throw ScanArchiveError.invalidArchivePackage("expected a .\(Self.fileExtension) package directory")
        }
    }

    private func validateArchiveExtension(_ url: URL) throws {
        guard url.pathExtension.lowercased() == Self.fileExtension else {
            throw ScanArchiveError.invalidArchivePackage("expected a .\(Self.fileExtension) package")
        }
    }

    private func archiveLogicalSize(at archiveURL: URL) throws -> Int64 {
        let relativePaths: [String]
        do {
            relativePaths = try fileManager.subpathsOfDirectory(atPath: archiveURL.path)
        } catch {
            throw ScanArchiveError.invalidArchivePackage(
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
                throw ScanArchiveError.invalidArchivePackage(
                    "could not calculate snapshot size: \(error.localizedDescription)"
                )
            }

            guard values.isRegularFile == true else {
                continue
            }

            let (newTotalSize, overflow) = totalSize.addingReportingOverflow(Int64(values.fileSize ?? 0))
            guard !overflow else {
                throw ScanArchiveError.invalidArchivePackage("snapshot size exceeds supported range")
            }
            totalSize = newTotalSize
        }
        return totalSize
    }

    private func validateManifest(_ manifest: ScanArchiveDocument) throws {
        try validateManifestHeader(format: manifest.format, formatVersion: manifest.formatVersion)
        guard manifest.snapshot.isComplete else {
            throw ScanArchiveError.manifest("snapshot is not complete")
        }
        guard manifest.snapshot.nodeCount > 0 else {
            throw ScanArchiveError.manifest("snapshot has no nodes")
        }
        guard !manifest.snapshot.rootID.isEmpty,
              manifest.snapshot.rootID == manifest.snapshot.target.path else {
            throw ScanArchiveError.manifest("snapshot root does not match target path")
        }
        if let scanOptions = manifest.snapshot.scanOptions {
            let fingerprint = try Self.scanOptionsFingerprint(scanOptions)
            guard fingerprint == manifest.snapshot.scanOptionsFingerprint else {
                throw ScanArchiveError.integrity("scan options fingerprint mismatch")
            }
        }
        guard manifest.integrity.algorithm == "sha256" else {
            throw ScanArchiveError.integrity("unsupported integrity algorithm \(manifest.integrity.algorithm)")
        }
    }

    private func validateManifestHeader(format: String, formatVersion: Int) throws {
        guard format == Self.formatIdentifier else {
            throw ScanArchiveError.unsupportedFormat(format)
        }
        guard formatVersion == Self.currentFormatVersion else {
            throw ScanArchiveError.unsupportedVersion(formatVersion)
        }
    }

    private func validateCounts(
        manifest: ScanArchiveDocument,
        nodesByID: [String: FileNodeRecord],
        warnings: [ScanArchiveWarningV1]
    ) throws {
        guard nodesByID.count == manifest.snapshot.nodeCount else {
            throw ScanArchiveError.nodes("manifest expected \(manifest.snapshot.nodeCount) nodes, found \(nodesByID.count)")
        }
        guard warnings.count == manifest.snapshot.warningCount else {
            throw ScanArchiveError.manifest("manifest expected \(manifest.snapshot.warningCount) warnings, found \(warnings.count)")
        }
    }

    private func validateTopology(
        _ topology: ScanArchiveResolvedTopology,
        nodesByID: [String: FileNodeRecord],
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> [String: String] {
        guard topology.rootID == expectedRootID else {
            throw ScanArchiveError.topology("root ID does not match manifest")
        }
        guard let rootNode = nodesByID[topology.rootID] else {
            throw ScanArchiveError.topology("root node is missing")
        }
        guard rootNode.url.path == expectedTargetPath else {
            throw ScanArchiveError.topology("root path does not match target path")
        }
        for parentID in topology.childIDsByID.keys where nodesByID[parentID] == nil {
            throw ScanArchiveError.topology("child map parent \(parentID) is missing from node payload")
        }

        var parentIDByID: [String: String] = [:]
        var visited: Set<String> = []
        var visiting: Set<String> = []
        var stack: [(
            nodeID: String,
            childIDs: [String],
            nextChildIndex: Int,
            seenChildIDs: Set<String>
        )] = []

        func enter(_ nodeID: String) throws {
            guard nodesByID[nodeID] != nil else {
                throw ScanArchiveError.topology("node \(nodeID) is missing from node payload")
            }
            if visiting.contains(nodeID) {
                throw ScanArchiveError.topology("cycle detected at node \(nodeID)")
            }
            if visited.contains(nodeID) {
                return
            }

            visiting.insert(nodeID)
            let childIDs = topology.childIDsByID[nodeID] ?? []
            if !childIDs.isEmpty && nodesByID[nodeID]?.isDirectory != true {
                throw ScanArchiveError.topology("non-directory node \(nodeID) has children")
            }

            stack.append((
                nodeID: nodeID,
                childIDs: childIDs,
                nextChildIndex: 0,
                seenChildIDs: []
            ))
        }

        try enter(topology.rootID)
        while !stack.isEmpty {
            var frame = stack.removeLast()

            guard frame.nextChildIndex < frame.childIDs.count else {
                visiting.remove(frame.nodeID)
                visited.insert(frame.nodeID)
                if Self.shouldReportProgress(visited.count) || visited.count == nodesByID.count {
                    try Task.checkCancellation()
                    progressReporter?.report(ScanArchiveProgress(
                        phase: .validatingTopology,
                        completedUnitCount: visited.count,
                        totalUnitCount: nodesByID.count,
                        message: "Validating topology"
                    ))
                    await Task.yield()
                }
                continue
            }

            let childID = frame.childIDs[frame.nextChildIndex]
            frame.nextChildIndex += 1
            guard frame.seenChildIDs.insert(childID).inserted else {
                throw ScanArchiveError.topology("node \(frame.nodeID) contains duplicate child \(childID)")
            }
            stack.append(frame)

            guard childID != frame.nodeID else {
                throw ScanArchiveError.topology("node \(frame.nodeID) references itself as a child")
            }
            guard nodesByID[childID] != nil else {
                throw ScanArchiveError.topology("child \(childID) is missing from node payload")
            }
            if let parentNode = nodesByID[frame.nodeID],
               let childNode = nodesByID[childID],
               !childNode.isSynthetic,
               !Self.path(childNode.url.path, isContainedIn: expectedTargetPath) {
                throw ScanArchiveError.topology("child \(childID) path is outside target \(parentNode.id)")
            }
            if let existingParentID = parentIDByID[childID], existingParentID != frame.nodeID {
                throw ScanArchiveError.topology("child \(childID) has multiple parents")
            }
            parentIDByID[childID] = frame.nodeID
            try enter(childID)
        }

        guard visited.count == nodesByID.count else {
            let missingCount = nodesByID.count - visited.count
            throw ScanArchiveError.topology("\(missingCount) node(s) are not reachable from root")
        }

        return parentIDByID
    }

    private static func path(_ childPath: String, isContainedIn parentPath: String) -> Bool {
        guard childPath != parentPath else { return true }
        if parentPath == "/" {
            return childPath.hasPrefix("/")
        }

        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : "\(parentPath)/"
        return childPath.hasPrefix(parentPrefix)
    }

    private func sectionURL(named sectionName: String, in archiveURL: URL, sectionDescription: String) throws -> URL {
        guard !sectionName.isEmpty,
              !sectionName.contains("/"),
              !sectionName.contains("\\") else {
            throw ScanArchiveError.manifest("invalid \(sectionDescription) section path")
        }
        return archiveURL.appending(path: sectionName, directoryHint: .notDirectory)
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

    private func writeNodes(
        _ treeStore: FileTreeStore,
        to url: URL,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> String {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw ScanArchiveError.nodes("could not create nodes section")
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let encoder = Self.makeJSONLineEncoder()
        let totalNodeCount = treeStore.nodeCount
        var processedNodeCount = 0

        for nodeID in treeStore.indexedNodeIDs() {
            try Task.checkCancellation()
            guard let node = treeStore.node(id: nodeID) else {
                throw ScanArchiveError.nodes("node \(nodeID) disappeared while exporting")
            }
            var lineData = try encoder.encode(ScanArchiveNode(node))
            lineData.append(Self.newlineData)
            hasher.update(data: lineData)
            try fileHandle.write(contentsOf: lineData)
            processedNodeCount += 1

            if Self.shouldReportProgress(processedNodeCount) || processedNodeCount == totalNodeCount {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .writingNodes,
                    completedUnitCount: processedNodeCount,
                    totalUnitCount: totalNodeCount,
                    message: "Writing node records"
                ))
                await Task.yield()
            }
        }

        return Data(hasher.finalize()).base64EncodedString()
    }

    private func readNodes(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> ScanArchiveNodePayload {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ScanArchiveError.nodes(error.localizedDescription)
        }
        defer { try? fileHandle.close() }

        let decoder = Self.makeJSONDecoder()
        var nodesByID: [String: FileNodeRecord] = [:]
        var orderedNodeIDs: [String] = []
        orderedNodeIDs.reserveCapacity(expectedNodeCount)
        var buffer = Data()
        var hasher = SHA256()
        var decodedNodeCount = 0

        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try fileHandle.read(upToCount: Self.readChunkSize) ?? Data()
            } catch let error as ScanArchiveError {
                throw error
            } catch {
                throw ScanArchiveError.nodes(error.localizedDescription)
            }
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            buffer.append(chunk)

            while let newlineRange = buffer.firstRange(of: Self.newlineData) {
                let lineData = Data(buffer[..<newlineRange.lowerBound])
                buffer.removeSubrange(..<newlineRange.upperBound)
                try validateNodeLineSize(lineData)
                if try decodeNodeLine(
                    lineData,
                    decoder: decoder,
                    nodesByID: &nodesByID,
                    orderedNodeIDs: &orderedNodeIDs
                ) {
                    decodedNodeCount += 1
                    try validateDecodedNodeCount(decodedNodeCount, expectedNodeCount: expectedNodeCount)
                    if Self.shouldReportProgress(decodedNodeCount) || decodedNodeCount == expectedNodeCount {
                        progressReporter?.report(ScanArchiveProgress(
                            phase: .readingNodes,
                            completedUnitCount: decodedNodeCount,
                            totalUnitCount: expectedNodeCount,
                            message: "Reading node records"
                        ))
                        await Task.yield()
                    }
                }
            }
            try validateNodeLineSize(buffer)
        }

        if !buffer.isEmpty {
            try validateNodeLineSize(buffer)
            if try decodeNodeLine(
                buffer,
                decoder: decoder,
                nodesByID: &nodesByID,
                orderedNodeIDs: &orderedNodeIDs
            ) {
                decodedNodeCount += 1
                try validateDecodedNodeCount(decodedNodeCount, expectedNodeCount: expectedNodeCount)
            }
        }

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingNodes,
            completedUnitCount: decodedNodeCount,
            totalUnitCount: expectedNodeCount,
            message: "Reading node records"
        ))

        let actualChecksum = Data(hasher.finalize()).base64EncodedString()
        guard actualChecksum == expectedChecksum else {
            throw ScanArchiveError.integrity("nodes checksum mismatch")
        }

        return ScanArchiveNodePayload(nodesByID: nodesByID, orderedNodeIDs: orderedNodeIDs)
    }

    private func validateNodeLineSize(_ lineData: Data) throws {
        guard lineData.count <= Self.maxNodeLineByteCount else {
            throw ScanArchiveError.nodes("node record is too large")
        }
    }

    private func validateDecodedNodeCount(_ decodedNodeCount: Int, expectedNodeCount: Int) throws {
        guard decodedNodeCount <= expectedNodeCount else {
            throw ScanArchiveError.nodes("node payload contains more nodes than manifest expected")
        }
    }

    private func decodeNodeLine(
        _ lineData: Data,
        decoder: JSONDecoder,
        nodesByID: inout [String: FileNodeRecord],
        orderedNodeIDs: inout [String]
    ) throws -> Bool {
        guard !lineData.isEmpty else { return false }
        let node: FileNodeRecord
        do {
            node = try decoder.decode(ScanArchiveNode.self, from: lineData).modelNode()
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw ScanArchiveError.nodes("invalid JSONL node: \(error.localizedDescription)")
        }
        guard nodesByID[node.id] == nil else {
            throw ScanArchiveError.nodes("duplicate node ID \(node.id)")
        }
        nodesByID[node.id] = node
        orderedNodeIDs.append(node.id)
        return true
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.makeSectionJSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        mapError: (String) -> ScanArchiveError
    ) throws -> T {
        let data = try readData(from: url, mapError: mapError)
        return try decodeJSON(type, from: data, mapError: mapError)
    }

    private func readData(
        from url: URL,
        mapError: (String) -> ScanArchiveError
    ) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw mapError(error.localizedDescription)
        }
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

    private static func makeJSONLineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func shouldReportProgress(_ completedUnitCount: Int) -> Bool {
        completedUnitCount == 0 || completedUnitCount % progressReportInterval == 0
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
            message: "Archive stats did not match node payload. Radix repaired totals during import.",
            category: .fileSystem
        )
    }
}

private nonisolated struct ScanArchiveNodePayload: Sendable {
    let nodesByID: [String: FileNodeRecord]
    let orderedNodeIDs: [String]
}

fileprivate nonisolated struct ScanArchiveResolvedTopology: Sendable {
    let rootID: String
    let childIDsByID: [String: [String]]
}

private nonisolated struct ScanArchiveHeader: Decodable, Sendable {
    let format: String
    let formatVersion: Int
}

nonisolated struct ScanArchiveDocument: Codable, Sendable {
    let format: String
    let formatVersion: Int
    let createdBy: ScanArchiveCreatedBy
    let exportedAt: Date
    let snapshot: ScanArchiveSnapshotSummary
    let sections: ScanArchiveSections
    let integrity: ScanArchiveIntegrity

    init(
        exportedAt: Date,
        appVersion: String,
        snapshot: ScanSnapshot,
        pathMode: ScanArchivePathMode,
        sections: ScanArchiveSections,
        nodeChecksum: String,
        formatVersion: Int = ScanArchiveService.currentFormatVersion,
        swiftSchema: String = "ScanArchiveV3"
    ) throws {
        self.format = ScanArchiveService.formatIdentifier
        self.formatVersion = formatVersion
        self.createdBy = ScanArchiveCreatedBy(appVersion: appVersion, swiftSchema: swiftSchema)
        self.exportedAt = exportedAt
        self.snapshot = try ScanArchiveSnapshotSummary(snapshot, pathMode: pathMode)
        self.sections = sections
        self.integrity = ScanArchiveIntegrity(nodes: nodeChecksum)
    }
}

nonisolated struct ScanArchiveCreatedBy: Codable, Sendable {
    let app: String
    let appVersion: String
    let swiftSchema: String

    init(appVersion: String, swiftSchema: String = "ScanArchiveV3") {
        self.app = "Radix"
        self.appVersion = appVersion
        self.swiftSchema = swiftSchema
    }
}

nonisolated struct ScanArchiveSnapshotSummary: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date?
    let isComplete: Bool
    let target: ScanArchiveTargetV1
    let rootID: String
    let nodeCount: Int
    let warningCount: Int
    let pathMode: ScanArchivePathMode
    let scanOptions: ScanOptions?
    let scanOptionsFingerprint: String?

    init(_ snapshot: ScanSnapshot, pathMode: ScanArchivePathMode) throws {
        self.id = snapshot.id
        self.startedAt = snapshot.startedAt
        self.finishedAt = snapshot.finishedAt
        self.isComplete = snapshot.isComplete
        self.target = ScanArchiveTargetV1(snapshot.target)
        self.rootID = snapshot.treeStore.rootID
        self.nodeCount = snapshot.treeStore.nodeCount
        self.warningCount = snapshot.scanWarnings.count
        self.pathMode = pathMode
        self.scanOptions = snapshot.scanOptions
        self.scanOptionsFingerprint = try ScanArchiveService.scanOptionsFingerprint(snapshot.scanOptions)
    }
}

nonisolated struct ScanArchiveTargetV1: Codable, Sendable {
    let path: String
    let displayName: String
    let kind: ScanTargetKind

    init(_ target: ScanTarget) {
        self.path = target.url.path
        self.displayName = target.displayName
        self.kind = target.kind
    }

    func modelTarget() -> ScanTarget {
        ScanTarget(
            id: path,
            url: URL(filePath: path, directoryHint: .isDirectory),
            displayName: displayName,
            kind: kind
        )
    }
}

nonisolated struct ScanArchiveSections: Codable, Sendable {
    let nodes: String
    let topology: String
    let warnings: String
    let stats: String
}

nonisolated struct ScanArchiveIntegrity: Codable, Sendable {
    let algorithm: String
    let nodes: String

    init(nodes: String) {
        self.algorithm = "sha256"
        self.nodes = nodes
    }
}

nonisolated struct ScanArchiveNode: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id = "i"
        case path = "p"
        case name = "n"
        case isDirectory = "d"
        case isSymbolicLink = "s"
        case allocatedSize = "a"
        case unduplicatedAllocatedSize = "u"
        case logicalSize = "l"
        case descendantFileCount = "c"
        case lastModified = "m"
        case fileIdentity = "f"
        case linkCount = "k"
        case isPackage = "g"
        case isAccessible = "r"
        case isSelfAccessible = "q"
        case isSynthetic = "y"
        case isAutoSummarized = "z"
    }

    let id: String
    let path: String?
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let unduplicatedAllocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let lastModified: Date?
    let fileIdentity: ScanArchiveFileIdentity?
    let linkCount: UInt64
    let isPackage: Bool
    let isAccessible: Bool
    let isSelfAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    init(_ node: FileNodeRecord) {
        self.id = node.id
        self.path = node.isSynthetic || node.url.path != node.id ? node.url.path : nil
        self.name = node.name
        self.isDirectory = node.isDirectory
        self.isSymbolicLink = node.isSymbolicLink
        self.allocatedSize = node.allocatedSize
        self.unduplicatedAllocatedSize = node.unduplicatedAllocatedSize
        self.logicalSize = node.logicalSize
        self.descendantFileCount = node.descendantFileCount
        self.lastModified = node.lastModified
        self.fileIdentity = node.fileIdentity.map(ScanArchiveFileIdentity.init)
        self.linkCount = node.linkCount
        self.isPackage = node.isPackage
        self.isAccessible = node.isAccessible
        self.isSelfAccessible = node.isSelfAccessible
        self.isSynthetic = node.isSynthetic
        self.isAutoSummarized = node.isAutoSummarized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.name = try container.decode(String.self, forKey: .name)
        self.isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        self.isSymbolicLink = try container.decodeIfPresent(Bool.self, forKey: .isSymbolicLink) ?? false
        self.allocatedSize = try container.decode(Int64.self, forKey: .allocatedSize)
        self.unduplicatedAllocatedSize = try container.decodeIfPresent(
            Int64.self,
            forKey: .unduplicatedAllocatedSize
        ) ?? allocatedSize
        self.logicalSize = try container.decodeIfPresent(Int64.self, forKey: .logicalSize) ?? allocatedSize
        self.descendantFileCount = try container.decodeIfPresent(Int.self, forKey: .descendantFileCount) ??
            (isDirectory ? 0 : 1)
        if let lastModifiedSeconds = try container.decodeIfPresent(Double.self, forKey: .lastModified) {
            self.lastModified = Date(timeIntervalSince1970: lastModifiedSeconds)
        } else {
            self.lastModified = nil
        }
        self.fileIdentity = try container.decodeIfPresent(ScanArchiveFileIdentity.self, forKey: .fileIdentity)
        self.linkCount = try container.decodeIfPresent(UInt64.self, forKey: .linkCount) ?? 1
        self.isPackage = try container.decodeIfPresent(Bool.self, forKey: .isPackage) ?? false
        self.isAccessible = try container.decodeIfPresent(Bool.self, forKey: .isAccessible) ?? true
        self.isSelfAccessible = try container.decodeIfPresent(Bool.self, forKey: .isSelfAccessible) ?? isAccessible
        self.isSynthetic = try container.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
        self.isAutoSummarized = try container.decodeIfPresent(Bool.self, forKey: .isAutoSummarized) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if let path {
            try container.encode(path, forKey: .path)
        }
        if isDirectory {
            try container.encode(true, forKey: .isDirectory)
        }
        if isSymbolicLink {
            try container.encode(true, forKey: .isSymbolicLink)
        }
        try container.encode(allocatedSize, forKey: .allocatedSize)
        if unduplicatedAllocatedSize != allocatedSize {
            try container.encode(unduplicatedAllocatedSize, forKey: .unduplicatedAllocatedSize)
        }
        if logicalSize != allocatedSize {
            try container.encode(logicalSize, forKey: .logicalSize)
        }
        let defaultDescendantFileCount = isDirectory ? 0 : 1
        if descendantFileCount != defaultDescendantFileCount {
            try container.encode(descendantFileCount, forKey: .descendantFileCount)
        }
        if let lastModified {
            try container.encode(lastModified.timeIntervalSince1970, forKey: .lastModified)
        }
        if let fileIdentity {
            try container.encode(fileIdentity, forKey: .fileIdentity)
        }
        if linkCount != 1 {
            try container.encode(linkCount, forKey: .linkCount)
        }
        if isPackage {
            try container.encode(true, forKey: .isPackage)
        }
        if !isAccessible {
            try container.encode(false, forKey: .isAccessible)
        }
        if isSelfAccessible != isAccessible {
            try container.encode(isSelfAccessible, forKey: .isSelfAccessible)
        }
        if isSynthetic {
            try container.encode(true, forKey: .isSynthetic)
        }
        if isAutoSummarized {
            try container.encode(true, forKey: .isAutoSummarized)
        }
    }

    func modelNode() throws -> FileNodeRecord {
        guard !id.isEmpty else {
            throw ScanArchiveError.nodes("node has empty ID")
        }
        let resolvedPath = path ?? id
        guard !resolvedPath.isEmpty else {
            throw ScanArchiveError.nodes("node \(id) has empty path")
        }
        guard allocatedSize >= 0, unduplicatedAllocatedSize >= 0, logicalSize >= 0 else {
            throw ScanArchiveError.nodes("node \(id) has negative size")
        }
        guard descendantFileCount >= 0 else {
            throw ScanArchiveError.nodes("node \(id) has negative descendant count")
        }

        let nodeURL = URL(filePath: resolvedPath, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        guard isSynthetic || id == nodeURL.path else {
            throw ScanArchiveError.nodes("node \(id) path does not match ID")
        }

        return FileNodeRecord(
            id: id,
            url: nodeURL,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: try fileIdentity?.modelIdentity(),
            linkCount: max(linkCount, 1),
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }
}

nonisolated struct ScanArchiveFileIdentity: Codable, Sendable {
    nonisolated enum Kind: Int, Codable, Sendable {
        case resourceIdentifier = 0
        case fileSystem = 1
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "k"
        case resourceIdentifier = "r"
        case device = "d"
        case inode = "i"
    }

    let kind: Kind
    let resourceIdentifier: String?
    let device: UInt64?
    let inode: UInt64?

    init(_ identity: FileIdentity) {
        switch identity {
        case .resourceIdentifier(let data):
            self.kind = .resourceIdentifier
            self.resourceIdentifier = data.base64EncodedString()
            self.device = nil
            self.inode = nil
        case .fileSystem(let device, let inode):
            self.kind = .fileSystem
            self.resourceIdentifier = nil
            self.device = device
            self.inode = inode
        }
    }

    func modelIdentity() throws -> FileIdentity {
        switch kind {
        case .resourceIdentifier:
            guard let resourceIdentifier,
                  let data = Data(base64Encoded: resourceIdentifier) else {
                throw ScanArchiveError.nodes("file identity has invalid resource identifier")
            }
            return FileIdentity(resourceIdentifier: data)
        case .fileSystem:
            guard let device, let inode else {
                throw ScanArchiveError.nodes("file identity has incomplete file system identity")
            }
            return FileIdentity(device: device, inode: inode)
        }
    }
}

nonisolated struct ScanArchiveTopology: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case rootOrdinal = "r"
        case childOrdinalsByOrdinal = "c"
    }

    let rootOrdinal: Int
    let childOrdinalsByOrdinal: [String: [Int]]

    init(rootOrdinal: Int, childOrdinalsByOrdinal: [String: [Int]]) {
        self.rootOrdinal = rootOrdinal
        self.childOrdinalsByOrdinal = childOrdinalsByOrdinal
    }

    init(_ treeStore: FileTreeStore) throws {
        let orderedNodeIDs = treeStore.indexedNodeIDs()
        var ordinalByID: [String: Int] = [:]
        ordinalByID.reserveCapacity(orderedNodeIDs.count)

        for (ordinal, nodeID) in orderedNodeIDs.enumerated() {
            ordinalByID[nodeID] = ordinal
        }

        guard let rootOrdinal = ordinalByID[treeStore.rootID] else {
            throw ScanArchiveError.topology("root node is missing from node order")
        }

        var childOrdinalsByOrdinal: [String: [Int]] = [:]
        childOrdinalsByOrdinal.reserveCapacity(treeStore.childIDsByID.count)

        for parentID in orderedNodeIDs {
            guard let childIDs = treeStore.childIDsByID[parentID],
                  !childIDs.isEmpty else {
                continue
            }
            guard let parentOrdinal = ordinalByID[parentID] else {
                throw ScanArchiveError.topology("parent \(parentID) is missing from node order")
            }

            var childOrdinals: [Int] = []
            childOrdinals.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let childOrdinal = ordinalByID[childID] else {
                    throw ScanArchiveError.topology("child \(childID) is missing from node order")
                }
                childOrdinals.append(childOrdinal)
            }
            childOrdinalsByOrdinal[String(parentOrdinal)] = childOrdinals
        }

        self.rootOrdinal = rootOrdinal
        self.childOrdinalsByOrdinal = childOrdinalsByOrdinal
    }

    fileprivate func resolvedTopology(orderedNodeIDs: [String]) throws -> ScanArchiveResolvedTopology {
        guard orderedNodeIDs.indices.contains(rootOrdinal) else {
            throw ScanArchiveError.topology("root ordinal \(rootOrdinal) is out of range")
        }

        var childIDsByID: [String: [String]] = [:]
        childIDsByID.reserveCapacity(childOrdinalsByOrdinal.count)

        for (parentOrdinalKey, childOrdinals) in childOrdinalsByOrdinal {
            guard let parentOrdinal = Int(parentOrdinalKey),
                  String(parentOrdinal) == parentOrdinalKey else {
                throw ScanArchiveError.topology("parent ordinal \(parentOrdinalKey) is invalid")
            }
            guard orderedNodeIDs.indices.contains(parentOrdinal) else {
                throw ScanArchiveError.topology("parent ordinal \(parentOrdinal) is out of range")
            }

            var childIDs: [String] = []
            childIDs.reserveCapacity(childOrdinals.count)
            for childOrdinal in childOrdinals {
                guard orderedNodeIDs.indices.contains(childOrdinal) else {
                    throw ScanArchiveError.topology("child ordinal \(childOrdinal) is out of range")
                }
                childIDs.append(orderedNodeIDs[childOrdinal])
            }
            childIDsByID[orderedNodeIDs[parentOrdinal]] = childIDs
        }

        return ScanArchiveResolvedTopology(
            rootID: orderedNodeIDs[rootOrdinal],
            childIDsByID: childIDsByID
        )
    }
}

nonisolated struct ScanArchiveWarningV1: Codable, Sendable {
    let path: String
    let message: String
    let category: String

    init(_ warning: ScanWarning) {
        self.path = warning.path
        self.message = warning.message
        self.category = warning.category.rawValue
    }

    func modelWarning() throws -> ScanWarning {
        guard let category = ScanWarningCategory(rawValue: category) else {
            throw ScanArchiveError.manifest("unknown warning category \(category)")
        }
        return ScanWarning(path: path, message: message, category: category)
    }
}

nonisolated struct ScanArchiveStatsV1: Codable, Sendable {
    let totalAllocatedSize: Int64
    let totalLogicalSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let accessibleItemCount: Int
    let inaccessibleItemCount: Int

    init(_ stats: ScanAggregateStats) {
        self.totalAllocatedSize = stats.totalAllocatedSize
        self.totalLogicalSize = stats.totalLogicalSize
        self.fileCount = stats.fileCount
        self.directoryCount = stats.directoryCount
        self.accessibleItemCount = stats.accessibleItemCount
        self.inaccessibleItemCount = stats.inaccessibleItemCount
    }

    func matches(_ stats: ScanAggregateStats) -> Bool {
        totalAllocatedSize == stats.totalAllocatedSize &&
            totalLogicalSize == stats.totalLogicalSize &&
            fileCount == stats.fileCount &&
            directoryCount == stats.directoryCount &&
            accessibleItemCount == stats.accessibleItemCount &&
            inaccessibleItemCount == stats.inaccessibleItemCount
    }
}
