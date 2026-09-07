import SwiftUI

struct WorkspaceTourPromptView: View {
    let step: WorkspaceTourController.Step
    var showsFolderNavigation = false
    var showsCompletionButton = true
    let stop: () -> Void
    let advance: () -> Void

    var body: some View {
        if step != .scan {
            prompt
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if step == .markForReview {
                Text("You can also select an item and choose Inspect > Add to Discard Pile (⇧⌘L).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step != .finished || showsCompletionButton {
                HStack {
                    if step != .finished {
                        Button("Stop Tour", action: stop)
                            .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 12)
                    Button(actionTitle, action: advance)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch step {
        case .scan: ""
        case .selectResult: String(localized: "Explore the practice folder")
        case .openFolder:
            showsFolderNavigation ? String(localized: "Folder contents") : String(localized: "Open a folder")
        case .visualization: String(localized: "Switch the disk map")
        case .inspector: String(localized: "Show or hide details")
        case .search: String(localized: "Find a file")
        case .rescan: String(localized: "Refresh a scan")
        case .markForReview: String(localized: "Try the Discard Pile")
        case .review: String(localized: "Review the Discard Pile")
        case .removeMark: String(localized: "Remove an item")
        case .finished: String(localized: "Tour Complete")
        }
    }

    private var message: String {
        switch step {
        case .scan: ""
        case .selectResult:
            String(localized: "The map shows how your disk space is used. Selecting an item in the map or Contents highlights it in both.")
        case .openFolder:
            showsFolderNavigation
                ? String(localized: "The map and file list now show this folder’s contents. Use the path to return to a parent folder.")
                : String(localized: "Double-clicking a folder row opens its contents in both the map and the file list.")
        case .visualization:
            String(localized: "Sunburst uses rings; Treemap uses rectangles. Both show how your disk space is used.")
        case .inspector:
            String(localized: "The Inspector shows details about the selected item. This button shows or hides it.")
        case .search:
            String(localized: "Search by name in Current Contents or across the Entire Scan.")
        case .rescan:
            String(localized: "Rescan updates the current folder. Rescan Entire Scan in the File menu refreshes everything.")
        case .markForReview:
            String(localized: "Drag a sample file or folder from the map or Contents to the Discard Pile. This marks it for review without moving or deleting it.")
        case .review:
            String(localized: "Click Discard Pile to review the items you added.")
        case .removeMark:
            String(localized: "The minus (–) button removes an item from the Discard Pile. It reappears in the folder view and is no longer marked for deletion.")
        case .finished:
            String(localized: "Choose Done to finish the tour and explore your own files.")
        }
    }

    private var actionTitle: String {
        switch step {
        case .markForReview, .review: String(localized: "Skip Exercise")
        case .finished: String(localized: "Done")
        default: String(localized: "Next")
        }
    }
}
