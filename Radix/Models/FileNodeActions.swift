//
//  FileNodeActions.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum FileNodeAction: CaseIterable, Equatable, Identifiable, Sendable {
    case quickLook
    case revealInFinder
    case open
    case copyPath
    case moveToTrash

    var id: Self { self }

    var title: String {
        switch self {
        case .quickLook:
            return "Quick Look"
        case .revealInFinder:
            return "Reveal in Finder"
        case .open:
            return "Open"
        case .copyPath:
            return "Copy Path"
        case .moveToTrash:
            return "Move to Trash"
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
        case .copyPath:
            return availability.canCopyPath
        case .moveToTrash:
            return availability.canMoveToTrash
        }
    }
}

struct FileNodeActionAvailability: Equatable, Sendable {
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
        snapshotSource: ScanSnapshotSource = .live
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
            ) == true && snapshotSource.allowsFileMutation
        )
    }

    init(
        nodes: [FileNodeRecord],
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live(),
        snapshotSource: ScanSnapshotSource = .live
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
                snapshotSource: snapshotSource
            )
            return
        }

        self.init(
            canOpen: false,
            canPreviewWithQuickLook: false,
            canRevealInFinder: nodes.allSatisfy(\.supportsFileActions) && snapshotSource.allowsLivePathActions,
            canCopyPath: nodes.allSatisfy(\.supportsFileActions) && snapshotSource.allowsArchivedPathCopy,
            canMoveToTrash: nodes.allSatisfy {
                $0.supportsMoveToTrash(
                    activeTarget: activeTarget,
                    trashSafetyPolicy: trashSafetyPolicy
                )
            } && snapshotSource.allowsFileMutation
        )
    }
}

enum ScanPostTrashAction: Equatable {
    case clearActiveScan
    case removeFromActiveScan
    case none

    static func afterRemovingNode(activeTargetID: String?, removedNodeID: String) -> ScanPostTrashAction {
        guard let activeTargetID else { return .none }
        return activeTargetID == removedNodeID ? .clearActiveScan : .removeFromActiveScan
    }
}

extension FileNodeRecord {
    var supportsMoveToTrash: Bool {
        supportsMoveToTrash(trashSafetyPolicy: .live())
    }

    func supportsMoveToTrash(trashSafetyPolicy: TrashSafetyPolicy) -> Bool {
        supportsFileActions && trashSafetyPolicy.blockReason(for: url) == nil
    }

    func supportsMoveToTrash(
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) -> Bool {
        guard supportsMoveToTrash(trashSafetyPolicy: trashSafetyPolicy) else { return false }
        guard let activeTarget else { return true }
        return !(activeTarget.kind == .volume && activeTarget.id == id)
    }

    func actionAvailability(
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
