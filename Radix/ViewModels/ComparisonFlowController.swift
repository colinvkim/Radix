import Foundation

@MainActor
final class ComparisonFlowController {
    var onChange: (() -> Void)?

    private(set) var scanComparison: ScanComparison? {
        didSet { notifyChanged() }
    }

    var pendingComparisonSetup: ScanComparisonSetup? {
        didSet { notifyChanged() }
    }

    init(
        scanComparison: ScanComparison? = nil,
        pendingComparisonSetup: ScanComparisonSetup? = nil
    ) {
        self.scanComparison = scanComparison
        self.pendingComparisonSetup = pendingComparisonSetup
    }

    func setScanComparison(_ comparison: ScanComparison?) {
        scanComparison = comparison
    }

    var hasPendingSetup: Bool {
        pendingComparisonSetup != nil
    }

    enum SetupConfirmationOutcome {
        case confirmed(ScanComparisonSetup)
        case validationFailed
        case staleCurrentSnapshot
        case noPendingSetup
    }

    func swapPendingSetup() {
        guard var setup = pendingComparisonSetup else { return }
        setup.swap()
        setup.errorMessage = setup.validationMessage
        pendingComparisonSetup = setup
    }

    @discardableResult
    func clearPendingSetup() -> Bool {
        guard pendingComparisonSetup != nil else { return false }
        pendingComparisonSetup = nil
        return true
    }

    func confirmPendingSetup(currentLiveSnapshotID: UUID?) -> SetupConfirmationOutcome {
        guard let setup = pendingComparisonSetup else { return .noPendingSetup }
        guard setup.canCompare else {
            var updatedSetup = setup
            updatedSetup.errorMessage = setup.validationMessage ?? String(
                localized: "Choose two scans to compare.",
                comment: "Error shown when confirming a comparison with missing scans."
            )
            pendingComparisonSetup = updatedSetup
            return .validationFailed
        }
        if let currentSnapshotID = setup.currentSnapshotID,
           currentLiveSnapshotID != currentSnapshotID {
            pendingComparisonSetup = nil
            return .staleCurrentSnapshot
        }

        pendingComparisonSetup = nil
        return .confirmed(setup)
    }

    func clearComparisonSlot(_ slot: ScanComparisonSlot) {
        guard var setup = pendingComparisonSetup else { return }
        setup.setCandidate(nil, for: slot)
        setup.errorMessage = nil
        pendingComparisonSetup = setup
    }

    func assignCurrentSnapshot(
        _ snapshot: ScanSnapshot?,
        for slot: ScanComparisonSlot,
        isEligible: Bool
    ) {
        guard var setup = pendingComparisonSetup else { return }
        guard isEligible, let snapshot else {
            setup.errorMessage = String(
                localized: "Complete a live scan before using it in a comparison.",
                comment: "Error shown when the current scan cannot be used for comparison."
            )
            pendingComparisonSetup = setup
            return
        }
        setup.setCandidate(ScanComparisonCandidate(snapshot: snapshot), for: slot)
        setup.errorMessage = setup.validationMessage
        pendingComparisonSetup = setup
    }

    struct PreviewBeginInfo {
        let setupID: UUID
    }

    func beginPreview(
        from sourceURL: URL,
        for slot: ScanComparisonSlot,
        savedScanExtension: String?
    ) -> PreviewBeginInfo? {
        guard var setup = pendingComparisonSetup,
              setup.loadingSlot == nil else {
            return nil
        }
        if let savedScanExtension,
           sourceURL.pathExtension.lowercased() != savedScanExtension {
            setup.errorMessage = String(
                localized: "Drop a .\(savedScanExtension) saved scan.",
                comment: "Error shown when a dropped file is not a saved scan archive."
            )
            pendingComparisonSetup = setup
            return nil
        }

        let info = PreviewBeginInfo(setupID: setup.id)
        setup.loadingSlot = slot
        setup.errorMessage = nil
        setup.setCandidate(nil, for: slot)
        pendingComparisonSetup = setup
        return info
    }

    @discardableResult
    func applyPreview(
        _ preview: ScanArchivePreview,
        info: PreviewBeginInfo
    ) -> Bool {
        guard var setup = pendingComparisonSetup,
              setup.id == info.setupID,
              let loadedSlot = setup.loadingSlot else {
            return false
        }
        setup.setCandidate(ScanComparisonCandidate(preview: preview), for: loadedSlot)
        setup.loadingSlot = nil
        setup.errorMessage = setup.validationMessage
        pendingComparisonSetup = setup
        return true
    }

    @discardableResult
    func failPreview(info: PreviewBeginInfo, message: String) -> Bool {
        guard var setup = pendingComparisonSetup,
              setup.id == info.setupID else {
            return false
        }
        setup.loadingSlot = nil
        setup.errorMessage = message
        pendingComparisonSetup = setup
        return true
    }

    @discardableResult
    func clearLoadingSlot(info: PreviewBeginInfo) -> Bool {
        guard var setup = pendingComparisonSetup,
              setup.id == info.setupID,
              setup.loadingSlot != nil else {
            return false
        }
        setup.loadingSlot = nil
        pendingComparisonSetup = setup
        return true
    }

    private func notifyChanged() {
        onChange?()
    }
}
