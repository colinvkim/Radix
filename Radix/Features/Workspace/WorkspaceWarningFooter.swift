import AppKit
import SwiftUI

struct WarningFooter: View {
    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let actions: WorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(warnings.count) locations had limited access or scan warnings.")
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}
