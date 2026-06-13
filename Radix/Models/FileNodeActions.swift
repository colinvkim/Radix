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
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) {
        let supportsFileActions = node?.supportsFileActions == true
        self.init(
            canOpen: supportsFileActions,
            canPreviewWithQuickLook: supportsFileActions,
            canRevealInFinder: supportsFileActions,
            canCopyPath: supportsFileActions,
            canMoveToTrash: node?.supportsMoveToTrash(
                activeTarget: activeTarget,
                trashSafetyPolicy: trashSafetyPolicy
            ) == true
        )
    }
}

enum ScanPostTrashAction: Equatable {
    case clearActiveScan
    case rescanActiveScan
    case none

    static func afterRemovingNode(activeTargetID: String?, removedNodeID: String) -> ScanPostTrashAction {
        guard let activeTargetID else { return .none }
        return activeTargetID == removedNodeID ? .clearActiveScan : .rescanActiveScan
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
        trashSafetyPolicy: TrashSafetyPolicy = .live()
    ) -> FileNodeActionAvailability {
        FileNodeActionAvailability(
            node: self,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy
        )
    }
}
