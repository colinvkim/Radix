//
//  AppQuickLookController.swift
//  Radix
//

import AppKit
import Foundation

@MainActor
struct AppQuickLookSelectionContext {
    let selectedNode: FileNodeRecord?
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
}

@MainActor
protocol AppQuickLookControllerDelegate: AnyObject {
    var quickLookSelectionContext: AppQuickLookSelectionContext { get }
    var isQuickLookKeyboardShortcutBlocked: Bool { get }

    func validatedSelectionForQuickLook() throws -> FileNodeRecord
    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error)
}

@MainActor
final class AppQuickLookController {
    weak var delegate: (any AppQuickLookControllerDelegate)?

    private let quickLookActions: AppQuickLookActions
    private let installKeyMonitorAction: (@escaping (NSEvent) -> Bool) -> AppEventMonitorToken?
    private var keyMonitor: AppEventMonitorToken?
    private var workspaceWindowNumber: Int?

    init(systemActions: AppSystemActions) {
        quickLookActions = systemActions.quickLook
        installKeyMonitorAction = systemActions.installQuickLookKeyMonitor
    }

    deinit {
        MainActor.assumeIsolated {
            removeKeyMonitor()
        }
    }

    func setWorkspaceWindowNumber(_ windowNumber: Int?) {
        workspaceWindowNumber = windowNumber
    }

    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = installKeyMonitorAction { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyDown(event) == true
            }
        }
    }

    func removeKeyMonitor() {
        keyMonitor?.remove()
        keyMonitor = nil
    }

    func closePreview() {
        quickLookActions.close()
    }

    func previewSelected() {
        performSelectedPreviewAction(quickLookActions.present)
    }

    func toggleSelected() {
        performSelectedPreviewAction(quickLookActions.toggle)
    }

    func syncVisiblePreview() {
        guard quickLookActions.isPreviewVisible() else { return }

        guard let context = delegate?.quickLookSelectionContext,
              let selectedNode = context.selectedNode,
              canPreview(selectedNode, in: context) else {
            quickLookActions.close()
            return
        }

        quickLookActions.updateVisiblePreview(selectedNode.url)
    }

    private func performSelectedPreviewAction(_ action: (URL) throws -> Void) {
        do {
            guard let selectedNode = try delegate?.validatedSelectionForQuickLook() else { return }
            try action(selectedNode.url)
        } catch {
            delegate?.appQuickLookController(self, didFailWith: error)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard Self.isPlainSpaceKey(event) else { return false }
        guard isWorkspaceKeyEvent(event) else { return false }
        guard let delegate, !delegate.isQuickLookKeyboardShortcutBlocked else { return false }
        guard !quickLookActions.isPreviewPanelKeyWindow() else { return false }
        guard !Self.shouldPreserveSpaceKey(for: event.window?.firstResponder) else { return false }
        let context = delegate.quickLookSelectionContext
        guard let selectedNode = context.selectedNode,
              canPreview(selectedNode, in: context) else {
            return false
        }

        toggleSelected()
        return true
    }

    private static func isPlainSpaceKey(_ event: NSEvent) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return false }
        return event.keyCode == 49 || event.charactersIgnoringModifiers == " "
    }

    private func isWorkspaceKeyEvent(_ event: NSEvent) -> Bool {
        guard let workspaceWindowNumber else { return false }
        return event.windowNumber == workspaceWindowNumber
    }

    private static func shouldPreserveSpaceKey(for responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if responder is NSTextView || responder is NSTextField || responder is NSButton {
            return true
        }

        if responder is NSTableView || responder is NSOutlineView || responder is NSCollectionView {
            return false
        }

        return responder is NSControl
    }

    private func canPreview(_ node: FileNodeRecord, in context: AppQuickLookSelectionContext) -> Bool {
        node.actionAvailability(
            activeTarget: context.activeTarget,
            trashSafetyPolicy: context.trashSafetyPolicy
        ).canPreviewWithQuickLook
    }
}
