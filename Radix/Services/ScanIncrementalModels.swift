import Foundation

/// A persistent position in one volume's FSEvents journal.
///
/// The event ID is meaningful only while `volumeUUID` still identifies the
/// device containing the scan target. `capturedAt` is informational; event IDs,
/// rather than wall-clock time, define the history boundary.
nonisolated struct ScanIncrementalCheckpoint: Codable, Hashable, Sendable {
    let volumeUUID: String
    let eventID: UInt64
    let capturedAt: Date

    init(volumeUUID: String, eventID: UInt64, capturedAt: Date = Date()) {
        self.volumeUUID = volumeUUID.lowercased()
        self.eventID = eventID
        self.capturedAt = capturedAt
    }
}

/// Filesystem-independent flags consumed by the incremental rescan planner.
/// The Darwin provider translates FSEvents constants into these values so the
/// planner and its tests do not depend on CoreServices numeric constants.
nonisolated struct FileSystemEventFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let mustScanSubdirectories = Self(rawValue: 1 << 0)
    static let userDropped = Self(rawValue: 1 << 1)
    static let kernelDropped = Self(rawValue: 1 << 2)
    static let eventIDsWrapped = Self(rawValue: 1 << 3)
    static let rootChanged = Self(rawValue: 1 << 4)
    static let volumeMounted = Self(rawValue: 1 << 5)
    static let volumeUnmounted = Self(rawValue: 1 << 6)

    static let itemCreated = Self(rawValue: 1 << 7)
    static let itemRemoved = Self(rawValue: 1 << 8)
    static let itemRenamed = Self(rawValue: 1 << 9)
    static let itemModified = Self(rawValue: 1 << 10)
    static let itemMetadataModified = Self(rawValue: 1 << 11)
    static let itemIsFile = Self(rawValue: 1 << 12)
    static let itemIsDirectory = Self(rawValue: 1 << 13)
    static let itemIsSymbolicLink = Self(rawValue: 1 << 14)
    static let itemCloned = Self(rawValue: 1 << 15)
    static let itemIsHardLink = Self(rawValue: 1 << 16)
    static let itemIsLastHardLink = Self(rawValue: 1 << 17)
}

/// Producers supply absolute paths in the scan's namespace. Preserve them:
/// Foundation standardization can rewrite `/private/var` to `/var`.
nonisolated struct FileSystemEventRecord: Codable, Hashable, Sendable {
    let path: String
    let eventID: UInt64
    let flags: FileSystemEventFlags

    init(path: String, eventID: UInt64, flags: FileSystemEventFlags) {
        self.path = path
        self.eventID = eventID
        self.flags = flags
    }
}

nonisolated struct FileSystemEventHistory: Sendable {
    let since: ScanIncrementalCheckpoint
    let through: ScanIncrementalCheckpoint
    let events: [FileSystemEventRecord]

    init(
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint,
        events: [FileSystemEventRecord]
    ) {
        self.since = since
        self.through = through
        self.events = events
    }
}

nonisolated enum IncrementalRescanFallbackReason: String, Codable, Hashable, Sendable {
    case incompleteBaseline
    case readOnlyBaseline
    case volumeTarget
    case changedTarget
    case changedScanOptions
    case checkpointUnavailable
    case targetIdentityUnavailable
    case targetIdentityChanged
    case eventHistoryUnavailable
    case userDroppedEvents
    case kernelDroppedEvents
    case eventIDsWrapped
    case watchedRootChanged
    case nestedVolumeChanged
    case cloneTopologyChanged
    case changedScanRoot
    case eventOutsideTarget
    case noMaterializedAncestor
    case autoSummarizedBoundary
    case incrementalWorkTooBroad
    case sharedAllocationTopologyChanged
    case directoryRelistFailed
    case changedSubtreeUnavailable
    case subtreeRescanFailed
    case subtreeResultUnavailable
    case treeUpdateFailed
}

/// Groups implementation-level fallback reasons into explanations that are
/// useful to someone waiting for a rescan to finish.
nonisolated enum ScanFallbackCategory: Equatable, Sendable {
    case settingsChanged
    case historyUnavailable
    case tooManyChanges
    case locationChanged
    case volumeAccounting
    case previousScanUnavailable
    case incrementalUpdateFailed
}

