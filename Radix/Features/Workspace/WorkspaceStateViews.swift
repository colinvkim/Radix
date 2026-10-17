import Combine
import Foundation
import SwiftUI

struct EmptyWorkspaceState: View {
    let startupDiskTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Choose a Folder or Disk")
                    .font(.title2.weight(.semibold))

                Text("Start from the sidebar, drop a folder into the window, or choose a location manually.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button("Choose Folder…") {
                    actions.chooseFolder()
                }
                .buttonStyle(.borderedProminent)

                if let startupDiskTarget {
                    Button("Scan \(startupDiskTarget.sidebarTitle)") {
                        actions.startScan(startupDiskTarget)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningWorkspaceState: View {
    @ObservedObject var progress: ScanProgressState
    @StateObject private var throttledItemCounts = ThrottledScanItemCounts()
    @State private var isFallbackExplanationPresented = false

    let selectedTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                if isPreparingIncremental {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 260)
                } else {
                    ProgressView(value: scanProgressFraction, total: 1)
                        .frame(width: 260)

                    Text(progressPercentageText)
                        .contentTransition(
                            .numericText(value: Double(progress.metrics.progressPercentage))
                        )
                        .animation(
                            .easeOut(duration: 0.2),
                            value: progress.metrics.progressPercentage
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text(scanTitle)
                    .font(.title3.weight(.semibold))

                if let fallbackCategory {
                    Button {
                        isFallbackExplanationPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Why Radix is performing a complete scan")
                    .accessibilityLabel("Why Radix is performing a complete scan")
                    .popover(isPresented: $isFallbackExplanationPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Why a complete scan?")
                                .font(.headline)
                            Text(fallbackCategory.userFacingCause)
                            Text("Radix is scanning the entire location to ensure accurate results.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(16)
                        .frame(width: 310, alignment: .leading)
                    }
                }
            }

            if !isPreparingIncremental {
                ScanCurrentPathText(
                    path: progress.metrics.currentPath,
                    isFinalizing: isFinalizingScan
                )

                Text(itemCountText)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: throttledItemCounts.counts)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Stop Scan") {
                actions.stopScan()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            throttledItemCounts.bind(to: progress)
        }
        .onDisappear {
            throttledItemCounts.cancel()
        }
        .onChange(of: progress.executionMode) { _, mode in
            if case .some(.fullFallback) = mode {
                throttledItemCounts.bind(to: progress)
            }
        }
    }

    private var isFinalizingScan: Bool {
        progress.metrics.isFinalizing
    }

    private var scanProgressFraction: Double {
        progress.metrics.progressFraction
    }

    private var progressPercentageText: String {
        let fraction = Double(progress.metrics.progressPercentage) / 100
        let percentage = fraction.formatted(
            .percent.precision(.fractionLength(0))
        )
        guard isFinalizingScan else { return percentage }
        return String(
            localized: "Finishing \(percentage)",
            comment: "Progress percentage shown while a scan is finalizing."
        )
    }

    private var itemCountText: String {
        let files = String(
            localized: "\(throttledItemCounts.counts.filesVisited) files",
            comment: "File count shown while scanning."
        )
        let folders = String(
            localized: "\(throttledItemCounts.counts.directoriesVisited) folders",
            comment: "Folder count shown while scanning."
        )
        return String(
            localized: "\(files), \(folders)",
            comment: "Scan progress summary containing localized file and folder counts."
        )
    }

    private var scanTitle: String {
        let targetName = selectedTarget?.displayName ?? String(localized: "Location")
        switch progress.executionMode {
        case .some(.preparingIncremental):
            return String(
                localized: "Checking for changes in \(targetName)",
                comment: "Progress title while Radix prepares an incremental rescan."
            )
        case .some(.incremental), .some(.incrementalNoChanges):
            return String(
                localized: "Rescanning changes in \(targetName)",
                comment: "Progress title for an incremental rescan of a location."
            )
        case .some(.fullFallback):
            return String(
                localized: "Scanning all of \(targetName)",
                comment: "Progress title when an incremental rescan safely falls back to scanning the entire location."
            )
        case .some(.full), .none:
            return String(
                localized: "Scanning \(targetName)",
                comment: "Progress title showing the current scan target."
            )
        }
    }

    private var isPreparingIncremental: Bool {
        progress.executionMode == .preparingIncremental
    }

    private var fallbackCategory: ScanFallbackCategory? {
        if case .some(.fullFallback(let reason)) = progress.executionMode {
            return reason.presentationCategory
        }
        return nil
    }
}

struct ScanCompletionNoticeBanner: View {
    let notice: ScanCompletionNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .topBannerSurface()
    }

    private var title: String {
        switch notice {
        case .incrementalUpdated:
            return String(localized: "Scan updated from recent changes")
        case .noChanges:
            return String(localized: "No changes since the previous scan")
        case .fullFallback:
            return String(localized: "Complete rescan finished")
        case .folderUpdated(let name):
            return String(
                localized: "\(name) updated",
                comment: "Confirmation shown after one folder was refreshed inside an existing scan."
            )
        }
    }

    private var detail: String? {
        guard case .fullFallback(let reason) = notice else { return nil }
        let result = String(
            localized: "Radix scanned the entire location.",
            comment: "Result shown after an incremental rescan safely completed as a full scan."
        )
        return "\(reason.presentationCategory.userFacingCause) \(result)"
    }

    private var iconName: String {
        if case .fullFallback = notice {
            return "info.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if case .fullFallback = notice {
            return .orange
        }
        return .green
    }
}

struct BackgroundRefreshPausedBanner: View {
    let rescan: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Refresh this folder manually")
                    .font(.subheadline.weight(.semibold))
                Text("Automatic refresh could not safely update this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Rescan Entire Scan", action: rescan)
                .buttonStyle(.borderless)
        }
        .topBannerSurface()
    }
}

