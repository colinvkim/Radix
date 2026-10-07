import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @ObservedObject var workspaceTour: WorkspaceTourController
    @FocusedValue(\.isDiscardPileUndoContext) private var isDiscardPileUndoContext
    @FocusedValue(\.isWorkspaceWindowFocused) private var isWorkspaceWindowFocused
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction
    @FocusedValue(\.isFileListSearchActive) private var isFileListSearchActive
    @FocusedValue(\.chartViewportAction) private var chartViewportAction

    var body: some Commands {
        let selectedActionAvailability = FileNodeActionAvailability(
            nodes: navigation.selectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource,
            isReadOnlyMode: appModel.isReadOnlyMode
        )

        if isDiscardPileUndoContext == true {
            CommandGroup(replacing: .undoRedo) {
                Button { appModel.undoDiscardPileChange() } label: {
                    Text(verbatim: appModel.discardPileUndoTitle)
                }
                .keyboardShortcut("z")
                .disabled(!appModel.canUndoDiscardPileChange)

                Button { appModel.redoDiscardPileChange() } label: {
                    Text(verbatim: appModel.discardPileRedoTitle)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!appModel.canRedoDiscardPileChange)
            }
        }

        SidebarCommands()
        if canUseWorkspaceCommands, scanState.snapshot != nil {
            InspectorCommands()
        } else {
            CommandGroup(after: .sidebar) {
                Button("Show Inspector", systemImage: "sidebar.trailing") {}
                    .keyboardShortcut("i", modifiers: [.command, .control])
                    .disabled(true)
            }
        }

        CommandGroup(after: .help) {
            Button("Take a Quick Tour") {
                appModel.startWorkspaceTour()
            }
            .disabled(isWorkspaceWindowFocused != true || !appModel.canStartWorkspaceTour)

            Button("Stop Tour") {
                workspaceTour.stop()
            }
            .disabled(isWorkspaceWindowFocused != true || !workspaceTour.isActive)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                chartViewportAction?(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(
                !canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )

            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                chartViewportAction?(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(
                !canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )

            Button("Actual Size") {
                chartViewportAction?(.reset)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(
                !canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )
        }

        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(isWorkspaceWindowFocused != true || scanState.isScanOperationInProgress)

            Button("Import Snapshot…", systemImage: "square.and.arrow.down") {
                appModel.importScanSnapshot()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(isWorkspaceWindowFocused != true || !appModel.canImportScanSnapshot)

            Button("Export Snapshot…", systemImage: "square.and.arrow.up") {
                appModel.exportCurrentScan()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(isWorkspaceWindowFocused != true || !appModel.canExportCurrentScan)

            Divider()

            Button("Compare Scans…") {
                appModel.compareScanSnapshots()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(isWorkspaceWindowFocused != true || !appModel.canCompareScanSnapshots)

            Divider()

            Button("Rescan Current Folder") {
                appModel.rescan()
            }
            .keyboardShortcut("r")
            .disabled(!canUseWorkspaceCommands || !appModel.canRescanCurrentFolder)

            Button("Rescan Entire Scan") {
                appModel.rescanEntireScan()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canUseWorkspaceCommands || !appModel.canRescanEntireScan)

            Button("Stop Scan", systemImage: "stop") {
                appModel.stopScan()
            }
            .keyboardShortcut(".")
            .disabled(isWorkspaceWindowFocused != true || !scanState.canStopScan)

            Divider()

            selectedFileActionCommand(
                .quickLook,
                availability: selectedActionAvailability,
                shortcut: "y"
            )

            selectedFileActionCommand(
                .open,
                availability: selectedActionAvailability,
                shortcut: "o",
                modifiers: [.command, .shift]
            )
            .labelStyle(.titleOnly)

            Button(
                FileNodeAction.openInTerminal.title(for: navigation.selectedNode),
                systemImage: FileNodeAction.openInTerminal.systemImageName
            ) {
                commandSelectedFileActions.perform(.openInTerminal)
            }
            .disabled(
                !canUseWorkspaceCommands ||
                    !FileNodeAction.openInTerminal.isEnabled(in: selectedActionAvailability)
            )

            selectedFileActionCommand(
                .revealInFinder,
                availability: selectedActionAvailability,
                shortcut: "j",
                modifiers: [.command, .shift]
            )

            Divider()

            Button(addSelectionToDiscardPileTitle, systemImage: "checklist") {
                if appModel.selectionIncludesHiddenNodes {
                    appModel.presentDiscardPileReview()
                } else {
                    appModel.addSelectedNodesToDiscardPile()
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(
                !canUseWorkspaceCommands ||
                    (!appModel.selectionIncludesHiddenNodes
                        && !selectedActionAvailability.canMoveToTrash)
            )

            selectedFileActionCommand(
                .moveToTrash,
                availability: selectedActionAvailability,
                shortcut: .delete
            )
        }

        CommandGroup(after: .pasteboard) {
            selectedFileActionCommand(
                .copyPath,
                availability: selectedActionAvailability,
                shortcut: "c",
                modifiers: [.command, .shift]
            )
            .labelStyle(.titleOnly)
        }

        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Search Current Contents") {
                    fileListFilterAction?(.currentContents)
                }
                .keyboardShortcut("f")
                .disabled(!canUseWorkspaceCommands || fileListFilterAction == nil)

                Button("Search Entire Scan") {
                    fileListFilterAction?(.entireScan)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canUseWorkspaceCommands || fileListFilterAction == nil)
            }
        }

        CommandMenu("Navigate") {
            Button("Back", systemImage: "chevron.left") {
                appModel.navigateBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!canUseWorkspaceCommands || !navigation.canNavigateBack)

            Button("Forward", systemImage: "chevron.forward") {
                appModel.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!canUseWorkspaceCommands || !navigation.canNavigateForward)

            Divider()

            Button("Go to Parent", systemImage: "arrow.up") {
                appModel.navigateToParent()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!canUseWorkspaceCommands || !navigation.canNavigateToParent)

            Divider()

            Button("Zoom Into Selection") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!canUseWorkspaceCommands || !appModel.canZoomIntoSelection)

            Button("Back to Scan Root") {
                appModel.resetFocusToRoot()
            }
            .disabled(!canUseWorkspaceCommands || navigation.isFocusedAtRoot)
        }
    }

    private var canUseWorkspaceCommands: Bool {
        isWorkspaceWindowFocused == true && appModel.canUseWorkspaceCommands
    }

    private var addSelectionToDiscardPileTitle: String {
        if appModel.selectionIncludesHiddenNodes {
            return String(
                localized: "Review Discard Pile",
                comment: "Command for reviewing the Discard Pile when the selection is already included."
            )
        }
        let count = navigation.selectedNodeIDs.count
        guard count > 1 else {
            return String(localized: "Add to Discard Pile", comment: "Action for marking one selected item for possible deletion.")
        }
        return String(localized: "Add \(count) Items to Discard Pile", comment: "Action for marking multiple selected items for possible deletion.")
    }

    private var commandSelectedFileActions: SelectedFileActions {
        SelectedFileActions(
            quickLook: { appModel.toggleQuickLookForSelected() },
            revealInFinder: { appModel.revealSelectedInFinder() },
            open: { appModel.openSelected() },
            openInTerminal: { Task { await appModel.openSelectedInTerminal() } },
            copyPath: { appModel.copySelectedPath() },
            moveToTrash: { appModel.requestMoveSelectedToTrash() }
        )
    }

    private func selectedFileActionCommand(
        _ action: FileNodeAction,
        availability: FileNodeActionAvailability,
        shortcut: KeyEquivalent,
        modifiers: EventModifiers = [.command]
    ) -> some View {
        Button(action.title, systemImage: action.systemImageName) {
            commandSelectedFileActions.perform(action)
        }
        .keyboardShortcut(shortcut, modifiers: modifiers)
        .disabled(
            !canUseWorkspaceCommands ||
                !action.isEnabled(in: availability) ||
                (action == .moveToTrash &&
                    (appModel.selectionIncludesHiddenNodes || isFileListSearchActive == true))
        )
    }
}
