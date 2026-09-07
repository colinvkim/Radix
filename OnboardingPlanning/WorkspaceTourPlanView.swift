import SwiftUI

// A planning note at the onboarding exit, not another onboarding screen or a
// replica workspace. The production tour attaches to the actual Radix controls.
struct WorkspaceTourPlanView: View {
    let startsTour: Bool
    let usesDefaultAction: Bool
    let returnToChoice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("Planning note", tableName: "Planning")
            } icon: {
                Image(systemName: "pencil.and.outline")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Continue in Radix’s workspace", tableName: "Planning")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        startsTour
                            ? "This planner ends at the handoff. The tour will use the real workspace, with prompts beside the controls the user is learning."
                            : "The workspace opens without a tour. The user can start it later from Help.",
                        tableName: "Planning"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if startsTour {
                        tourStop("Start with sample files", symbol: "folder.badge.plus", detail: "Create and scan a temporary Practice Folder automatically before showing the first tip.")
                        tourStop("Explain controls in place", symbol: "cursorarrow.click", detail: "Use short prompts beside the disk map, view switcher, search, and inspector.")
                        tourStop("Practice dragging", symbol: "arrow.down.right", detail: "Point to the Discard Pile. Advance after a sample file or folder is added from the map or Contents.")
                        tourStop("Review the Discard Pile", symbol: "checklist", detail: "Open the Discard Pile sheet. Explain the minus button, then use Next to continue.")
                        Text("Informational tips advance with Next. Adding items and opening the Discard Pile advance the exercise. The user can stop at any time.", tableName: "Planning")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(action: returnToChoice) {
                    Text("Back to Tour Choice", tableName: "Planning")
                }
                .keyboardShortcut(usesDefaultAction ? .defaultAction : nil)
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tourStop(_ title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title, tableName: "Planning").font(.headline)
                Text(detail, tableName: "Planning")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
