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

    let selectedTarget: ScanTarget?
    let actions: WorkspaceActions

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ProgressView(value: scanProgressFraction, total: 1)
                    .frame(width: 260)

                Text(scanProgressLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Scanning \(selectedTarget?.displayName ?? "Location")")
                .font(.title3.weight(.semibold))

            Text(progress.metrics.currentPath)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            Text("\(progress.metrics.filesVisited) files, \(progress.metrics.directoriesVisited) folders")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Stop Scan") {
                actions.stopScan()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isFinalizingScan: Bool {
        progress.metrics.isFinalizing
    }

    private var scanProgressFraction: Double {
        progress.metrics.progressFraction
    }

    private var scanProgressLabel: String {
        if isFinalizingScan {
            return "Finishing \(progress.metrics.progressPercentage.formatted(.number))%"
        }
        return progress.metrics.progressPercentage.formatted(.number) + "%"
    }
}
