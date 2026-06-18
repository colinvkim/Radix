import AppKit
import SwiftUI

struct WarningFooter: View {
    let warnings: [ScanWarning]
    let fullDiskAccessStatus: FullDiskAccessStatus
    let shouldSuggestFullDiskAccess: Bool
    let actions: WorkspaceActions
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                Text(warnings.first?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if shouldSuggestFullDiskAccess {
                Button("Open Full Disk Access") {
                    actions.openFullDiskAccessSettings()
                }
            } else {
                Button("Dismiss") {
                    onDismiss()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var summary: String {
        // When access is already granted, the remaining warnings are system
        // locations macOS protects regardless of Full Disk Access, so avoid
        // implying the user can resolve them.
        if fullDiskAccessStatus == .granted {
            return "\(warnings.count) system locations are protected by macOS and were skipped."
        }
        return "\(warnings.count) locations had limited access or scan warnings."
    }
}
