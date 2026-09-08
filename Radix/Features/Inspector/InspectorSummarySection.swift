import SwiftUI

struct InspectorSummarySection: View {
    let node: FileNodeRecord
    let availability: FileNodeActionAvailability
    let allowsMoveToTrash: Bool
    let actions: SelectedFileActions

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.systemImageName)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayName)
                        .font(.headline)
                        .lineLimit(2)

                    if node.isSynthetic {
                        Text("Estimated storage that macOS reports as used but that Radix could not attribute to a regular file path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(node.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(node.url.path)
                    }
                }

                Spacer(minLength: 4)

                if showsMoreMenu {
                    Menu {
                        if availability.canOpen {
                            Button(
                                FileNodeAction.open.title,
                                systemImage: FileNodeAction.open.systemImageName
                            ) {
                                actions.perform(.open)
                            }
                        }

                        if availability.canCopyPath {
                            Button(
                                FileNodeAction.copyPath.title,
                                systemImage: FileNodeAction.copyPath.systemImageName
                            ) {
                                actions.perform(.copyPath)
                            }
                        }

                        if availability.canMoveToTrash && allowsMoveToTrash {
                            Divider()

                            Button(
                                FileNodeAction.moveToTrash.title,
                                systemImage: FileNodeAction.moveToTrash.systemImageName,
                                role: .destructive
                            ) {
                                actions.perform(.moveToTrash)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More Actions")
                    .accessibilityLabel("More Actions")
                }
            }
        }
    }

    private var showsMoreMenu: Bool {
        availability.canOpen
            || availability.canCopyPath
            || (availability.canMoveToTrash && allowsMoveToTrash)
    }
}
