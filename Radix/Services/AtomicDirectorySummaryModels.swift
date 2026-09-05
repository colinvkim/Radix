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
    let localizedEnumerationError: Error?
    let isDirectoryHint: Bool?
    /// Exact validated child-name bytes for native descriptor-relative work and
    /// Unicode names. Ordinary ASCII leaves and Foundation entries omit them.
    let nativeName: BulkDirectoryEnumerator.NativeName?

    init(
        url: URL,
        metadata: NodeMetadata?,
        localizedEnumerationError: Error? = nil,
        isDirectoryHint: Bool? = nil,
        nativeName: BulkDirectoryEnumerator.NativeName? = nil
    ) {
        self.url = url
        self.metadata = metadata
        self.localizedEnumerationError = localizedEnumerationError
        self.isDirectoryHint = isDirectoryHint
        self.nativeName = nativeName
    }
}

nonisolated struct AtomicDirectorySummary: Sendable {
    let allocatedSize: Int64
    let logicalSize: Int64
    let descendantFileCount: Int
    /// Entries inspected while producing the summary, including directories and
    /// entries later excluded from the represented result.
    let visitedItemCount: Int
    let isAccessible: Bool
    let warnings: [ScanWarning]
    let sharedAllocationAccumulator: SharedAllocationOwnerAccumulator
}

nonisolated struct AtomicDirectorySummaryPartial: Sendable {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var descendantFileCount = 0
    var visitedItemCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var sharedAllocationAccumulator = SharedAllocationOwnerAccumulator()

    mutating func updateAccessibility(_ readable: Bool) {
        isAccessible = isAccessible && readable
    }

    mutating func recordWarning(for url: URL, error: Error) {
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    mutating func accumulateFile(
        _ metadata: NodeMetadata,
        url: URL,
        ownerNodeID: String,
        knownPath: String? = nil
    ) {
        allocatedSize = ScanIntegerMath.addingClamped(allocatedSize, metadata.allocatedSize)
        logicalSize = ScanIntegerMath.addingClamped(logicalSize, metadata.logicalSize)
        if !metadata.isSymbolicLink {
            descendantFileCount = ScanIntegerMath.addingClamped(descendantFileCount, 1)
        }
        if let claim = SharedAllocationDeduplicator.claim(
            for: metadata,
            ownerNodeID: ownerNodeID,
            path: knownPath ?? url.path
        ) {
            sharedAllocationAccumulator.record(claim)
        }
    }
}

nonisolated struct AtomicSummaryWorkResult: Sendable {
    var partial: AtomicDirectorySummaryPartial
    var pendingItems: [AtomicSummaryWorkItem]
}

nonisolated struct AtomicSummaryWorkItem: @unchecked Sendable {
    let url: URL
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
    let expectedIdentity: FileIdentity?
    let volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy
    var bufferedEntries: [DirectoryEntry]
    var nextEntryIndex: Int
    var cursor: BulkDirectoryEnumerator.Cursor?
    var needsCursor: Bool
    var requiresRootRestartOnFallback: Bool
    /// The scan's immediate-child listing may contain an entry whose prefetched
    /// metadata failed transiently. The legacy reused-entry path retried those
    /// entries once before recording a warning; pooled reused work preserves that
    /// behavior without changing cursor-enumeration failure handling.
    var reloadsMissingBufferedMetadata: Bool

    init(
        url: URL,
        treatPackagesAsDirectories: Bool,
        ownerNodeID: String,
        expectedIdentity: FileIdentity? = nil,
        volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy = .unrestricted,
        bufferedEntries: [DirectoryEntry] = [],
        nextEntryIndex: Int = 0,
        cursor: BulkDirectoryEnumerator.Cursor? = nil,
        needsCursor: Bool = true,
        requiresRootRestartOnFallback: Bool = false,
        reloadsMissingBufferedMetadata: Bool = false
    ) {
        self.url = url
        self.treatPackagesAsDirectories = treatPackagesAsDirectories
        self.ownerNodeID = ownerNodeID
        self.expectedIdentity = expectedIdentity
        self.volumeBoundaryPolicy = volumeBoundaryPolicy
        self.bufferedEntries = bufferedEntries
        self.nextEntryIndex = nextEntryIndex
        self.cursor = cursor
        self.needsCursor = needsCursor
        self.requiresRootRestartOnFallback = requiresRootRestartOnFallback
        self.reloadsMissingBufferedMetadata = reloadsMissingBufferedMetadata
    }
}

nonisolated struct AtomicDirectoryProbeResumeState: @unchecked Sendable {
    var partial: AtomicDirectorySummaryPartial
    var workItems: [AtomicSummaryWorkItem]
    let visitedItemCount: Int

    init(
        partial: AtomicDirectorySummaryPartial,
        workItems: [AtomicSummaryWorkItem],
        visitedItemCount: Int
    ) {
        var partial = partial
        partial.visitedItemCount = max(partial.visitedItemCount, visitedItemCount)
        self.partial = partial
        self.workItems = workItems
        self.visitedItemCount = max(visitedItemCount, 0)
    }

    func invalidateCursors() {
        for workItem in workItems {
            workItem.cursor?.invalidate()
        }
    }
}

nonisolated struct AtomicDirectoryProbeOutcome: @unchecked Sendable {
    var profile: AtomicDirectoryProbeProfile
    var resumeState: AtomicDirectoryProbeResumeState?
    var visitedItemCount: Int
    var reusableDirectoryListings: [String: AtomicDirectoryProbeListing]
    var fullyExhausted: Bool

    init(
        profile: AtomicDirectoryProbeProfile,
        resumeState: AtomicDirectoryProbeResumeState?,
        visitedItemCount: Int = 0,
        reusableDirectoryListings: [String: AtomicDirectoryProbeListing] = [:],
        fullyExhausted: Bool = false
    ) {
        self.profile = profile
        self.resumeState = resumeState
        self.visitedItemCount = visitedItemCount
        self.reusableDirectoryListings = reusableDirectoryListings
        self.fullyExhausted = fullyExhausted
    }
}

nonisolated struct AtomicDirectoryProbeListing: Sendable {
    let entries: [DirectoryEntry]
    let enumeratedItemCount: Int
}

nonisolated struct AtomicDirectorySummaryDecision: Sendable {
    let summary: AtomicDirectorySummary?
    let reusableDirectoryListings: [String: AtomicDirectoryProbeListing]
    let descendantProbeFullyExhausted: Bool
}

#if DEBUG
nonisolated enum ScanAutoSummaryProfileEvent: Sendable {
    case probeCompleted(visitedItemCount: Int, wasAccepted: Bool)
    case directorySummarized(descendantFileCount: Int)
    case reusedDirectoryListing(entryCount: Int)
}
#endif

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
