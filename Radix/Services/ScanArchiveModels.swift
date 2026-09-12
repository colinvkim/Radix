//
//  ScanArchiveModels.swift
//  Radix
//

import Foundation

nonisolated struct ScanArchiveResolvedTopology: Sendable {
    let rootID: String
    let childIDsByID: [String: [String]]
}

nonisolated struct ScanArchiveHeader: Decodable, Sendable {
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
    let sectionEncodings: ScanArchiveSectionEncodings?
    let sectionByteCounts: ScanArchiveSectionByteCounts?
    let integrity: ScanArchiveIntegrity

    init(
        exportedAt: Date,
        appVersion: String,
        snapshot: ScanSnapshot,
        pathMode: ScanArchivePathMode,
        sections: ScanArchiveSections,
        nodeChecksum: String,
        topologyChecksum: String? = nil,
        warningsChecksum: String? = nil,
        statsChecksum: String? = nil,
        formatVersion: Int,
        swiftSchema: String? = nil,
        sectionEncodings: ScanArchiveSectionEncodings? = nil,
        sectionByteCounts: ScanArchiveSectionByteCounts? = nil
    ) throws {
        self.format = ScanArchiveService.formatIdentifier
        self.formatVersion = formatVersion
        self.createdBy = ScanArchiveCreatedBy(
            appVersion: appVersion,
            swiftSchema: swiftSchema ?? "ScanArchiveV\(formatVersion)"
        )
        self.exportedAt = exportedAt
        self.snapshot = try ScanArchiveSnapshotSummary(snapshot, pathMode: pathMode)
        self.sections = sections
        self.sectionEncodings = sectionEncodings
        self.sectionByteCounts = sectionByteCounts
        self.integrity = ScanArchiveIntegrity(
            nodes: nodeChecksum,
            topology: topologyChecksum,
            warnings: warningsChecksum,
            stats: statsChecksum,
            domain: formatVersion == 5 ? .decodedSectionBytes : nil
        )
    }
}

