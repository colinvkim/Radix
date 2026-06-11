import SwiftUI

struct InspectorNoSelectionView: View {
    let scanWarningsPreview: [ScanWarning]
    let shouldSuggestFullDiskAccess: Bool
    let openFullDiskAccessSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.trailing")
            } description: {
                Text("Select a chart segment or table row to inspect metadata and file actions.")
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)

            if !scanWarningsPreview.isEmpty {
                Divider()

                Form {
                    InspectorWarningsSection(
                        warnings: scanWarningsPreview,
                        shouldSuggestFullDiskAccess: shouldSuggestFullDiskAccess,
                        openFullDiskAccessSettings: openFullDiskAccessSettings
                    )
                }
                .formStyle(.grouped)
                .frame(maxHeight: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
