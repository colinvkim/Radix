import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction
    @FocusedValue(\.inspectorVisibility) private var inspectorVisibility
    @FocusedValue(\.workspaceFocusAction) private var workspaceFocusAction
    @FocusedValue(\.sunburstViewportAction) private var sunburstViewportAction

    var body: some Commands {
        SidebarCommands()

        CommandGroup(after: .toolbar) {
            Button("Focus Sidebar", systemImage: "sidebar.left") {
                workspaceFocusAction?(.sidebar)
            }
            .keyboardShortcut("1")
            .disabled(workspaceFocusAction == nil)

            Button("Focus Chart", systemImage: "chart.pie") {
                workspaceFocusAction?(.chart)
            }
            .keyboardShortcut("2")
            .disabled(workspaceFocusAction == nil || scanState.snapshot == nil)

            Button("Focus Contents", systemImage: "list.bullet") {
                workspaceFocusAction?(.contents)
            }
            .keyboardShortcut("3")
            .disabled(workspaceFocusAction == nil || scanState.snapshot == nil)

            Divider()

            Button(inspectorToggleTitle, systemImage: "sidebar.trailing") {
                inspectorVisibility?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(inspectorVisibility == nil)

            Divider()

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                sunburstViewportAction?(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(sunburstViewportAction == nil || scanState.snapshot == nil)

            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                sunburstViewportAction?(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(sunburstViewportAction == nil || scanState.snapshot == nil)

            Button("Actual Size", systemImage: "arrow.counterclockwise") {
                sunburstViewportAction?(.reset)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(sunburstViewportAction == nil || scanState.snapshot == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(scanState.isScanning)

            Button("Import Snapshot…", systemImage: "square.and.arrow.down") {
                appModel.importScanSnapshot()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!appModel.canImportScanSnapshot)

            Button("Export Snapshot…", systemImage: "square.and.arrow.up") {
                appModel.exportCurrentScan()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!appModel.canExportCurrentScan)

            Divider()

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

            Button("Go to Parent", systemImage: "arrow.up") {
                appModel.navigateToParent()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!navigation.canNavigateToParent)

            Divider()

            Button("Zoom Into Selection", systemImage: "plus.magnifyingglass") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
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
            selectedFileActionCommand(.quickLook, shortcut: "y")

            selectedFileActionCommand(.open, shortcut: "o", modifiers: [.command, .shift])

            selectedFileActionCommand(.revealInFinder, shortcut: "j", modifiers: [.command, .shift])

            selectedFileActionCommand(.copyPath, shortcut: "c", modifiers: [.command, .shift])

            Divider()

            selectedFileActionCommand(.moveToTrash, shortcut: .delete, modifiers: [])
        }
    }

    private var selectedActionAvailability: FileNodeActionAvailability {
        FileNodeActionAvailability(
            nodes: navigation.selectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
    }

    private var inspectorToggleTitle: String {
        if inspectorVisibility?.wrappedValue == true {
            return "Hide Inspector"
        }
        return "Show Inspector"
    }

    private var commandSelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.toggleQuickLookForSelected() },
            revealInFinder: { appModel.revealSelectedInFinder() },
            open: { appModel.openSelected() },
            copyPath: { appModel.copySelectedPath() },
            moveToTrash: { appModel.requestMoveSelectedToTrash() }
        )
    }

    private func selectedFileActionCommand(
        _ action: FileNodeAction,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers = [.command]
    ) -> some View {
        Button(action.title, systemImage: action.systemImageName) {
            commandSelectedFileActions.perform(action)
        }
        .keyboardShortcut(shortcut, modifiers: modifiers)
        .disabled(!action.isEnabled(in: selectedActionAvailability))
    }
}
