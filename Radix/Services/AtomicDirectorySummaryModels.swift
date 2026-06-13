//
//  AtomicDirectorySummaryModels.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

typealias CancellationCheck = @Sendable () throws -> Void

/// A child discovered during directory enumeration.
/// Directory enumeration prefetches resource values, so carrying decoded metadata forward
/// avoids asking each URL for the same values again when the child is scanned.
nonisolated struct DirectoryEntry: Sendable {
    let url: URL
    let metadata: NodeMetadata?
}

nonisolated struct AtomicDirectorySummary: Sendable {
    let allocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    let isAccessible: Bool
    let warnings: [ScanWarning]
    let hardLinkClaims: [HardLinkClaim]
}

nonisolated final class AtomicDirectorySummaryState {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkClaims: [HardLinkClaim] = []
    let ownerNodeID: String

    init(ownerNodeID: String) {
        self.ownerNodeID = ownerNodeID
    }
}

nonisolated struct AtomicDirectoryProbeProfile: Sendable {
    var observedFileCount = 0
    var observedDirectoryCount = 0
    var totalSampledLogicalSize: Int64 = 0
    var observedNodeDependencyLayout = false

    func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
        guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
        return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
    }
}
