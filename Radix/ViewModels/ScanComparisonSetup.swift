import Foundation

nonisolated enum ScanComparisonCandidateSource: Equatable, Sendable {
    case archive(URL)
    case currentSnapshot(UUID)
}

nonisolated enum ScanComparisonSlot: String, CaseIterable, Identifiable, Sendable {
    case before
    case after

    var id: String { rawValue }

    var title: String {
        switch self {
        case .before:
            return String(localized: "Earlier Scan", comment: "Comparison slot label for the older scan.")
        case .after:
            return String(localized: "Later Scan", comment: "Comparison slot label for the newer scan.")
        }
    }
}

nonisolated struct ScanComparisonCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ScanComparisonCandidateSource
    let displayName: String
    let path: String
    let targetKind: ScanTargetKind
    let scanDate: Date
    let totalAllocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let warningCount: Int
    let scanOptions: ScanOptions?

    init(preview: ScanArchivePreview) {
        self.id = UUID()
        self.source = .archive(preview.archiveURL)
        self.displayName = preview.target.displayName
        self.path = preview.target.path
        self.targetKind = preview.target.kind
        self.scanDate = preview.finishedAt ?? preview.startedAt
        self.totalAllocatedSize = preview.totalAllocatedSize
        self.fileCount = preview.fileCount
        self.directoryCount = preview.directoryCount
        self.warningCount = preview.warningCount
        self.scanOptions = preview.scanOptions
    }

    init(snapshot: ScanSnapshot) {
        self.init(snapshot: snapshot, source: .currentSnapshot(snapshot.id))
    }

    private init(snapshot: ScanSnapshot, source: ScanComparisonCandidateSource) {
        self.id = snapshot.id
        self.source = source
        self.displayName = snapshot.target.displayName
        self.path = snapshot.target.url.path
        self.targetKind = snapshot.target.kind
        self.scanDate = snapshot.finishedAt ?? snapshot.startedAt
        self.totalAllocatedSize = snapshot.aggregateStats.totalAllocatedSize
        self.fileCount = snapshot.aggregateStats.fileCount
        self.directoryCount = snapshot.aggregateStats.directoryCount
        self.warningCount = snapshot.scanWarnings.count
        self.scanOptions = snapshot.scanOptions
    }

    var isCurrentScan: Bool {
        if case .currentSnapshot = source {
            return true
        }
        return false
    }
}

nonisolated struct ScanComparisonSetup: Identifiable, Equatable, Sendable {
    let id: UUID
    var before: ScanComparisonCandidate?
    var after: ScanComparisonCandidate?
    var loadingSlot: ScanComparisonSlot?
    var errorMessage: String?

    init(
        before: ScanComparisonCandidate? = nil,
        after: ScanComparisonCandidate? = nil,
        loadingSlot: ScanComparisonSlot? = nil,
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.before = before
        self.after = after
        self.loadingSlot = loadingSlot
        self.errorMessage = errorMessage
    }

    var canCompare: Bool {
        guard loadingSlot == nil,
              let before,
              let after else {
            return false
        }
        return before.source != after.source && validationMessage == nil
    }

    var validationMessage: String? {
        guard let before,
              let after else {
            return nil
        }
        if before.source == after.source {
            return String(
                localized: "Choose two different scans.",
                comment: "Error shown when both comparison slots contain the same scan."
            )
        }
        guard before.targetKind == after.targetKind,
              Self.normalizedRootPath(before.path) == Self.normalizedRootPath(after.path) else {
            return String(
                localized: "Choose scans of the same location.",
                comment: "Error shown when comparing scans of different locations."
            )
        }
        if before.scanDate > after.scanDate {
            return String(
                localized: "The earlier scan must precede the later scan.",
                comment: "Error shown when comparison slots are in reverse chronological order."
            )
        }
        return nil
    }

    var coverageWarningMessage: String? {
        guard let before,
              let after,
              validationMessage == nil else {
            return nil
        }

        switch (before.scanOptions, after.scanOptions) {
        case let (beforeOptions?, afterOptions?) where beforeOptions != afterOptions:
            return String(
                localized: "Coverage warning: Scan settings differ, so added or removed items may reflect coverage changes rather than disk changes.",
                comment: "Non-blocking warning shown before comparing scans made with different settings."
            )
        case (nil, _), (_, nil):
            return String(
                localized: "Coverage warning: Scan settings are unavailable for one or both scans, so some changes may be caused by different scan coverage.",
                comment: "Non-blocking warning shown before comparing scans whose settings are unavailable."
            )
        default:
            return nil
        }
    }

    var resolvedCandidates: (before: ScanComparisonCandidate, after: ScanComparisonCandidate)? {
        guard let before,
              let after else {
            return nil
        }
        return (before, after)
    }

    var currentSnapshotID: UUID? {
        if case .currentSnapshot(let id)? = before?.source {
            return id
        }
        if case .currentSnapshot(let id)? = after?.source {
            return id
        }
        return nil
    }

    func candidate(for slot: ScanComparisonSlot) -> ScanComparisonCandidate? {
        switch slot {
        case .before:
            return before
        case .after:
            return after
        }
    }

    func canAssignCurrentScan(to slot: ScanComparisonSlot) -> Bool {
        let otherCandidate = switch slot {
        case .before:
            after
        case .after:
            before
        }
        return otherCandidate?.isCurrentScan != true
    }

    mutating func setCandidate(_ candidate: ScanComparisonCandidate?, for slot: ScanComparisonSlot) {
        switch slot {
        case .before:
            before = candidate
        case .after:
            after = candidate
        }
    }

    mutating func swap() {
        Swift.swap(&before, &after)
        switch loadingSlot {
        case .before:
            loadingSlot = .after
        case .after:
            loadingSlot = .before
        case nil:
            break
        }
    }

    private static func normalizedRootPath(_ path: String) -> String {
        URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
    }
}
