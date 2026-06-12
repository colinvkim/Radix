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

    let selectedTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ProgressView(value: scanProgressFraction, total: 1)
                    .frame(width: 260)

                HStack(spacing: 0) {
                    if isFinalizingScan {
                        Text("Finishing ")
                    }

                    ScanProgressNumberText(value: progress.metrics.progressPercentage)

                    Text("%")
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Text("Scanning \(selectedTarget?.displayName ?? "Location")")
                .font(.title3.weight(.semibold))

            Text(progress.metrics.currentPath)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .frame(maxWidth: 540)

            HStack(spacing: 0) {
                ScanProgressNumberText(value: throttledItemCounts.counts.filesVisited)
                Text(" files, ")
                ScanProgressNumberText(value: throttledItemCounts.counts.directoriesVisited)
                Text(" folders")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

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
    }

    private var isFinalizingScan: Bool {
        progress.metrics.isFinalizing
    }

    private var scanProgressFraction: Double {
        progress.metrics.progressFraction
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

private struct ScanProgressNumberText: View {
    let value: Int

    var body: some View {
        Text(value.formatted(.number))
            .contentTransition(.numericText(value: Double(value)))
            .animation(.easeOut(duration: 0.2), value: value)
    }
}
