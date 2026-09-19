import SwiftUI

struct InspectorWarningsSection: View {
    let selectionName: String
    let warnings: [ScanWarning]
    let fullDiskAccessAdvice: FullDiskAccessAdvice
    let openFullDiskAccessSettings: () -> Void

    @State private var showsWarnings = false

    var body: some View {
        let presentation = ScanWarningPresentation(
            selectionName: selectionName,
            warnings: warnings,
            fullDiskAccessAdvice: fullDiskAccessAdvice
        )

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(presentation.noticeTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                Text(presentation.noticeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(presentation.showWarningsTitle) {
                    showsWarnings.toggle()
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
                .popover(isPresented: $showsWarnings, arrowEdge: .trailing) {
                    ScanWarningsPopover(
                        presentation: presentation,
                        openFullDiskAccessSettings: openFullDiskAccessSettings
                    )
                }
            }
        }
    }
}
