import AppKit
import SwiftUI

struct PermissionBanner: View {
    let actions: WorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Protected folders were skipped.")
                    .font(.headline)

                Text("Grant Full Disk Access for more complete scans of Mail, Safari, Messages, and Library content.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Full Disk Access") {
                actions.openFullDiskAccessSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
