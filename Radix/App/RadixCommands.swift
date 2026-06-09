import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(scanState.isScanning)

            Button("Rescan", systemImage: "arrow.clockwise") {
                appModel.rescan()
            }
            .keyboardShortcut("r")
            .disabled(!scanState.canRescan)

            Button("Stop Scan", systemImage: "stop") {
                appModel.stopScan()
            }
            .keyboardShortcut(".")
            .disabled(!scanState.canStopScan)
        }

        CommandMenu("Find") {
            Button("Find in Current Contents", systemImage: "sparkle.magnifyingglass") {
                fileListFilterAction?(.currentContents)
            }
            .keyboardShortcut("f")
            .disabled(fileListFilterAction == nil)

            Button("Search Entire Scan", systemImage: "magnifyingglass") {
                fileListFilterAction?(.entireScan)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(fileListFilterAction == nil)
        }

        CommandMenu("Navigate") {
            Button("Back", systemImage: "chevron.left") {
                appModel.navigateBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!navigation.canNavigateBack)

            Button("Forward", systemImage: "chevron.forward") {
                appModel.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!navigation.canNavigateForward)

            Divider()

            Button("Zoom Into Selection", systemImage: "plus.magnifyingglass") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.return)
            .disabled(!navigation.canZoomIntoSelection)

            Button("Back to Scan Root", systemImage: "arrowshape.turn.up.backward") {
                appModel.resetFocusToRoot()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(navigation.isFocusedAtRoot)

            Divider()

            Button("Clear Selection", systemImage: "clear") {
                appModel.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!navigation.canClearSelection)
        }

        CommandMenu("Inspect") {
            Button("Quick Look", systemImage: RadixSystemImages.quickLook) {
                appModel.toggleQuickLookForSelected()
            }
            .keyboardShortcut("y", modifiers: [.command])
            .disabled(!selectedActionAvailability.canPreviewWithQuickLook)

            Button("Open", systemImage: "arrow.up.forward.app") {
                appModel.openSelected()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!selectedActionAvailability.canOpen)

            Button("Reveal in Finder", systemImage: RadixSystemImages.revealInFinder) {
                appModel.revealSelectedInFinder()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!selectedActionAvailability.canRevealInFinder)

            Button("Copy Path", systemImage: RadixSystemImages.copyPath) {
                appModel.copySelectedPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!selectedActionAvailability.canCopyPath)

            Divider()

            Button("Move to Trash", systemImage: "trash") {
                appModel.requestMoveSelectedToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!selectedActionAvailability.canMoveToTrash)
        }
    }

    private var selectedActionAvailability: FileNodeActionAvailability {
        FileNodeActionAvailability(
            node: navigation.selectedNode,
            activeTarget: scanState.selectedTarget
        )
    }
}