nonisolated struct ScanArchiveCreatedBy: Codable, Sendable {
    let app: String
    let appVersion: String
    let swiftSchema: String

    init(appVersion: String, swiftSchema: String) {
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
    let volumeCapacity: VolumeCapacitySnapshot?

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
        self.volumeCapacity = snapshot.volumeCapacity
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

nonisolated enum ScanArchiveSectionEncoding: String, Codable, Sendable {
    case identity
    case lzfse
}

nonisolated struct ScanArchiveSectionEncodings: Codable, Equatable, Sendable {
    let nodes: ScanArchiveSectionEncoding
    let topology: ScanArchiveSectionEncoding
    let warnings: ScanArchiveSectionEncoding
    let stats: ScanArchiveSectionEncoding

    static let identity = ScanArchiveSectionEncodings(
        nodes: .identity,
        topology: .identity,
        warnings: .identity,
        stats: .identity
    )

    static let versionFive = ScanArchiveSectionEncodings(
        nodes: .lzfse,
        topology: .lzfse,
        warnings: .identity,
        stats: .identity
    )
}

nonisolated struct ScanArchiveSectionByteCounts: Codable, Equatable, Sendable {
    let nodes: Int64
    let topology: Int64
    let warnings: Int64
    let stats: Int64

    var areValid: Bool {
        nodes >= 0 && topology >= 0 && warnings >= 0 && stats >= 0
    }
}

nonisolated enum ScanArchiveIntegrityDomain: String, Codable, Sendable {
    case decodedSectionBytes = "decoded-section-bytes"
}

nonisolated struct ScanArchiveIntegrity: Codable, Sendable {
    let algorithm: String
    let nodes: String
    let topology: String?
    let warnings: String?
    let stats: String?
    let domain: ScanArchiveIntegrityDomain?

    init(
        nodes: String,
        topology: String? = nil,
        warnings: String? = nil,
        stats: String? = nil,
        domain: ScanArchiveIntegrityDomain? = nil
    ) {
        self.algorithm = "sha256"
        self.nodes = nodes
        self.topology = topology
        self.warnings = warnings
        self.stats = stats
        self.domain = domain
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
        case dataAllocatedSize = "v"
        case logicalSize = "l"
        case descendantFileCount = "c"
        case lastModified = "m"
        case fileIdentity = "f"
        case linkCount = "k"
        case cloneIdentity = "o"
        case mayShareDataBlocks = "h"
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
    let dataAllocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let lastModified: Date?
    let fileIdentity: ScanArchiveFileIdentity?
    let linkCount: UInt64
    let cloneIdentity: ScanArchiveCloneIdentity?
    let mayShareDataBlocks: Bool
    let isPackage: Bool
    let isAccessible: Bool
    let isSelfAccessible: Bool
    let isSynthetic: Bool
    let isAutoSummarized: Bool

    init(
        _ node: FileNodeRecord,
        includesLocation: Bool = true,
        includesName: Bool = true
    ) {
        self.id = includesLocation ? node.id : ""
        self.path = includesLocation && (node.isSynthetic || node.url.path != node.id)
            ? node.url.path
            : nil
        self.name = includesName ? node.name : ""
        self.isDirectory = node.isDirectory
        self.isSymbolicLink = node.isSymbolicLink
        self.allocatedSize = node.allocatedSize
        self.unduplicatedAllocatedSize = node.unduplicatedAllocatedSize
        self.dataAllocatedSize = node.dataAllocatedSize
        self.logicalSize = node.logicalSize
        self.descendantFileCount = node.descendantFileCount
        self.lastModified = node.lastModified
        self.fileIdentity = node.fileIdentity.map(ScanArchiveFileIdentity.init)
        self.linkCount = node.linkCount
        self.cloneIdentity = node.cloneIdentity.map(ScanArchiveCloneIdentity.init)
        self.mayShareDataBlocks = node.mayShareDataBlocks
        self.isPackage = node.isPackage
        self.isAccessible = node.isAccessible
        self.isSelfAccessible = node.isSelfAccessible
        self.isSynthetic = node.isSynthetic
        self.isAutoSummarized = node.isAutoSummarized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        self.isSymbolicLink = try container.decodeIfPresent(Bool.self, forKey: .isSymbolicLink) ?? false
        self.allocatedSize = try container.decode(Int64.self, forKey: .allocatedSize)
        self.unduplicatedAllocatedSize = try container.decodeIfPresent(
            Int64.self,
            forKey: .unduplicatedAllocatedSize
        ) ?? allocatedSize
        self.dataAllocatedSize = try container.decodeIfPresent(Int64.self, forKey: .dataAllocatedSize)
            ?? unduplicatedAllocatedSize
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
        self.cloneIdentity = try container.decodeIfPresent(ScanArchiveCloneIdentity.self, forKey: .cloneIdentity)
        self.mayShareDataBlocks = try container.decodeIfPresent(Bool.self, forKey: .mayShareDataBlocks) ?? false
        self.isPackage = try container.decodeIfPresent(Bool.self, forKey: .isPackage) ?? false
        self.isAccessible = try container.decodeIfPresent(Bool.self, forKey: .isAccessible) ?? true
        self.isSelfAccessible = try container.decodeIfPresent(Bool.self, forKey: .isSelfAccessible) ?? isAccessible
        self.isSynthetic = try container.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
        self.isAutoSummarized = try container.decodeIfPresent(Bool.self, forKey: .isAutoSummarized) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !id.isEmpty {
            try container.encode(id, forKey: .id)
        }
        if !name.isEmpty {
            try container.encode(name, forKey: .name)
        }
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
        if dataAllocatedSize != unduplicatedAllocatedSize {
            try container.encode(dataAllocatedSize, forKey: .dataAllocatedSize)
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
        if let cloneIdentity {
            try container.encode(cloneIdentity, forKey: .cloneIdentity)
        }
        if mayShareDataBlocks {
            try container.encode(true, forKey: .mayShareDataBlocks)
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

    func modelNode(
        resolvedID: String? = nil,
        resolvedPath: String? = nil,
        resolvedName: String? = nil,
        locationAlreadyValidated: Bool = false
    ) throws -> FileNodeRecord {
        let modelID = resolvedID ?? id
        guard !modelID.isEmpty else {
            throw ScanArchiveError.nodes(localized: "node has empty ID")
        }
        let modelPath = resolvedPath ?? path ?? modelID
        guard !modelPath.isEmpty else {
            throw ScanArchiveError.nodes(localized: "node \(modelID) has empty path")
        }
        guard allocatedSize >= 0,
              unduplicatedAllocatedSize >= 0,
              dataAllocatedSize >= 0,
              dataAllocatedSize <= unduplicatedAllocatedSize,
              logicalSize >= 0 else {
            throw ScanArchiveError.nodes(localized: "node \(modelID) has negative size")
        }
        guard descendantFileCount >= 0 else {
            throw ScanArchiveError.nodes(localized: "node \(modelID) has negative descendant count")
        }

        let nodeURL = URL(filePath: modelPath, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        guard locationAlreadyValidated || isSynthetic || modelID == nodeURL.path else {
            throw ScanArchiveError.nodes(localized: "node \(modelID) path does not match ID")
        }

        return FileNodeRecord(
            id: modelID,
            url: nodeURL,
            name: resolvedName ?? name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            dataAllocatedSize: dataAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: try fileIdentity?.modelIdentity(),
            linkCount: max(linkCount, 1),
            cloneIdentity: cloneIdentity?.modelIdentity(),
            mayShareDataBlocks: mayShareDataBlocks,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized
        )
    }
}

nonisolated struct ScanArchiveCloneIdentity: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case device = "d"
        case cloneID = "c"
    }

    let device: UInt64
    let cloneID: UInt64

    init(_ identity: CloneIdentity) {
        self.device = identity.device
        self.cloneID = identity.cloneID
    }

    func modelIdentity() -> CloneIdentity {
        CloneIdentity(device: device, cloneID: cloneID)
    }
}

/// Version-4 node envelope. Ordinary nodes store one path component and their
/// parent's ordinal instead of repeating their absolute ID on every JSONL line.
/// Explicit locations are reserved for synthetic and otherwise nonstandard nodes.
nonisolated struct ScanArchiveCompactNode: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case relativePath = "x"
        case explicitID = "i"
        case explicitPath = "p"
        case payload = "v"
    }

    let relativePath: String?
    let explicitID: String?
    let explicitPath: String?
    let payload: ScanArchiveNode

    init(
        _ node: FileNodeRecord,
        parent: FileNodeRecord?
    ) {
        guard let parent else {
            self.relativePath = nil
            self.explicitID = nil
            self.explicitPath = nil
            self.payload = ScanArchiveNode(node, includesLocation: false)
            return
        }

        let component = node.url.lastPathComponent
        let derivedPath = parent.url.appending(
            path: component,
            directoryHint: node.isDirectory ? .isDirectory : .notDirectory
        ).path
        if !node.isSynthetic, node.id == node.url.path, derivedPath == node.id {
            self.relativePath = component
            self.explicitID = nil
            self.explicitPath = nil
            self.payload = ScanArchiveNode(
                node,
                includesLocation: false,
                includesName: node.name != component
            )
        } else {
            self.relativePath = nil
            self.explicitID = node.id
            self.explicitPath = node.url.path
            self.payload = ScanArchiveNode(node, includesLocation: false)
        }
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
        case volumeToken = "v"
    }

    let kind: Kind
    let resourceIdentifier: String?
    let device: UInt64?
    let inode: UInt64?
    let volumeToken: UInt64?

    init(_ identity: FileIdentity) {
        switch identity {
        case .resourceIdentifier(let data):
            self.kind = .resourceIdentifier
            self.resourceIdentifier = data.base64EncodedString()
            self.device = nil
            self.inode = nil
            self.volumeToken = nil
        case .fileSystem(let device, let inode, let volumeToken):
            self.kind = .fileSystem
            self.resourceIdentifier = nil
            self.device = device
            self.inode = inode
            self.volumeToken = volumeToken
        }
    }

    func modelIdentity() throws -> FileIdentity {
        switch kind {
        case .resourceIdentifier:
            guard let resourceIdentifier,
                  let data = Data(base64Encoded: resourceIdentifier) else {
                throw ScanArchiveError.nodes(localized: "file identity has invalid resource identifier")
            }
            return FileIdentity(resourceIdentifier: data)
        case .fileSystem:
            guard let device, let inode else {
                throw ScanArchiveError.nodes(localized: "file identity has incomplete file system identity")
            }
            return FileIdentity(device: device, inode: inode, volumeToken: volumeToken)
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
            throw ScanArchiveError.topology(localized: "root node is missing from node order")
        }

        var childOrdinalsByOrdinal: [String: [Int]] = [:]
        childOrdinalsByOrdinal.reserveCapacity(orderedNodeIDs.count)

        for parentID in orderedNodeIDs {
            let childIDs = treeStore.childIDs(of: parentID)
            guard !childIDs.isEmpty else {
                continue
            }
            guard let parentOrdinal = ordinalByID[parentID] else {
                throw ScanArchiveError.topology(localized: "parent \(parentID) is missing from node order")
            }

            var childOrdinals: [Int] = []
            childOrdinals.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let childOrdinal = ordinalByID[childID] else {
                    throw ScanArchiveError.topology(localized: "child \(childID) is missing from node order")
                }
                childOrdinals.append(childOrdinal)
            }
            childOrdinalsByOrdinal[String(parentOrdinal)] = childOrdinals
        }

        self.rootOrdinal = rootOrdinal
        self.childOrdinalsByOrdinal = childOrdinalsByOrdinal
    }

    func resolvedTopology(orderedNodeIDs: [String]) throws -> ScanArchiveResolvedTopology {
        guard orderedNodeIDs.indices.contains(rootOrdinal) else {
            throw ScanArchiveError.topology(localized: "root ordinal \(rootOrdinal) is out of range")
        }

        var childIDsByID: [String: [String]] = [:]
        childIDsByID.reserveCapacity(childOrdinalsByOrdinal.count)

        for (parentOrdinalKey, childOrdinals) in childOrdinalsByOrdinal {
            guard let parentOrdinal = Int(parentOrdinalKey),
                  String(parentOrdinal) == parentOrdinalKey else {
                throw ScanArchiveError.topology(localized: "parent ordinal \(parentOrdinalKey) is invalid")
            }
            guard orderedNodeIDs.indices.contains(parentOrdinal) else {
                throw ScanArchiveError.topology(localized: "parent ordinal \(parentOrdinal) is out of range")
            }

            var childIDs: [String] = []
            childIDs.reserveCapacity(childOrdinals.count)
            for childOrdinal in childOrdinals {
                guard orderedNodeIDs.indices.contains(childOrdinal) else {
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is out of range")
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
            throw ScanArchiveError.manifest(localized: "unknown warning category \(category)")
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

    func validate() throws {
        guard totalAllocatedSize >= 0, totalLogicalSize >= 0 else {
            throw ScanArchiveError.stats(localized: "snapshot totals cannot be negative")
        }
        guard fileCount >= 0,
              directoryCount >= 0,
              accessibleItemCount >= 0,
              inaccessibleItemCount >= 0 else {
            throw ScanArchiveError.stats(localized: "snapshot item counts cannot be negative")
        }
    }
}
