import SwiftUI

struct InspectorActionsSection: View {
    let availability: FileNodeActionAvailability
    let canExpandSummarizedSelection: Bool
    let canZoomIntoSelection: Bool
    let quickLookAction: () -> Void
    let revealAction: () -> Void
    let expandAction: () -> Void
    let zoomAction: () -> Void
    let openAction: () -> Void
    let copyPathAction: () -> Void
    let trashAction: () -> Void

    var body: some View {
        Section("Actions") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    quickLookAction()
                } label: {
                    Label("Quick Look", systemImage: RadixSystemImages.quickLook)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!availability.canPreviewWithQuickLook)

                Button {
                    revealAction()
                } label: {
                    Label("Reveal in Finder", systemImage: RadixSystemImages.revealInFinder)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!availability.canRevealInFinder)

                if canExpandSummarizedSelection {
                    Button {
                        expandAction()
                    } label: {
                        Label("Expand Fully", systemImage: "arrowshape.turn.up.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if canZoomIntoSelection {
                    Button {
                        zoomAction()
                    } label: {
                        Label("Zoom Into Folder", systemImage: "plus.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        openButton
                        copyPathButton
                    }

                    VStack(spacing: 8) {
                        openButton
                        copyPathButton
                    }
                }

                Button(role: .destructive) {
                    trashAction()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!availability.canMoveToTrash)
            }
            .controlSize(.regular)
        }
    }

    private var openButton: some View {
        Button {
            openAction()
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!availability.canOpen)
    }

    private var copyPathButton: some View {
        Button {
            copyPathAction()
        } label: {
            Label("Copy Path", systemImage: RadixSystemImages.copyPath)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!availability.canCopyPath)
    }
}
