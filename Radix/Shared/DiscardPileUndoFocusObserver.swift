import AppKit
import Combine
import SwiftUI

/// Enables collection commands for the workspace or its review sheet when
/// the key window has non-text focus.
/// Native text editors and other windows retain the standard Undo/Redo group.
struct DiscardPileUndoFocusObserver: NSViewRepresentable {
    let includesAttachedSheet: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
            coordinator?.scheduleUpdate()
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.includesAttachedSheet = includesAttachedSheet
        context.coordinator.onChange = onChange
        context.coordinator.window = view.window
        context.coordinator.scheduleUpdate()
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.stop()
    }

    final class AttachmentView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
        var includesAttachedSheet = false
        var onChange: (Bool) -> Void = { _ in }
        private var lastValue: Bool?
        private var notifications = Set<AnyCancellable>()
        private var updateTask: Task<Void, Never>?

        init() {
            NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification))
                .sink { [weak self] _ in self?.scheduleUpdate() }
                .store(in: &notifications)
        }

        func scheduleUpdate() {
            guard updateTask == nil else { return }
            updateTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                updateTask = nil
                let keyWindow = NSApp.keyWindow
                let belongsToWorkspace = keyWindow === window ||
                    (includesAttachedSheet && keyWindow?.sheetParent === window)
                let active = window != nil && belongsToWorkspace && !(keyWindow?.firstResponder is NSTextView)
                guard active != lastValue else { return }
                lastValue = active
                onChange(active)
            }
        }

        func stop() {
            updateTask?.cancel()
            updateTask = nil
            notifications.removeAll()
            window = nil
        }
    }
}
