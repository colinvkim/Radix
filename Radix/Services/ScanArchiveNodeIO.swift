//
//  ScanArchiveNodeIO.swift
//  Radix
//

import CryptoKit
import Foundation

private nonisolated enum ScanArchiveNodeIOConstants {
    static let readChunkSize = 1024 * 1024
    static let maxNodeLineByteCount = 1024 * 1024
    static let maximumInitialRecordCapacity = 65_536
    static let maximumConcurrentDecodes = 8
    static let newlineData = Data([0x0A])
}

nonisolated struct ScanArchiveNodePayload: Sendable {
    let nodesByID: [String: FileNodeRecord]
    let orderedNodeIDs: [String]
}

nonisolated private struct ScanArchiveNodeLocation {
    let id: String
    let path: String
}

nonisolated private struct ScanArchiveCompactTopology {
    let rootOrdinal: Int
    let parentRawIndices: [UInt32]
    let childSpans: [FileTreeChildSpan]
    let childIndices: [FileTreeNodeIndex]
    let orderedNodeIndices: [FileTreeNodeIndex]
    let parentsPrecedeChildren: Bool
}

nonisolated private enum ScanArchiveNodeOrdinalLookup {
    case dense([Int])
    case sparse([FileTreeNodeIndex: Int])

    init(
        orderedNodeIndices: [FileTreeNodeIndex],
        backingNodeCapacity: Int,
        cancellationCheck: () throws -> Void
    ) throws {
        if backingNodeCapacity <= max(orderedNodeIndices.count * 4, 4_096) {
            var ordinals = Array(repeating: -1, count: backingNodeCapacity)
            for (ordinal, nodeIndex) in orderedNodeIndices.enumerated() {
                if ordinal.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                ordinals[Int(nodeIndex.rawValue)] = ordinal
            }
            self = .dense(ordinals)
        } else {
            var ordinals: [FileTreeNodeIndex: Int] = [:]
            ordinals.reserveCapacity(orderedNodeIndices.count)
            for (ordinal, nodeIndex) in orderedNodeIndices.enumerated() {
                if ordinal.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                ordinals[nodeIndex] = ordinal
            }
            self = .sparse(ordinals)
        }
    }

    subscript(nodeIndex: FileTreeNodeIndex) -> Int? {
        switch self {
        case .dense(let ordinals):
            let offset = Int(nodeIndex.rawValue)
            guard ordinals.indices.contains(offset), ordinals[offset] >= 0 else { return nil }
            return ordinals[offset]
        case .sparse(let ordinals):
            return ordinals[nodeIndex]
        }
    }
}