nonisolated extension IncrementalRescanFallbackReason {
    var presentationCategory: ScanFallbackCategory {
        switch self {
        case .changedScanOptions:
            return .settingsChanged
        case .checkpointUnavailable,
             .eventHistoryUnavailable,
             .userDroppedEvents,
             .kernelDroppedEvents,
             .eventIDsWrapped:
            return .historyUnavailable
        case .incrementalWorkTooBroad:
            return .tooManyChanges
        case .changedTarget,
             .targetIdentityUnavailable,
             .targetIdentityChanged,
             .watchedRootChanged,
             .nestedVolumeChanged,
             .changedScanRoot,
             .eventOutsideTarget:
            return .locationChanged
        case .volumeTarget:
            return .volumeAccounting
        case .incompleteBaseline,
             .readOnlyBaseline,
             .noMaterializedAncestor,
             .autoSummarizedBoundary,
             .cloneTopologyChanged,
             .sharedAllocationTopologyChanged:
            return .previousScanUnavailable
        case .directoryRelistFailed,
             .changedSubtreeUnavailable,
             .subtreeRescanFailed,
             .subtreeResultUnavailable,
             .treeUpdateFailed:
            return .incrementalUpdateFailed
        }
    }
}

/// Describes the work backing the active scan without persisting transient UI state
/// into a completed snapshot.
nonisolated enum ScanExecutionMode: Equatable, Sendable {
    case full
    case preparingIncremental
    case incremental
    case incrementalNoChanges
    case fullFallback(IncrementalRescanFallbackReason)
}

nonisolated enum IncrementalRescanPlan: Equatable, Sendable {
    case noChanges
    case update(
        relistDirectoryIDs: [String],
        rescanSubtreeIDs: [String]
    )
    case fullScan(reason: IncrementalRescanFallbackReason)
}

nonisolated enum FileSystemEventHistoryError: LocalizedError, Sendable {
    case targetUnavailable(String)
    case targetIsNotDirectory(String)
    case nonLocalVolume(String)
    case volumeUUIDUnavailable(String)
    case eventIDUnavailable(String)
    case volumeChanged
    case eventIDRolledBack
    case invalidCheckpointRange
    case streamCreationFailed
    case streamStartFailed
    case historyEndedWithoutSentinel

    var errorDescription: String? {
        switch self {
        case .targetUnavailable(let path):
            return String(localized: "The incremental scan target is unavailable: \(path).", comment: "Error shown when an incremental scan target is unavailable.")
        case .targetIsNotDirectory(let path):
            return String(localized: "The incremental scan target is not a directory: \(path).", comment: "Error shown when an incremental scan target is not a directory.")
        case .nonLocalVolume(let path):
            return String(localized: "Incremental scans are unavailable for the non-local volume containing \(path).", comment: "Error shown when incremental scanning is unavailable on a non-local volume.")
        case .volumeUUIDUnavailable(let path):
            return String(localized: "The volume containing \(path) does not expose an FSEvents UUID.", comment: "Error shown when a volume has no FSEvents UUID.")
        case .eventIDUnavailable(let path):
            return String(localized: "The volume containing \(path) does not expose an FSEvents checkpoint.", comment: "Error shown when a volume has no FSEvents checkpoint.")
        case .volumeChanged:
            return String(localized: "The scan target is now on a different volume.", comment: "Error shown when an incremental scan target moved volumes.")
        case .eventIDRolledBack:
            return String(localized: "The volume's FSEvents history is older than the saved checkpoint.", comment: "Error shown when an incremental scan checkpoint is too old.")
        case .invalidCheckpointRange:
            return String(localized: "The requested FSEvents checkpoint range is invalid.", comment: "Error shown when an incremental scan checkpoint range is invalid.")
        case .streamCreationFailed:
            return String(localized: "Radix could not create an FSEvents history stream.", comment: "Error shown when an FSEvents history stream cannot be created.")
        case .streamStartFailed:
            return String(localized: "Radix could not start the FSEvents history stream.", comment: "Error shown when an FSEvents history stream cannot be started.")
        case .historyEndedWithoutSentinel:
            return String(localized: "The FSEvents history stream ended before reporting HistoryDone.", comment: "Error shown when an FSEvents history stream ends unexpectedly.")
        }
    }
}
