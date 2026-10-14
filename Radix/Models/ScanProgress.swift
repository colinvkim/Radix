import Foundation

nonisolated struct ScanMetrics: Sendable {
    var filesVisited = 0
    var directoriesVisited = 0
    var bytesDiscovered: Int64 = 0
    var currentPath = ""
    var discoveredItems = 0
    var completedItems = 0
    var estimatedTotalBytes: Int64 = 0
    var volumeCapacity: VolumeCapacitySnapshot?
    /// Fraction of the tree's total traversal weight that has finished scanning (0...1).
    /// The scanner assigns the root a weight of 1 and recursively splits each directory's
    /// weight among its children when the directory is enumerated, so the sum of completed
    /// weights converges to 1 exactly as the traversal finishes.
    var completedTraversalWeight = 0.0
    /// Fractional traversal weight completed inside package/atomic summaries that
    /// are still in flight. This is folded into progress without marking their
    /// tree nodes complete before the summary result is committed.
    var atomicSummaryCompletedTraversalWeight = 0.0
    var atomicSummaryVisitedItems = 0
    var atomicSummaryEstimatedRemainingItems = 0
    var activeAtomicSummaryCount = 0
    var activePackageSummaryCount = 0
    var activePackageSummaryVisitedItems = 0
    var activePackageSummaryEstimatedRemainingItems = 0
    var activeAutoSummaryRepresentedItemCount = 0
    /// Package nodes that are known to require descendant work but have not
    /// committed yet. Observed summary descendants let the count cap
    /// extrapolate across package-heavy sibling sets without a prewalk.
    var pendingPackageSummaryCount = 0
    /// Direct children already discovered by ordinary traversal but temporarily
    /// transferred to an auto-summary decision or summary job.
    var pendingAutoSummaryRepresentedItemCount = 0
    var pendingAutoSummaryRepresentedDirectoryCount = 0
    /// Summary visits not already represented by `completedItems`.
    var completedSummaryAdditionalVisitedItemCount = 0
    var completedPackageSummaryCount = 0
    var completedPackageSummaryVisitedItemCount = 0
    /// Progress through the bottom-up assembly phase (0...1). Only meaningful while
    /// `isFinalizing` is true.
    var finalizationFraction = 0.0
    /// Directories whose contents have been enumerated (successfully or not).
    var enumeratedDirectoryCount = 0
    /// Directories discovered but not yet enumerated — the traversal frontier.
    var pendingDirectoryCount = 0
    /// Traversable directories counted in the active scan frontier for progress extrapolation.
    /// Final folder totals come from `ScanAggregateStats.directoryCount`, not this value.
    var discoveredDirectoryCount = 0
    var progressFraction = 0.0
    var isFinalizing = false

    /// Portion of the progress bar reserved for traversal; the remainder is consumed by
    /// the assembly (finalization) phase, with the final point reserved for completion.
    private nonisolated static let traversalSpan = 0.95
    private nonisolated static let finalizationCeiling = 0.99
    /// Upper bound on the geometric expansion applied per frontier directory when
    /// extrapolating how many descendants it will yield.
    private nonisolated static let maxFrontierExpansion = 6.0
    /// Matches the atomic-summary coordinator's minimum estimate for a newly
    /// registered work item before its first entries are observed.
    nonisolated static let unobservedSummaryEstimatedItemCount = 64

    nonisolated var progressPercentage: Int {
        Int((progressFraction * 100).rounded(.down))
    }

    nonisolated var currentItemName: String? {
        guard !currentPath.isEmpty else { return nil }
        let name = URL(filePath: currentPath).lastPathComponent
        return name.isEmpty ? nil : name
    }

    nonisolated mutating func recalculateProgress(isComplete: Bool = false) {
        if isComplete {
            progressFraction = 1
            return
        }

        if isFinalizing {
            let assembled = min(max(finalizationFraction, 0), 1)
            let fraction = Self.traversalSpan + (Self.finalizationCeiling - Self.traversalSpan) * assembled
            progressFraction = max(progressFraction, fraction)
            return
        }

        var traversalFraction = min(
            max(completedTraversalWeight + atomicSummaryCompletedTraversalWeight, 0),
            1
        )

        // The weight model overshoots in skewed trees (a directory's weight is split when
        // it is enumerated, before its true size is known). Cap it with a work-count
        // extrapolation: visited files and enumerated directories versus known remaining
        // items, the expected yield of the unenumerated frontier, and summary descendants.
        //
        // Apply the cap whenever discovered items remain unprocessed, not only when the
        // frontier still holds unenumerated directories. A large flat directory drains the
        // frontier to zero (no child subdirectories) while leaving thousands of discovered
        // files uncompleted; without this the weight estimate alone can leap near the
        // traversal ceiling before those files are scanned.
        //
        // A committed package counts as one represented node but can contain hundreds of
        // thousands of visited descendants. Extrapolate the cost of known unfinished
        // packages from completed and active summaries instead of treating every package
        // sibling as equal geometric work.
        let hasCountedWork = enumeratedDirectoryCount > 0
            || pendingPackageSummaryCount > 0
            || pendingAutoSummaryRepresentedItemCount > 0
            || activeAtomicSummaryCount > 0
        if hasCountedWork,
           (completedItems < discoveredItems
                || pendingDirectoryCount > 0
                || pendingPackageSummaryCount > 0
                || pendingAutoSummaryRepresentedItemCount > 0
                || activeAtomicSummaryCount > 0) {
            let enumerated = Double(max(enumeratedDirectoryCount, 0))
            let ordinaryDiscoveredItems = max(
                discoveredItems - pendingAutoSummaryRepresentedItemCount,
                0
            )
            let ordinaryDiscoveredDirectories = max(
                discoveredDirectoryCount - pendingAutoSummaryRepresentedDirectoryCount,
                0
            )
            let ordinaryPendingDirectories = max(
                pendingDirectoryCount - pendingAutoSummaryRepresentedDirectoryCount,
                0
            )
            let childrenPerDirectory = enumerated > 0
                ? Double(ordinaryDiscoveredItems) / enumerated
                : 0
            let subdirectoriesPerDirectory = enumerated > 0
                ? Double(ordinaryDiscoveredDirectories) / enumerated
                : 0
            let expansion = subdirectoriesPerDirectory < 1
                ? min(1 / (1 - subdirectoriesPerDirectory), Self.maxFrontierExpansion)
                : Self.maxFrontierExpansion
            let expectedFrontierYield = Double(ordinaryPendingDirectories)
                * childrenPerDirectory
                * expansion
            let completedWork = Double(max(completedItems, 0))
                + enumerated
                + Double(max(completedSummaryAdditionalVisitedItemCount, 0))
                + Double(max(atomicSummaryVisitedItems, 0))
            let ordinaryRemainingItems = max(
                Double(discoveredItems)
                    - Double(completedItems)
                    - enumerated
                    - Double(pendingPackageSummaryCount)
                    - Double(pendingAutoSummaryRepresentedItemCount),
                0
            )
            let completedPackageAverage = completedPackageSummaryCount > 0
                ? Double(completedPackageSummaryVisitedItemCount)
                    / Double(completedPackageSummaryCount)
                : 0
            let activePackageAverage = activePackageSummaryCount > 0
                ? (Double(activePackageSummaryVisitedItems)
                    + Double(activePackageSummaryEstimatedRemainingItems))
                    / Double(activePackageSummaryCount)
                : 0
            let estimatedPackageSize = max(
                completedPackageAverage,
                activePackageAverage,
                pendingPackageSummaryCount > activePackageSummaryCount
                    ? Double(Self.unobservedSummaryEstimatedItemCount)
                    : 0
            )
            let unregisteredPackageCount = max(
                pendingPackageSummaryCount - activePackageSummaryCount,
                0
            )
            let unregisteredPackageRemaining = Double(unregisteredPackageCount)
                * estimatedPackageSize
            let unregisteredAutoSummaryRemaining = Double(max(
                pendingAutoSummaryRepresentedItemCount
                    - activeAutoSummaryRepresentedItemCount,
                0
            ))
            let summaryRemaining = Double(max(atomicSummaryEstimatedRemainingItems, 0))
                + unregisteredPackageRemaining
                + unregisteredAutoSummaryRemaining
            let estimatedTotalWork = completedWork
                + ordinaryRemainingItems
                + expectedFrontierYield
                + summaryRemaining
            if estimatedTotalWork > 0 {
                traversalFraction = min(
                    traversalFraction,
                    min(completedWork / estimatedTotalWork, 1)
                )
            }
        }

        if estimatedTotalBytes > 0 {
            // Volume scans know the volume's used capacity up front; blending the byte
            // ratio in smooths the coarser weight-based estimate.
            let byteFraction = min(Double(bytesDiscovered) / Double(estimatedTotalBytes), 1)
            traversalFraction = (traversalFraction + byteFraction) / 2
        }

        let hasStarted = filesVisited > 0 || directoriesVisited > 0 || discoveredItems > 0
        let minimumVisibleProgress = hasStarted ? 0.01 : 0
        progressFraction = max(progressFraction, max(traversalFraction * Self.traversalSpan, minimumVisibleProgress))
    }
}

nonisolated enum ScanProgressEvent: Sendable {
    case executionMode(ScanExecutionMode)
    case progress(ScanMetrics)
    case warning(ScanWarning)
    case finished(ScanSnapshot)
}