nonisolated private struct ScanArchiveStreamingJSONWriter {
    private static let flushByteCount = 1024 * 1024

    private var sectionWriter: ScanArchiveSectionWriter
    private var buffer = Data()

    init(
        fileHandle: FileHandle,
        encoding: ScanArchiveSectionEncoding
    ) throws {
        self.sectionWriter = try ScanArchiveSectionWriter(
            fileHandle: fileHandle,
            encoding: encoding
        )
        buffer.reserveCapacity(Self.flushByteCount)
    }

    mutating func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.flushByteCount {
            try flush()
        }
    }

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= Self.flushByteCount {
            try flush()
        }
    }

    mutating func finish() throws -> String {
        try flush()
        return try sectionWriter.finish()
    }

    private mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try sectionWriter.append(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

extension ScanArchiveService {
    func writeNodes(
        _ treeStore: FileTreeStore,
        to url: URL,
        encoding: ScanArchiveSectionEncoding,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ScanArchiveError.nodes(localized: "could not create nodes section")
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        let encoder = Self.makeJSONLineEncoder()
        let totalNodeCount = treeStore.nodeCount
        var processedNodeCount = 0
        let orderedNodeIndices = treeStore.indexedNodeIndices()
        var writer = try ScanArchiveStreamingJSONWriter(
            fileHandle: fileHandle,
            encoding: encoding
        )

        for nodeIndex in orderedNodeIndices {
            try Task.checkCancellation()
            guard let node = treeStore.node(at: nodeIndex) else {
                throw ScanArchiveError.nodes(localized: "node index disappeared while exporting")
            }
            let parent = treeStore.parentIndex(of: nodeIndex).flatMap { treeStore.node(at: $0) }
            var lineData = try encoder.encode(
                ScanArchiveCompactNode(
                    node,
                    parent: parent
                )
            )
            lineData.append(ScanArchiveNodeIOConstants.newlineData)
            try writer.append(lineData)
            processedNodeCount += 1

            if ScanArchiveProgressReporting.shouldReportProgress(processedNodeCount) || processedNodeCount == totalNodeCount {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .writingNodes,
                    completedUnitCount: processedNodeCount,
                    totalUnitCount: totalNodeCount,
                    message: String(localized: "Writing node records", comment: "Progress message during scan archive processing.")
                ))
                await Task.yield()
            }
        }
        return try writer.finish()
    }

    /// Writes topology incrementally. Building and encoding the complete
    /// topology at once can consume hundreds of megabytes on a large scan.
    func writeTopology(
        _ treeStore: FileTreeStore,
        to url: URL,
        encoding: ScanArchiveSectionEncoding,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ScanArchiveError.topology(localized: "could not create topology section")
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        let orderedNodeIndices = treeStore.indexedNodeIndices()
        let ordinalByNodeIndex = try ScanArchiveNodeOrdinalLookup(
            orderedNodeIndices: orderedNodeIndices,
            backingNodeCapacity: treeStore.backingNodeCapacity,
            cancellationCheck: Task.checkCancellation
        )

        guard let rootIndex = treeStore.nodeIndex(id: treeStore.rootID) else {
            throw ScanArchiveError.topology(localized: "root node is missing from node order")
        }
        guard let rootOrdinal = ordinalByNodeIndex[rootIndex] else {
            throw ScanArchiveError.topology(localized: "root node is missing from node order")
        }

        var writer = try ScanArchiveStreamingJSONWriter(
            fileHandle: fileHandle,
            encoding: encoding
        )
        try writer.append("{\"r\":\(rootOrdinal),\"c\":{")
        var wroteParent = false

        for (processedOffset, parentIndex) in orderedNodeIndices.enumerated() {
            try Task.checkCancellation()
            let childIndices = treeStore.childIndices(of: parentIndex)
            if !childIndices.isEmpty {
                guard let parentOrdinal = ordinalByNodeIndex[parentIndex] else {
                    throw ScanArchiveError.topology(localized: "parent node is missing from node order")
                }

                if wroteParent {
                    try writer.append(",")
                }
                wroteParent = true
                try writer.append("\"\(parentOrdinal)\":[")

                for (childOffset, childIndex) in childIndices.enumerated() {
                    if childOffset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    guard let childOrdinal = ordinalByNodeIndex[childIndex] else {
                        throw ScanArchiveError.topology(localized: "child node is missing from node order")
                    }
                    if childOffset > 0 {
                        try writer.append(",")
                    }
                    try writer.append(String(childOrdinal))
                }
                try writer.append("]")
            }

            let completedCount = processedOffset + 1
            if ScanArchiveProgressReporting.shouldReportProgress(completedCount) ||
                completedCount == orderedNodeIndices.count {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .writingTopology,
                    completedUnitCount: completedCount,
                    totalUnitCount: orderedNodeIndices.count,
                    message: "Writing topology"
                ))
                await Task.yield()
            }
        }

        try writer.append("}}")
        return try writer.finish()
    }

    func readLegacyNodes(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        encoding: ScanArchiveSectionEncoding,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> ScanArchiveNodePayload {
        let records: [ScanArchiveNode] = try await readNodeRecords(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            encoding: encoding,
            progressReporter: progressReporter
        )
        var nodesByID: [String: FileNodeRecord] = [:]
        var orderedNodeIDs: [String] = []
        orderedNodeIDs.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let node = try record.modelNode()
            guard nodesByID[node.id] == nil else {
                throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
            }
            nodesByID[node.id] = node
            orderedNodeIDs.append(node.id)
        }
        return ScanArchiveNodePayload(
            nodesByID: nodesByID,
            orderedNodeIDs: orderedNodeIDs
        )
    }

    private func prepareCompactTopology(
        _ topology: ScanArchiveTopology,
        expectedNodeCount: Int
    ) throws -> ScanArchiveCompactTopology {
        guard (0..<expectedNodeCount).contains(topology.rootOrdinal) else {
            throw ScanArchiveError.topology(localized: "root ordinal \(topology.rootOrdinal) is out of range")
        }

        var edgeCount = 0
        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            try Task.checkCancellation()
            guard let parentOrdinal = Int(parentKey),
                  String(parentOrdinal) == parentKey,
                  (0..<expectedNodeCount).contains(parentOrdinal) else {
                throw ScanArchiveError.topology(localized: "parent ordinal \(parentKey) is invalid")
            }
            for childOrdinal in childOrdinals {
                if edgeCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                guard (0..<expectedNodeCount).contains(childOrdinal) else {
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is out of range")
                }
                let (updatedEdgeCount, overflow) = edgeCount.addingReportingOverflow(1)
                guard !overflow, updatedEdgeCount < expectedNodeCount else {
                    throw ScanArchiveError.topology(localized: "topology contains too many child references")
                }
                edgeCount = updatedEdgeCount
            }
        }
        guard edgeCount == expectedNodeCount - 1 else {
            try diagnoseMalformedCompactTopology(
                topology,
                rootOrdinal: topology.rootOrdinal,
                edgeCount: edgeCount
            )
            throw ScanArchiveError.topology(localized:
                "\(expectedNodeCount - edgeCount - 1) node(s) are not reachable from root"
            )
        }

        let noParent = UInt32.max
        var parentRawIndices = Array(repeating: noParent, count: expectedNodeCount)
        var childSpans = Array(repeating: FileTreeChildSpan(), count: expectedNodeCount)
        var childIndices: [FileTreeNodeIndex] = []
        childIndices.reserveCapacity(edgeCount)
        var parentsPrecedeChildren = true

        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            let parentOrdinal = Int(parentKey)!
            let childStart = childIndices.count
            for childOrdinal in childOrdinals {
                if childIndices.count.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                if childOrdinal == parentOrdinal {
                    if childOrdinal == topology.rootOrdinal {
                        throw ScanArchiveError.topology(localized: "root node references itself as a child")
                    }
                    throw ScanArchiveError.topology(localized: "node ordinal \(childOrdinal) references itself as a child")
                }
                let previousParent = parentRawIndices[childOrdinal]
                guard previousParent == noParent else {
                    if previousParent == UInt32(parentOrdinal) {
                        throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is duplicated")
                    }
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) has multiple parents")
                }
                parentRawIndices[childOrdinal] = UInt32(parentOrdinal)
                childIndices.append(FileTreeNodeIndex(rawValue: UInt32(childOrdinal)))
                parentsPrecedeChildren = parentsPrecedeChildren && parentOrdinal < childOrdinal
            }
            childSpans[parentOrdinal] = FileTreeChildSpan(
                start: UInt32(childStart),
                count: UInt32(childIndices.count - childStart)
            )
        }

        if parentRawIndices[topology.rootOrdinal] != noParent {
            if parentRawIndices[topology.rootOrdinal] == UInt32(topology.rootOrdinal) {
                throw ScanArchiveError.topology(localized: "root node references itself as a child")
            }
            throw ScanArchiveError.topology(localized: "root node is referenced as a child")
        }
        for ordinal in 0..<expectedNodeCount where ordinal != topology.rootOrdinal {
            guard parentRawIndices[ordinal] != noParent else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) is not reachable")
            }
        }

        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        var visited = Array(repeating: false, count: expectedNodeCount)
        var orderedNodeIndices: [FileTreeNodeIndex] = []
        orderedNodeIndices.reserveCapacity(expectedNodeCount)
        var stack = [rootIndex]
        while let nodeIndex = stack.popLast() {
            if orderedNodeIndices.count.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let offset = Int(nodeIndex.rawValue)
            guard !visited[offset] else {
                throw ScanArchiveError.topology(localized: "cycle detected at node ordinal \(offset)")
            }
            visited[offset] = true
            orderedNodeIndices.append(nodeIndex)
            let span = childSpans[offset]
            let start = Int(span.start)
            let end = start + Int(span.count)
            stack.append(contentsOf: childIndices[start..<end].reversed())
        }
        guard orderedNodeIndices.count == expectedNodeCount else {
            throw ScanArchiveError.topology(localized:
                "\(expectedNodeCount - orderedNodeIndices.count) node(s) are not reachable from root"
            )
        }

        return ScanArchiveCompactTopology(
            rootOrdinal: topology.rootOrdinal,
            parentRawIndices: parentRawIndices,
            childSpans: childSpans,
            childIndices: childIndices,
            orderedNodeIndices: orderedNodeIndices,
            parentsPrecedeChildren: parentsPrecedeChildren
        )
    }

    private func diagnoseMalformedCompactTopology(
        _ topology: ScanArchiveTopology,
        rootOrdinal: Int,
        edgeCount: Int
    ) throws {
        var parentByChild: [Int: Int] = [:]
        parentByChild.reserveCapacity(min(edgeCount, ScanArchiveNodeIOConstants.maximumInitialRecordCapacity))
        var processedChildCount = 0
        for (parentKey, childOrdinals) in topology.childOrdinalsByOrdinal {
            let parentOrdinal = Int(parentKey)!
            for childOrdinal in childOrdinals {
                if processedChildCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                processedChildCount += 1
                if childOrdinal == parentOrdinal {
                    if childOrdinal == rootOrdinal {
                        throw ScanArchiveError.topology(localized: "root node references itself as a child")
                    }
                    throw ScanArchiveError.topology(localized: "node ordinal \(childOrdinal) references itself as a child")
                }
                if let existingParent = parentByChild.updateValue(parentOrdinal, forKey: childOrdinal) {
                    if existingParent == parentOrdinal {
                        throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) is duplicated")
                    }
                    throw ScanArchiveError.topology(localized: "child ordinal \(childOrdinal) has multiple parents")
                }
            }
        }
        if parentByChild[rootOrdinal] != nil {
            throw ScanArchiveError.topology(localized: "root node is referenced as a child")
        }
    }

    private func compactNodeLocation(
        _ record: ScanArchiveCompactNode,
        ordinal: Int,
        rootOrdinal: Int,
        expectedRootID: String,
        parent: ScanArchiveNodeLocation?
    ) throws -> ScanArchiveNodeLocation {
        if ordinal == rootOrdinal {
            let id = record.explicitID ?? expectedRootID
            guard id == expectedRootID else {
                throw ScanArchiveError.topology(localized: "root ID does not match manifest")
            }
            return ScanArchiveNodeLocation(id: id, path: record.explicitPath ?? id)
        }
        guard let parent else {
            throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) has an unresolved parent")
        }
        if let explicitID = record.explicitID {
            return ScanArchiveNodeLocation(id: explicitID, path: record.explicitPath ?? explicitID)
        }
        guard let component = record.relativePath,
              !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("\0"),
              !component.contains("/") else {
            throw ScanArchiveError.nodes(localized:
                "node ordinal \(ordinal) has an invalid relative path"
            )
        }
        let separator = parent.path == "/" || parent.path.hasSuffix("/") ? "" : "/"
        let path = parent.path + separator + component
        return ScanArchiveNodeLocation(id: path, path: record.explicitPath ?? path)
    }

    private func modelCompactNode(
        _ record: ScanArchiveCompactNode,
        location: ScanArchiveNodeLocation,
        ordinal: Int,
        rootOrdinal: Int,
        expectedTargetPath: String,
        parentIsKnownContained: Bool = false
    ) throws -> FileNodeRecord {
        let hasValidatedRelativeLocation = ordinal != rootOrdinal &&
            record.explicitID == nil &&
            record.explicitPath == nil &&
            record.relativePath != nil
        let node = try record.payload.modelNode(
            resolvedID: location.id,
            resolvedPath: location.path,
            resolvedName: record.payload.name.isEmpty ? record.relativePath : nil,
            locationAlreadyValidated: hasValidatedRelativeLocation
        )
        if ordinal == rootOrdinal, node.url.path != expectedTargetPath {
            throw ScanArchiveError.topology(localized: "root path does not match target path")
        }
        let containmentAlreadyValidated = hasValidatedRelativeLocation && parentIsKnownContained
        if !node.isSynthetic,
           !containmentAlreadyValidated,
           !Self.path(node.id, isContainedIn: expectedTargetPath) {
            throw ScanArchiveError.topology(localized: "node \(node.id) path is outside target")
        }
        return node
    }

    func materializeCompactTreeStore(
        _ records: [ScanArchiveCompactNode],
        topology: ScanArchiveTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let compactTopology = try prepareCompactTopology(
            topology,
            expectedNodeCount: records.count
        )
        return try await materializeCompactTreeStore(
            records,
            topology: compactTopology,
            expectedRootID: expectedRootID,
            expectedTargetPath: expectedTargetPath,
            progressReporter: progressReporter
        )
    }

    private func materializeCompactTreeStore(
        _ records: [ScanArchiveCompactNode],
        topology: ScanArchiveCompactTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let noParent = UInt32.max

        var locations = Array<ScanArchiveNodeLocation?>(repeating: nil, count: records.count)

        func makeLocation(at ordinal: Int, parent: ScanArchiveNodeLocation?) throws -> ScanArchiveNodeLocation {
            let record = records[ordinal]
            return try compactNodeLocation(
                record,
                ordinal: ordinal,
                rootOrdinal: topology.rootOrdinal,
                expectedRootID: expectedRootID,
                parent: parent
            )
        }

        func resolveLocation(at ordinal: Int) throws -> ScanArchiveNodeLocation {
            if let location = locations[ordinal] {
                return location
            }
            if ordinal == topology.rootOrdinal {
                let location = try makeLocation(at: ordinal, parent: nil)
                locations[ordinal] = location
                return location
            }
            let directParentOrdinal = Int(topology.parentRawIndices[ordinal])
            if let parent = locations[directParentOrdinal] {
                let location = try makeLocation(at: ordinal, parent: parent)
                locations[ordinal] = location
                return location
            }

            var chain: [Int] = []
            var chainOrdinals = Set<Int>()
            var cursor = ordinal
            while locations[cursor] == nil {
                guard chainOrdinals.insert(cursor).inserted else {
                    throw ScanArchiveError.topology(localized: "cycle detected at node ordinal \(cursor)")
                }
                chain.append(cursor)
                guard cursor != topology.rootOrdinal else { break }
                let parentOrdinal = topology.parentRawIndices[cursor]
                guard parentOrdinal != noParent else {
                    throw ScanArchiveError.topology(localized: "node ordinal \(cursor) has an invalid parent")
                }
                cursor = Int(parentOrdinal)
            }

            while let pendingOrdinal = chain.popLast() {
                let parent = pendingOrdinal == topology.rootOrdinal
                    ? nil
                    : locations[Int(topology.parentRawIndices[pendingOrdinal])]
                let location = try makeLocation(at: pendingOrdinal, parent: parent)
                locations[pendingOrdinal] = location
            }

            guard let location = locations[ordinal] else {
                throw ScanArchiveError.topology(localized: "node ordinal \(ordinal) could not be resolved")
            }
            return location
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(records.count)
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(records.count)
        for ordinal in records.indices {
            if ordinal.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let location = try resolveLocation(at: ordinal)
            let node = try modelCompactNode(
                records[ordinal],
                location: location,
                ordinal: ordinal,
                rootOrdinal: topology.rootOrdinal,
                expectedTargetPath: expectedTargetPath
            )
            if topology.childSpans[ordinal].count > 0, !node.isDirectory {
                throw ScanArchiveError.topology(localized: "non-directory node ordinal \(ordinal) has children")
            }
            let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(ordinal))
            guard indexByNodeID.updateValue(nodeIndex, forKey: node.id) == nil else {
                throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
            }
            nodes.append(node)

            let completedCount = ordinal + 1
            if ScanArchiveProgressReporting.shouldReportProgress(completedCount) || completedCount == records.count {
                progressReporter?.report(ScanArchiveProgress(
                    phase: .validatingTopology,
                    completedUnitCount: completedCount,
                    totalUnitCount: records.count,
                    message: String(localized: "Validating topology", comment: "Progress message during scan archive processing.")
                ))
                await Task.yield()
            }
        }

        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        return FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: &nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: topology.parentRawIndices,
            childSpans: topology.childSpans,
            childIndices: topology.childIndices,
            orderedNodeIndices: topology.orderedNodeIndices
        )
    }

    func readCompactTreeStore(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        encoding: ScanArchiveSectionEncoding,
        topology archivedTopology: ScanArchiveTopology,
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> FileTreeStore {
        let topologyPreparationStartedAt = importProfileStart()
        let topology = try prepareCompactTopology(
            archivedTopology,
            expectedNodeCount: expectedNodeCount
        )
        finishImportProfile(.prepareTopology, startedAt: topologyPreparationStartedAt)
        guard topology.parentsPrecedeChildren else {
            let nodeReadingStartedAt = importProfileStart()
            let records: [ScanArchiveCompactNode] = try await readNodeRecords(
                from: url,
                expectedChecksum: expectedChecksum,
                expectedNodeCount: expectedNodeCount,
                encoding: encoding,
                progressReporter: progressReporter
            )
            finishImportProfile(.readAndMaterializeNodes, startedAt: nodeReadingStartedAt)
            guard records.count == expectedNodeCount else {
                throw ScanArchiveError.nodes(localized:
                    "manifest expected \(expectedNodeCount) nodes, found \(records.count)"
                )
            }
            let treeFinalizationStartedAt = importProfileStart()
            let treeStore = try await materializeCompactTreeStore(
                records,
                topology: topology,
                expectedRootID: expectedRootID,
                expectedTargetPath: expectedTargetPath,
                progressReporter: progressReporter
            )
            finishImportProfile(.finalizeTreeStore, startedAt: treeFinalizationStartedAt)
            return treeStore
        }

        var nodes: [FileNodeRecord] = []
        nodes.reserveCapacity(expectedNodeCount)
        var indexByNodeID: [String: FileTreeNodeIndex] = [:]
        indexByNodeID.reserveCapacity(expectedNodeCount)
        var explicitPathByOrdinal: [Int: String] = [:]

        let nodeReadingStartedAt = importProfileStart()
        try await readNodeBatches(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            encoding: encoding,
            progressReporter: progressReporter
        ) { (batch: [ScanArchiveCompactNode]) in
            for record in batch {
                let ordinal = nodes.count
                if ordinal.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let parent: ScanArchiveNodeLocation?
                let parentIsKnownContained: Bool
                if ordinal == topology.rootOrdinal {
                    parent = nil
                    parentIsKnownContained = false
                } else {
                    let parentOrdinal = Int(topology.parentRawIndices[ordinal])
                    guard nodes.indices.contains(parentOrdinal) else {
                        throw ScanArchiveError.topology(localized:
                            "node ordinal \(ordinal) has an unresolved parent"
                        )
                    }
                    let parentNode = nodes[parentOrdinal]
                    parent = ScanArchiveNodeLocation(
                        id: parentNode.id,
                        path: explicitPathByOrdinal[parentOrdinal] ?? parentNode.id
                    )
                    parentIsKnownContained = !parentNode.isSynthetic
                }

                let location = try compactNodeLocation(
                    record,
                    ordinal: ordinal,
                    rootOrdinal: topology.rootOrdinal,
                    expectedRootID: expectedRootID,
                    parent: parent
                )
                if location.path != location.id {
                    explicitPathByOrdinal[ordinal] = location.path
                }
                let node = try modelCompactNode(
                    record,
                    location: location,
                    ordinal: ordinal,
                    rootOrdinal: topology.rootOrdinal,
                    expectedTargetPath: expectedTargetPath,
                    parentIsKnownContained: parentIsKnownContained
                )
                if topology.childSpans[ordinal].count > 0, !node.isDirectory {
                    throw ScanArchiveError.topology(localized:
                        "non-directory node ordinal \(ordinal) has children"
                    )
                }
                let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(ordinal))
                guard indexByNodeID.updateValue(nodeIndex, forKey: node.id) == nil else {
                    throw ScanArchiveError.nodes(localized: "duplicate node ID \(node.id)")
                }
                nodes.append(node)
            }
        }
        finishImportProfile(.readAndMaterializeNodes, startedAt: nodeReadingStartedAt)

        guard nodes.count == expectedNodeCount else {
            throw ScanArchiveError.nodes(localized:
                "manifest expected \(expectedNodeCount) nodes, found \(nodes.count)"
            )
        }
        let rootIndex = FileTreeNodeIndex(rawValue: UInt32(topology.rootOrdinal))
        let treeFinalizationStartedAt = importProfileStart()
        let treeStore = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: &nodes,
            indexByNodeID: indexByNodeID,
            parentRawIndices: topology.parentRawIndices,
            childSpans: topology.childSpans,
            childIndices: topology.childIndices,
            orderedNodeIndices: topology.orderedNodeIndices
        )
        finishImportProfile(.finalizeTreeStore, startedAt: treeFinalizationStartedAt)
        return treeStore
    }

    private func readNodeRecords<Record: Decodable & Sendable>(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        encoding: ScanArchiveSectionEncoding,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws -> [Record] {
        var records: [Record] = []
        records.reserveCapacity(min(
            expectedNodeCount,
            ScanArchiveNodeIOConstants.maximumInitialRecordCapacity
        ))
        try await readNodeBatches(
            from: url,
            expectedChecksum: expectedChecksum,
            expectedNodeCount: expectedNodeCount,
            encoding: encoding,
            progressReporter: progressReporter
        ) { batch in
            records.append(contentsOf: batch)
        }
        return records
    }

    private func readNodeBatches<Record: Decodable & Sendable>(
        from url: URL,
        expectedChecksum: String,
        expectedNodeCount: Int,
        encoding: ScanArchiveSectionEncoding,
        progressReporter: ScanArchiveProgressReporter?,
        consumeBatch: ([Record]) throws -> Void
    ) async throws {
        let sectionReader: ScanArchiveSectionReader
        do {
            sectionReader = try ScanArchiveSectionReader(
                url: url,
                encoding: encoding
            )
        } catch {
            throw ScanArchiveError.nodes(error.localizedDescription)
        }
        defer { sectionReader.close() }

        var buffer = Data()
        var hasher = SHA256()
        var decodedNodeCount = 0
        var nextBatchIndex = 0
        var nextBatchToAppend = 0
        var pendingBatches: [Int: [Record]] = [:]
        var inFlightBatchCount = 0
        let maximumConcurrentDecodes = min(
            max(ProcessInfo.processInfo.activeProcessorCount, 1),
            ScanArchiveNodeIOConstants.maximumConcurrentDecodes
        )

        try await withThrowingTaskGroup(of: (Int, [Record]).self) { group in
            func appendReadyBatches() throws -> Bool {
                var appendedBatch = false
                while let batch = pendingBatches.removeValue(forKey: nextBatchToAppend) {
                    let updatedNodeCount = decodedNodeCount + batch.count
                    try validateDecodedNodeCount(updatedNodeCount, expectedNodeCount: expectedNodeCount)
                    let materializationStartedAt = importProfileStart()
                    try consumeBatch(batch)
                    finishImportProfile(
                        .nodeMaterializationWork,
                        startedAt: materializationStartedAt
                    )
                    decodedNodeCount = updatedNodeCount
                    nextBatchToAppend += 1
                    appendedBatch = true
                    progressReporter?.report(ScanArchiveProgress(
                        phase: .readingNodes,
                        completedUnitCount: decodedNodeCount,
                        totalUnitCount: expectedNodeCount,
                        message: String(localized: "Reading node records", comment: "Progress message during scan archive processing.")
                    ))
                }
                return appendedBatch
            }

            func enqueue(_ batchData: Data) {
                let batchIndex = nextBatchIndex
                nextBatchIndex += 1
                inFlightBatchCount += 1
                group.addTask {
                    let decodingStartedAt = importProfileStart()
                    let decoder = Self.makeJSONDecoder()
                    let records: [Record] = try decodeNodeBatch(batchData, decoder: decoder)
                    finishImportProfile(.nodeDecodeWork, startedAt: decodingStartedAt)
                    return (batchIndex, records)
                }
            }

            while true {
                try Task.checkCancellation()
                while inFlightBatchCount + pendingBatches.count >= maximumConcurrentDecodes {
                    let decoderWaitStartedAt = importProfileStart()
                    guard let completedBatch = try await group.next() else { break }
                    finishImportProfile(.nodeDecodeWait, startedAt: decoderWaitStartedAt)
                    inFlightBatchCount -= 1
                    pendingBatches[completedBatch.0] = completedBatch.1
                    if try appendReadyBatches() {
                        await Task.yield()
                    }
                }

                let ioStartedAt = importProfileStart()
                let chunk: Data
                do {
                    chunk = try sectionReader.read(
                        upToCount: ScanArchiveNodeIOConstants.readChunkSize
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ScanArchiveError {
                    throw error
                } catch {
                    throw ScanArchiveError.nodes(error.localizedDescription)
                }
                guard !chunk.isEmpty else {
                    finishImportProfile(.nodeIOWork, startedAt: ioStartedAt)
                    break
                }
                hasher.update(data: chunk)
                buffer.append(chunk)

                if let newlineIndex = buffer.lastIndex(of: 0x0A) {
                    let lineEndIndex = buffer.index(after: newlineIndex)
                    enqueue(Data(buffer[..<lineEndIndex]))
                    buffer.removeSubrange(..<lineEndIndex)
                }
                try validateNodeLineSize(buffer)
                finishImportProfile(.nodeIOWork, startedAt: ioStartedAt)
            }

            if !buffer.isEmpty {
                try validateNodeLineSize(buffer)
                enqueue(buffer)
                buffer = Data()
            }

            while true {
                let decoderWaitStartedAt = importProfileStart()
                guard let completedBatch = try await group.next() else { break }
                finishImportProfile(.nodeDecodeWait, startedAt: decoderWaitStartedAt)
                inFlightBatchCount -= 1
                pendingBatches[completedBatch.0] = completedBatch.1
                if try appendReadyBatches() {
                    await Task.yield()
                }
            }
        }

        progressReporter?.report(ScanArchiveProgress(
            phase: .readingNodes,
            completedUnitCount: decodedNodeCount,
            totalUnitCount: expectedNodeCount,
            message: String(localized: "Reading node records", comment: "Progress message during scan archive processing.")
        ))

        let actualChecksum = Data(hasher.finalize()).base64EncodedString()
        guard actualChecksum == expectedChecksum else {
            throw ScanArchiveError.integrity(localized: "nodes checksum mismatch")
        }

    }

    private func validateNodeLineSize(_ lineData: Data) throws {
        guard lineData.count <= ScanArchiveNodeIOConstants.maxNodeLineByteCount else {
            throw ScanArchiveError.nodes(localized: "node record is too large")
        }
    }

    private func validateDecodedNodeCount(_ decodedNodeCount: Int, expectedNodeCount: Int) throws {
        guard decodedNodeCount <= expectedNodeCount else {
            throw ScanArchiveError.nodes(localized: "node payload contains more nodes than manifest expected")
        }
    }

    private func decodeNodeLine<Record: Decodable>(
        _ lineData: Data,
        decoder: JSONDecoder
    ) throws -> Record? {
        guard !lineData.isEmpty else { return nil }
        do {
            return try decoder.decode(Record.self, from: lineData)
        } catch let error as ScanArchiveError {
            throw error
        } catch {
            throw ScanArchiveError.nodes(localized: "invalid JSONL node: \(error.localizedDescription)")
        }
    }

    private func decodeNodeBatch<Record: Decodable & Sendable>(
        _ data: Data,
        decoder: JSONDecoder
    ) throws -> [Record] {
        var result: [Record] = []
        var lineStartIndex = data.startIndex
        while let newlineIndex = data[lineStartIndex...].firstIndex(of: 0x0A) {
            let lineData = data[lineStartIndex..<newlineIndex]
            lineStartIndex = data.index(after: newlineIndex)
            try validateNodeLineSize(lineData)
            if let record: Record = try decodeNodeLine(lineData, decoder: decoder) {
                result.append(record)
            }
        }
        if lineStartIndex < data.endIndex {
            let lineData = data[lineStartIndex...]
            try validateNodeLineSize(lineData)
            if let record: Record = try decodeNodeLine(lineData, decoder: decoder) {
                result.append(record)
            }
        }
        return result
    }
}
