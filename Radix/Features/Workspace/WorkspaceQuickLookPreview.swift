import QuickLook
import QuickLookUI
import SwiftUI

struct WorkspaceQuickLookPreview: ViewModifier {
    @ObservedObject var controller: AppQuickLookController

    func body(content: Content) -> some View {
        content.quickLookPreview(
            Binding(
                get: { controller.session?.selection },
                set: { controller.setPreviewSelection($0) }
            ),
            in: controller.session?.urls ?? []
        )
        .background(QuickLookSourceNavigation(isEnabled: controller.session?.urls.count == 1))
    }
}

private struct QuickLookSourceNavigation: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> NavigationView { NavigationView() }

    func updateNSView(_ view: NavigationView, context: Context) {
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: NavigationView, coordinator: ()) {
        view.isEnabled = false
    }

    final class NavigationView: NSView {
        var isEnabled = false {
            didSet { updateMonitor() }
        }
        private var monitor: Any?

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            if isEnabled, window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return forwardNavigation(event)
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func forwardNavigation(_ event: NSEvent) -> NSEvent? {
            // Quick Look can leave mainWindow nil after returning from full screen.
            guard let window, window.isVisible,
                  NSApp.mainWindow == nil || NSApp.mainWindow === window,
                  let panel = event.window as? QLPreviewPanel,
                  !panel.isInFullScreenMode,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }

            if panel.firstResponder is NSControl { return event }
            if let text = panel.firstResponder as? NSTextView, text.isEditable { return event }

            switch window.firstResponder {
            case let chart as ChartKeyboardInteractionView where (123...126).contains(event.keyCode):
                chart.keyDown(with: event)
            case let table as NSTableView where event.keyCode == 125 || event.keyCode == 126:
                table.keyDown(with: event)
            default:
                return event
            }
            return nil
        }
    }
}