struct FolderRescanProgressBanner: View {
    let state: FolderRescanState
    @ObservedObject var progress: ScanProgressState
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.metrics.progressFraction, total: 1)
                .frame(width: 96)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "Rescanning \(state.nodeName)",
                    comment: "Progress banner title while refreshing one folder inside an existing scan."
                )
                .font(.subheadline.weight(.semibold))

                Text(progressDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Cancel")
        }
        .topBannerSurface()
    }

    private var progressDetail: String {
        if let currentName = progress.metrics.currentItemName {
            return currentName
        }
        return String(
            localized: "Preparing folder scan",
            comment: "Progress detail before a focused folder rescan reports its current item."
        )
    }
}

extension ScanFallbackCategory {
    var userFacingCause: String {
        switch self {
        case .settingsChanged:
            return String(localized: "Scan settings changed.")
        case .historyUnavailable:
            return String(localized: "Recent file history isn’t available.")
        case .tooManyChanges:
            return String(localized: "Too much changed for a quick rescan.")
        case .locationChanged:
            return String(localized: "The scan location changed while Radix was checking it.")
        case .volumeAccounting:
            return String(localized: "Disk rescans need a complete scan to keep storage totals accurate.")
        case .previousScanUnavailable:
            return String(localized: "The previous scan can’t be safely reused.")
        case .incrementalUpdateFailed:
            return String(localized: "Radix couldn’t safely apply the recent changes.")
        }
    }
}

private struct ScanItemCounts: Equatable {
    var filesVisited = 0
    var directoriesVisited = 0

    init() {}

    init(metrics: ScanMetrics) {
        filesVisited = metrics.filesVisited
        directoriesVisited = metrics.directoriesVisited
    }
}

private struct ScanCurrentPathText: View {
    private static let finalizingSummary = String(localized: "Summarizing results…", comment: "Progress text shown while a scan is finalizing.")

    let path: String
    let isFinalizing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(path)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2, reservesSpace: true)
            .truncationMode(.middle)
            .frame(maxWidth: 540)
            .overlay {
                if shouldShimmer {
                    ShimmeringTextHighlight(
                        text: path,
                        lineLimit: 2,
                        reservesSpace: true,
                        multilineTextAlignment: .center,
                        truncationMode: .middle,
                        frameAlignment: .center
                    )
                }
            }
    }

    private var shouldShimmer: Bool {
        isFinalizing && path == Self.finalizingSummary && !reduceMotion
    }
}

@MainActor
private final class ThrottledScanItemCounts: ObservableObject {
    @Published private(set) var counts = ScanItemCounts()

    private let updateInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(325)
    private var cancellable: AnyCancellable?

    func bind(to progress: ScanProgressState) {
        cancel()
        counts = ScanItemCounts(metrics: progress.metrics)

        cancellable = progress.$metrics
            .map(ScanItemCounts.init(metrics:))
            .removeDuplicates()
            .throttle(for: updateInterval, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] counts in
                self?.counts = counts
            }
    }

    func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }
}
