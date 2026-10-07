//
//  FileNodeActions.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated enum FileNodeAction: CaseIterable, Equatable, Identifiable, Sendable {
    case quickLook
    case revealInFinder
    case open
    case openInTerminal
    case copyPath
    case moveToTrash

    var id: Self { self }

    var title: String {
        switch self {
        case .quickLook:
            return String(localized: "Quick Look", comment: "File action that previews the selected item.")
        case .revealInFinder:
            return String(localized: "Reveal in Finder", comment: "File action that shows the selected item in Finder.")
        case .open:
            return String(localized: "Open", comment: "File action that opens the selected item.")
        case .openInTerminal:
            return String(localized: "Open in Terminal", comment: "File action that opens a shell at the selected folder.")
        case .copyPath:
            return String(localized: "Copy Path", comment: "File action that copies the selected item's path.")
        case .moveToTrash:
            return String(localized: "Move to Trash", comment: "Destructive file action that moves the selected item to the Trash.")
        }
    }

    var systemImageName: String {
        switch self {
        case .quickLook:
            if #available(macOS 15.0, *) {
                return "document.viewfinder"
            }
            return "doc.viewfinder"
        case .revealInFinder:
            if #available(macOS 26.0, *) {
                return "finder"
            }
            return "folder"
        case .open:
            return "arrow.up.forward.app"
        case .openInTerminal:
            return "terminal"
        case .copyPath:
            if #available(macOS 15.0, *) {
                return "document.on.document"
            }
            return "doc.on.doc"
        case .moveToTrash:
            return "trash"
        }
    }

    func isEnabled(in availability: FileNodeActionAvailability) -> Bool {
        switch self {
        case .quickLook:
            return availability.canPreviewWithQuickLook
        case .revealInFinder:
            return availability.canRevealInFinder
        case .open:
            return availability.canOpen
        case .openInTerminal:
            return availability.canOpen
        case .copyPath:
            return availability.canCopyPath
        case .moveToTrash:
            return availability.canMoveToTrash
        }
    }
}

extension FileNodeAction {
    nonisolated func title(for node: FileNodeRecord?) -> String {
        guard self == .openInTerminal,
              node?.opensTerminalInContainingFolder == true else {
            return title
        }
        return String(
            localized: "Open Containing Folder in Terminal",
            comment: "File action that opens a shell in the folder containing the selected file, package, or symbolic link."
        )
    }
}

nonisolated struct FileNodeActionAvailability: Equatable, Sendable {
    let canOpen: Bool
    let canPreviewWithQuickLook: Bool
    let canRevealInFinder: Bool
    let canCopyPath: Bool
    let canMoveToTrash: Bool

    init(
        canOpen: Bool,
        canPreviewWithQuickLook: Bool,
        canRevealInFinder: Bool,
        canCopyPath: Bool,
        canMoveToTrash: Bool
    ) {
        self.canOpen = canOpen
        self.canPreviewWithQuickLook = canPreviewWithQuickLook
        self.canRevealInFinder = canRevealInFinder
        self.canCopyPath = canCopyPath
        self.canMoveToTrash = canMoveToTrash
    }

    init(
        node: FileNodeRecord?,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live(),
        snapshotSource: ScanSnapshotSource = .live,
        isReadOnlyMode: Bool = false
    ) {
        let supportsFileActions = node?.supportsFileActions == true
        self.init(
            canOpen: supportsFileActions && snapshotSource.allowsLivePathActions,
            canPreviewWithQuickLook: supportsFileActions && snapshotSource.allowsLivePathActions,
            canRevealInFinder: supportsFileActions && snapshotSource.allowsLivePathActions,
            canCopyPath: supportsFileActions && snapshotSource.allowsArchivedPathCopy,
            canMoveToTrash: node?.supportsMoveToTrash(
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy
            ) == true && snapshotSource.allowsFileMutation && !isReadOnlyMode
        )
    }

    init(
        nodes: [FileNodeRecord],
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live(),
        snapshotSource: ScanSnapshotSource = .live,
        isReadOnlyMode: Bool = false
    ) {
        guard !nodes.isEmpty else {
            self.init(
                canOpen: false,
                canPreviewWithQuickLook: false,
                canRevealInFinder: false,
                canCopyPath: false,
                canMoveToTrash: false
            )
            return
        }

        guard nodes.count > 1 else {
            self.init(
                node: nodes.first,
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy,
                snapshotSource: snapshotSource,
                isReadOnlyMode: isReadOnlyMode
            )
            return
        }

        self.init(
            canOpen: false,
            canPreviewWithQuickLook: nodes.allSatisfy(\.supportsFileActions) && snapshotSource.allowsLivePathActions,
            canRevealInFinder: nodes.allSatisfy(\.supportsFileActions) && snapshotSource.allowsLivePathActions,
            canCopyPath: nodes.allSatisfy(\.supportsFileActions) && snapshotSource.allowsArchivedPathCopy,
            canMoveToTrash: nodes.allSatisfy {
                $0.supportsMoveToTrash(
                    activeTarget: activeTarget,
                    trashSafetyPolicy: trashSafetyPolicy
                )
            } && snapshotSource.allowsFileMutation && !isReadOnlyMode
        )
    }
}

nonisolated enum ScanPostTrashAction: Equatable {
    case clearActiveScan
    case removeFromActiveScan
    case none

    static func afterRemovingNode(activeTargetID: String?, removedNodeID: String) -> ScanPostTrashAction {
        guard let activeTargetID else { return .none }
        return activeTargetID == removedNodeID ? .clearActiveScan : .removeFromActiveScan
    }
}

extension FileNodeRecord {
    nonisolated var opensTerminalInContainingFolder: Bool {
        !isDirectory || isPackage || isSymbolicLink
    }

    nonisolated var terminalDirectoryURL: URL {
        opensTerminalInContainingFolder ? url.deletingLastPathComponent() : url
    }

    nonisolated var supportsMoveToTrash: Bool {
        supportsMoveToTrash(trashSafetyPolicy: .live())
    }

    nonisolated func supportsMoveToTrash(trashSafetyPolicy: TrashSafetyPolicy) -> Bool {
        supportsFileActions && trashSafetyPolicy.blockReason(for: url) == nil
    }

    nonisolated func supportsMoveToTrash(
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) -> Bool {
        guard supportsMoveToTrash(trashSafetyPolicy: trashSafetyPolicy) else { return false }
        guard let activeTarget else { return true }
        return !(activeTarget.kind == .volume && activeTarget.id == id)
    }

    nonisolated func actionAvailability(
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live(),
        snapshotSource: ScanSnapshotSource = .live
    ) -> FileNodeActionAvailability {
        FileNodeActionAvailability(
            node: self,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy,
            snapshotSource: snapshotSource
        )
    }
}
