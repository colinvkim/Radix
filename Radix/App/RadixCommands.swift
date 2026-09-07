import SwiftUI

struct RadixCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    @ObservedObject var workspaceTour: WorkspaceTourController
    @FocusedValue(\.fileListFilterAction) private var fileListFilterAction
    @FocusedValue(\.inspectorVisibility) private var inspectorVisibility
    @FocusedValue(\.workspaceFocusAction) private var workspaceFocusAction
    @FocusedValue(\.chartViewportAction) private var chartViewportAction

    var body: some Commands {
        let selectedActionAvailability = FileNodeActionAvailability(
            nodes: navigation.selectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )

        SidebarCommands()

        CommandGroup(after: .help) {
            Button("Take a Quick Tour") {
                appModel.startWorkspaceTour()
            }
            .disabled(!appModel.canStartWorkspaceTour)

            Button("Stop Tour") {
                workspaceTour.stop()
            }
            .disabled(!workspaceTour.isActive)
        }

        CommandGroup(after: .toolbar) {
            Button("Focus Sidebar", systemImage: "sidebar.left") {
                workspaceFocusAction?(.sidebar)
            }
            .keyboardShortcut("1")
            .disabled(!appModel.canUseWorkspaceCommands || workspaceFocusAction == nil)

            Button("Focus Chart", systemImage: "chart.pie") {
                workspaceFocusAction?(.chart)
            }
            .keyboardShortcut("2")
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    workspaceFocusAction == nil ||
                    scanState.snapshot == nil
            )

            Button("Focus Contents", systemImage: "list.bullet") {
                workspaceFocusAction?(.contents)
            }
            .keyboardShortcut("3")
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    workspaceFocusAction == nil ||
                    scanState.snapshot == nil
            )

            Divider()

            Button(inspectorToggleTitle, systemImage: "sidebar.trailing") {
                inspectorVisibility?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    inspectorVisibility == nil ||
                    scanState.snapshot == nil
            )

            Divider()

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                chartViewportAction?(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )

            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                chartViewportAction?(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )

            Button("Actual Size", systemImage: "arrow.counterclockwise") {
                chartViewportAction?(.reset)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    chartViewportAction == nil ||
                    scanState.snapshot == nil
            )
        }

        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                appModel.presentOpenPanelAndScan()
            }
            .keyboardShortcut("o")
            .disabled(scanState.isScanOperationInProgress)

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

            Button("Compare Scans…", systemImage: "rectangle.split.2x1") {
                appModel.compareScanSnapshots()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!appModel.canCompareScanSnapshots)

            Button("Compare Current Scan With Saved Scan…", systemImage: "arrow.left.arrow.right") {
                appModel.compareCurrentScanWithSnapshot()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!appModel.canCompareCurrentScanWithSnapshot)

            Divider()

            Button("Rescan Current Folder", systemImage: "arrow.clockwise") {
                appModel.rescan()
            }
            .keyboardShortcut("r")
            .disabled(!appModel.canRescanCurrentFolder)

            Button("Rescan Entire Scan", systemImage: "arrow.clockwise.circle") {
                appModel.rescanEntireScan()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appModel.canRescanEntireScan)

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
            .disabled(!appModel.canUseWorkspaceCommands || !navigation.canNavigateBack)

            Button("Forward", systemImage: "chevron.forward") {
                appModel.navigateForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!appModel.canUseWorkspaceCommands || !navigation.canNavigateForward)

            Divider()

            Button("Go to Parent", systemImage: "arrow.up") {
                appModel.navigateToParent()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!appModel.canUseWorkspaceCommands || !navigation.canNavigateToParent)

            Divider()

            Button("Zoom Into Selection", systemImage: "plus.magnifyingglass") {
                appModel.zoomIntoSelection()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!appModel.canUseWorkspaceCommands || !appModel.canZoomIntoSelection)

            Button("Back to Scan Root", systemImage: "arrowshape.turn.up.backward") {
                appModel.resetFocusToRoot()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(!appModel.canUseWorkspaceCommands || navigation.isFocusedAtRoot)

            Divider()

            Button("Clear Selection", systemImage: "clear") {
                appModel.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!appModel.canUseWorkspaceCommands || !navigation.canClearSelection)
        }

        CommandMenu("Inspect") {
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

            Button(
                FileNodeAction.openInTerminal.title(for: navigation.selectedNode),
                systemImage: FileNodeAction.openInTerminal.systemImageName
            ) {
                commandSelectedFileActions.perform(.openInTerminal)
            }
            .disabled(
                !appModel.canUseWorkspaceCommands ||
                    !FileNodeAction.openInTerminal.isEnabled(in: selectedActionAvailability)
            )

            selectedFileActionCommand(
                .revealInFinder,
                availability: selectedActionAvailability,
                shortcut: "j",
                modifiers: [.command, .shift]
            )

            selectedFileActionCommand(
                .copyPath,
                availability: selectedActionAvailability,
                shortcut: "c",
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
                !appModel.canUseWorkspaceCommands ||
                    (!appModel.selectionIncludesHiddenNodes
                        && !selectedActionAvailability.canMoveToTrash)
            )

            selectedFileActionCommand(
                .moveToTrash,
                availability: selectedActionAvailability,
                shortcut: .delete,
                modifiers: []
            )
        }
    }

    private var inspectorToggleTitle: String {
        if inspectorVisibility?.wrappedValue == true {
            return String(localized: "Hide Inspector", comment: "Command for hiding the inspector sidebar.")
        }
        return String(localized: "Show Inspector", comment: "Command for showing the inspector sidebar.")
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
            !appModel.canUseWorkspaceCommands ||
                !action.isEnabled(in: availability) ||
                (action == .moveToTrash && appModel.selectionIncludesHiddenNodes)
        )
    }
}
