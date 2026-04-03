import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(!appModel.canChooseFolder)

            Button("Rescan", systemImage: "arrow.clockwise") {
                appModel.rescan()
            }
            .keyboardShortcut("r")
            .disabled(!appModel.canRescan)

            Button("Stop Scan", systemImage: "stop") {
                appModel.stopScan()
            }
            .keyboardShortcut(".")
            .disabled(!appModel.canStopScan)
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
            .disabled(!appModel.canNavigateBack)

            Button("Forward", systemImage: "chevron.forward") {
                appModel.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!appModel.canNavigateForward)

            Divider()

            Button("Zoom Into Selection", systemImage: "plus.magnifyingglass") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.return)
            .disabled(!appModel.canZoomIntoSelection)

            Button("Back to Scan Root", systemImage: "arrowshape.turn.up.backward") {
                appModel.resetFocusToRoot()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(appModel.isFocusedAtRoot)

            Divider()

            Button("Clear Selection", systemImage: "clear") {
                appModel.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!appModel.canClearSelection)
        }

        CommandMenu("Inspect") {
            Button("Open", systemImage: "arrow.up.forward.app") {
                appModel.openSelected()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!appModel.canOpenSelected)

            Button("Reveal in Finder", systemImage: "finder") {
                appModel.revealSelectedInFinder()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!appModel.canRevealSelected)

            Button("Copy Path", systemImage: "document.on.document") {
                appModel.copySelectedPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!appModel.canCopySelectedPath)

            Divider()

            Button("Move to Trash", systemImage: "trash") {
                appModel.requestMoveSelectedToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!appModel.canMoveSelectedToTrash)
        }
    }
}
