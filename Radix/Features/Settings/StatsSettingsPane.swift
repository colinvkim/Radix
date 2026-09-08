import SwiftUI

struct StatsSettingsPane: View {
    private static let emptyValueText = "—"

    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            if appModel.usageStats.totalScansRun == 0 {
                StatsEmptyState {
                    appModel.presentOpenPanelAndScan()
                }
            } else {
                Section {
                    SpaceExploredHero(
                        bytes: appModel.usageStats.totalBytesScanned,
                        emptyValueText: Self.emptyValueText
                    )
                }

                Section("Scanning") {
                    StatValueRow(
                        String(
                            localized: "Scans run",
                            comment: "Stats pane label for the total number of scans run."
                        ),
                        value: countText(appModel.usageStats.totalScansRun)
                    )
                    StatValueRow(
                        String(
                            localized: "Largest scan",
                            comment: "Stats pane label for the largest scan by size."
                        ),
                        value: sizeText(appModel.usageStats.largestScanBytes)
                    )
                    StatValueRow(
                        String(
                            localized: "Average scan speed",
                            comment: "Stats pane label for the average scan throughput."
                        ),
                        value: rateText(appModel.usageStats.averageScanBytesPerSecond)
                    )
                    StatValueRow(
                        String(
                            localized: "Fastest scan speed",
                            comment: "Stats pane label for the fastest scan throughput."
                        ),
                        value: rateText(appModel.usageStats.fastestScanBytesPerSecond)
                    )
                }

                Section("Interaction") {
                    StatValueRow(
                        String(
                            localized: "Sunburst segments clicked",
                            comment: "Stats pane label for how often sunburst segments were clicked."
                        ),
                        value: countText(appModel.usageStats.sunburstSegmentsClicked)
                    )
                }

                Section("Trash") {
                    StatValueRow(
                        String(
                            localized: "Files deleted",
                            comment: "Stats pane label for the number of files moved to Trash."
                        ),
                        value: countText(appModel.usageStats.filesDeleted)
                    )
                    StatValueRow(
                        String(
                            localized: "Folders deleted",
                            comment: "Stats pane label for the number of folders moved to Trash."
                        ),
                        value: countText(appModel.usageStats.foldersDeleted)
                    )
                    StatValueRow(
                        String(
                            localized: "Bytes moved to Trash",
                            comment: "Stats pane label for the total bytes moved to Trash."
                        ),
                        value: sizeText(appModel.usageStats.bytesMovedToTrash)
                    )
                    StatValueRow(
                        String(
                            localized: "Largest trash move",
                            comment: "Stats pane label for the largest single move to Trash."
                        ),
                        value: sizeText(appModel.usageStats.largestTrashMoveBytes)
                    )
                }
            }

            Section("Local Data") {
                Text("Stats are stored locally on this Mac. Radix records aggregate counts and sizes only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func countText(_ value: Int) -> String {
        guard value > 0 else { return Self.emptyValueText }
        return value.formatted()
    }

    private func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return Self.emptyValueText }
        return RadixFormatters.size(bytes)
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return Self.emptyValueText
        }

        return sizeText(Int64(bytesPerSecond.rounded())) + "/s"
    }
}

private struct StatsEmptyState: View {
    let startScan: () -> Void

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)

                VStack(spacing: 4) {
                    Text("No Stats Yet")
                        .font(.headline)

                    Text("Run your first scan to start building local usage stats.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Start First Scan") {
                    startScan()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}

private struct SpaceExploredHero: View {
    let bytes: Int64
    let emptyValueText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedBytes: Int64 = 0

    private var valueText: String {
        guard displayedBytes > 0 else { return emptyValueText }
        return RadixFormatters.size(displayedBytes)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("Space explored")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(valueText)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(displayedBytes)))
                    .animation(.easeOut(duration: 0.18), value: displayedBytes)
                    .accessibilityLabel("Space explored")
                    .accessibilityValue(valueText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .task(id: bytes) {
            await animateDisplayedBytes(to: bytes)
        }
    }

    @MainActor
    private func animateDisplayedBytes(to targetBytes: Int64) async {
        let targetBytes = max(0, targetBytes)
        guard !reduceMotion else {
            displayedBytes = targetBytes
            return
        }

        let startBytes = displayedBytes
        guard startBytes != targetBytes else { return }
        guard targetBytes > 0 else {
            withAnimation(.easeOut(duration: 0.18)) {
                displayedBytes = 0
            }
            return
        }

        let frameCount = 36
        let frameDelay = Duration.milliseconds(18)
        for frame in 1...frameCount {
            do {
                try await Task.sleep(for: frameDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            let progress = Double(frame) / Double(frameCount)
            let easedProgress = 1 - pow(1 - progress, 3)
            let interpolatedBytes = Double(startBytes) + (Double(targetBytes - startBytes) * easedProgress)
            withAnimation(.easeOut(duration: 0.18)) {
                displayedBytes = max(0, Int64(interpolatedBytes.rounded()))
            }
        }

        withAnimation(.easeOut(duration: 0.18)) {
            displayedBytes = targetBytes
        }
    }
}

private struct StatValueRow: View {
    private let title: String
    private let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
