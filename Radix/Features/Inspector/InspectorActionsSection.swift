import SwiftUI

struct InspectorActionsSection: View {
    let availability: FileNodeActionAvailability
    let canExpandSummarizedSelection: Bool
    let canZoomIntoSelection: Bool
    let fileActions: SelectedFileActions
    let addToDiscardPile: () -> Void
    let expandAction: () -> Void
    let zoomAction: () -> Void

    var body: some View {
        Section("Actions") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    fileActions.perform(.quickLook)
                } label: {
                    Label(FileNodeAction.quickLook.title, systemImage: FileNodeAction.quickLook.systemImageName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!FileNodeAction.quickLook.isEnabled(in: availability))

                Button {
                    fileActions.perform(.revealInFinder)
                } label: {
                    Label(FileNodeAction.revealInFinder.title, systemImage: FileNodeAction.revealInFinder.systemImageName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!FileNodeAction.revealInFinder.isEnabled(in: availability))

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

                Button {
                    addToDiscardPile()
                } label: {
                    Label("Add to Discard Pile", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!availability.canMoveToTrash)

                Button(role: .destructive) {
                    fileActions.perform(.moveToTrash)
                } label: {
                    Label(FileNodeAction.moveToTrash.title, systemImage: FileNodeAction.moveToTrash.systemImageName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!FileNodeAction.moveToTrash.isEnabled(in: availability))
            }
            .controlSize(.regular)
        }
    }

    private var openButton: some View {
        Button {
            fileActions.perform(.open)
        } label: {
            Label(FileNodeAction.open.title, systemImage: FileNodeAction.open.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!FileNodeAction.open.isEnabled(in: availability))
    }

    private var copyPathButton: some View {
        Button {
            fileActions.perform(.copyPath)
        } label: {
            Label(FileNodeAction.copyPath.title, systemImage: FileNodeAction.copyPath.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!FileNodeAction.copyPath.isEnabled(in: availability))
    }
}
