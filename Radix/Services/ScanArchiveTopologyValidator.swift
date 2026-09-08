//
//  ScanArchiveTopologyValidator.swift
//  Radix
//

import Foundation

extension ScanArchiveService {
    func validateTopology(
        _ topology: ScanArchiveResolvedTopology,
        nodesByID: [String: FileNodeRecord],
        expectedRootID: String,
        expectedTargetPath: String,
        progressReporter: ScanArchiveProgressReporter?
    ) async throws {
        guard topology.rootID == expectedRootID else {
            throw ScanArchiveError.topology(localized: "root ID does not match manifest")
        }
        guard let rootNode = nodesByID[topology.rootID] else {
            throw ScanArchiveError.topology(localized: "root node is missing")
        }
        guard rootNode.url.path == expectedTargetPath else {
            throw ScanArchiveError.topology(localized: "root path does not match target path")
        }
        for parentID in topology.childIDsByID.keys where nodesByID[parentID] == nil {
            throw ScanArchiveError.topology(localized: "child map parent \(parentID) is missing from node payload")
        }

        var parentedNodeIDs: Set<String> = []
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
                throw ScanArchiveError.topology(localized: "node \(nodeID) is missing from node payload")
            }
            if visiting.contains(nodeID) {
                throw ScanArchiveError.topology(localized: "cycle detected at node \(nodeID)")
            }
            if visited.contains(nodeID) {
                return
            }

            visiting.insert(nodeID)
            let childIDs = topology.childIDsByID[nodeID] ?? []
            if !childIDs.isEmpty && nodesByID[nodeID]?.isDirectory != true {
                throw ScanArchiveError.topology(localized: "non-directory node \(nodeID) has children")
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
                if ScanArchiveProgressReporting.shouldReportProgress(visited.count) || visited.count == nodesByID.count {
                    try Task.checkCancellation()
                    progressReporter?.report(ScanArchiveProgress(
                        phase: .validatingTopology,
                        completedUnitCount: visited.count,
                        totalUnitCount: nodesByID.count,
                        message: String(localized: "Validating topology", comment: "Progress message during scan archive processing.")
                    ))
                    await Task.yield()
                }
                continue
            }

            let childID = frame.childIDs[frame.nextChildIndex]
            frame.nextChildIndex += 1
            guard frame.seenChildIDs.insert(childID).inserted else {
                throw ScanArchiveError.topology(localized: "node \(frame.nodeID) contains duplicate child \(childID)")
            }
            stack.append(frame)

            guard childID != frame.nodeID else {
                throw ScanArchiveError.topology(localized: "node \(frame.nodeID) references itself as a child")
            }
            guard nodesByID[childID] != nil else {
                throw ScanArchiveError.topology(localized: "child \(childID) is missing from node payload")
            }
            if let parentNode = nodesByID[frame.nodeID],
               let childNode = nodesByID[childID],
               !childNode.isSynthetic,
               !Self.path(childNode.url.path, isContainedIn: expectedTargetPath) {
                throw ScanArchiveError.topology(localized: "child \(childID) path is outside target \(parentNode.id)")
            }
            guard parentedNodeIDs.insert(childID).inserted else {
                throw ScanArchiveError.topology(localized: "child \(childID) has multiple parents")
            }
            try enter(childID)
        }

        guard visited.count == nodesByID.count else {
            let missingCount = nodesByID.count - visited.count
            throw ScanArchiveError.topology(localized: "\(missingCount) node(s) are not reachable from root")
        }

    }

    static func path(_ childPath: String, isContainedIn parentPath: String) -> Bool {
        guard childPath != parentPath else { return true }
        if parentPath == "/" {
            return childPath.hasPrefix("/")
        }

        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : "\(parentPath)/"
        return childPath.hasPrefix(parentPrefix)
    }
}
