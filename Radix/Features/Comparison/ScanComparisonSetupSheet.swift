import SwiftUI

struct ScanComparisonSetupSheet: View {
    let setup: ScanComparisonSetup
    let canUseCurrentScan: Bool
    let onChooseSnapshot: (ScanComparisonSlot) -> Void
    let onDropSnapshot: (URL, ScanComparisonSlot) -> Void
    let onUseCurrentScan: (ScanComparisonSlot) -> Void
    let onClear: (ScanComparisonSlot) -> Void
    let onSwap: () -> Void
    let onCancel: () -> Void
    let onCompare: () -> Void

    private var isBusy: Bool {
        setup.loadingSlot != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Scans")
                    .font(.title3.weight(.semibold))

                Text("Choose two scans of the same location. Coverage differences will be identified.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                ScanComparisonCandidateGroup(
                    slot: .before,
                    candidate: setup.before,
                    isLoading: setup.loadingSlot == .before,
                    canUseCurrentScan: canUseCurrentScan && setup.canAssignCurrentScan(to: .before),
                    actionsDisabled: isBusy,
                    onChooseSnapshot: onChooseSnapshot,
                    onDropSnapshot: onDropSnapshot,
                    onUseCurrentScan: onUseCurrentScan,
                    onClear: onClear
                )

                Button {
                    onSwap()
                } label: {
                    Label("Swap Earlier and Later", systemImage: "arrow.left.arrow.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(isBusy || (setup.before == nil && setup.after == nil))
                .help("Swap Earlier and Later")

                ScanComparisonCandidateGroup(
                    slot: .after,
                    candidate: setup.after,
                    isLoading: setup.loadingSlot == .after,
                    canUseCurrentScan: canUseCurrentScan && setup.canAssignCurrentScan(to: .after),
                    actionsDisabled: isBusy,
                    onChooseSnapshot: onChooseSnapshot,
                    onDropSnapshot: onDropSnapshot,
                    onUseCurrentScan: onUseCurrentScan,
                    onClear: onClear
                )
            }
            .padding(20)

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let blockingMessage = setup.errorMessage ?? setup.validationMessage {
                        Label(blockingMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if let coverageWarningMessage = setup.coverageWarningMessage {
                        Label(coverageWarningMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .frame(maxWidth: 430, alignment: .leading)

                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Compare") {
                    onCompare()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.canCompare)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 780)
    }
}

private struct ScanComparisonCandidateGroup: View {
    let slot: ScanComparisonSlot
    let candidate: ScanComparisonCandidate?
    let isLoading: Bool
    let canUseCurrentScan: Bool
    let actionsDisabled: Bool
    let onChooseSnapshot: (ScanComparisonSlot) -> Void
    let onDropSnapshot: (URL, ScanComparisonSlot) -> Void
    let onUseCurrentScan: (ScanComparisonSlot) -> Void
    let onClear: (ScanComparisonSlot) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        GroupBox {
            Group {
                if isLoading {
                    loadingContent
                } else if let candidate {
                    candidateContent(candidate)
                } else {
                    emptyContent
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 170,
                maxHeight: 170,
                alignment: .topLeading
            )
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(isDropTargeted ? 0.1 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        Color.accentColor.opacity(isDropTargeted ? 0.9 : 0),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !actionsDisabled, let sourceURL = urls.first else { return false }
                onDropSnapshot(sourceURL, slot)
                return true
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted && !actionsDisabled
            }
        } label: {
            HStack(spacing: 8) {
                Text(slot.title)
                    .font(.headline)

                if candidate?.isCurrentScan == true {
                    Label("Current Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No Snapshot Selected")
                .font(.subheadline.weight(.medium))

            Text(emptyStateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("or drop a saved scan here")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            sourceActions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingContent: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Reading Snapshot…")
                .font(.subheadline.weight(.medium))

            Text("Validating snapshot contents")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateContent(_ candidate: ScanComparisonCandidate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(candidate.path)
            }

            Label(
                "Scanned \(RadixFormatters.date(candidate.scanDate))",
                systemImage: "clock"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 28) {
                metric("Size", RadixFormatters.size(candidate.totalAllocatedSize))
                metric("Files", candidate.fileCount.formatted())
                metric("Folders", candidate.directoryCount.formatted())

                if candidate.warningCount > 0 {
                    metric("Warnings", candidate.warningCount.formatted())
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                selectedControls(for: candidate)
            }
        }
    }

    private var emptyStateMessage: String {
        canUseCurrentScan
            ? String(localized: "Choose a saved scan or use the current scan.", comment: "Empty comparison slot guidance when the current scan is available.")
            : String(localized: "Choose a saved scan.", comment: "Empty comparison slot guidance when only saved scans are available.")
    }

    private var sourceActions: some View {
        HStack(spacing: 8) {
            Button("Choose Saved Scan…") {
                onChooseSnapshot(slot)
            }

            if canUseCurrentScan {
                Button("Use Current Scan") {
                    onUseCurrentScan(slot)
                }
            }
        }
        .controlSize(.small)
        .disabled(actionsDisabled)
    }

    private func selectedControls(for candidate: ScanComparisonCandidate) -> some View {
        HStack(spacing: 8) {
            Button("Replace…") {
                onChooseSnapshot(slot)
            }

            if canUseCurrentScan, !candidate.isCurrentScan {
                Button {
                    onUseCurrentScan(slot)
                } label: {
                    Label(
                        "Use Current Scan for \(slot.title)",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                .labelStyle(.iconOnly)
                .help("Use Current Scan")
            }

            Button {
                onClear(slot)
            } label: {
                Label("Clear \(slot.title)", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Clear \(slot.title)")
        }
        .controlSize(.small)
        .disabled(actionsDisabled)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
