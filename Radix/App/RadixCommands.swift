import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction

    var body: some Commands {
        SidebarCommands()

        CommandGroup(after: .newItem) {
            Button("Scan Folder…") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(!appModel.canChooseFolder)

            Button("Rescan") {
                appModel.rescan()
            }
            .keyboardShortcut("r")
            .disabled(!appModel.canRescan)

            Button("Stop Scan") {
                appModel.stopScan()
            }
            .keyboardShortcut(".")
            .disabled(!appModel.canStopScan)
        }

        CommandMenu("Find") {
            Button("Find in Current Contents") {
                fileListFilterAction?(.currentContents)
            }
            .keyboardShortcut("f")
            .disabled(fileListFilterAction == nil)

            Button("Search Entire Scan") {
                fileListFilterAction?(.entireScan)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(fileListFilterAction == nil)
        }

        CommandMenu("Navigate") {
            Button("Back") {
                appModel.navigateBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!appModel.canNavigateBack)

            Button("Forward") {
                appModel.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!appModel.canNavigateForward)

            Divider()

            Button("Zoom Into Selection") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.return)
            .disabled(!appModel.canZoomIntoSelection)

            Button("Back to Scan Root") {
                appModel.resetFocusToRoot()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(appModel.isFocusedAtRoot)

            Divider()

            Button("Clear Selection") {
                appModel.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!appModel.canClearSelection)
        }

        CommandMenu("Inspect") {
            Button("Open") {
                appModel.openSelected()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!appModel.canOpenSelected)

            Button("Reveal in Finder") {
                appModel.revealSelectedInFinder()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!appModel.canRevealSelected)

            Button("Copy Path") {
                appModel.copySelectedPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!appModel.canCopySelectedPath)

            Divider()

            Button("Move to Trash") {
                appModel.requestMoveSelectedToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!appModel.canMoveSelectedToTrash)
        }
    }
}
