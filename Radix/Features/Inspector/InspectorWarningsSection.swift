import SwiftUI

struct InspectorWarningsSection: View {
    let warnings: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        Section("Warnings") {
            ForEach(warnings) { warning in
                VStack(alignment: .leading, spacing: 4) {
                    Label(warning.path, systemImage: warning.category.symbolName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if shouldSuggestFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    openFullDiskAccessSettings()
                }
            }
        }
    }
}
