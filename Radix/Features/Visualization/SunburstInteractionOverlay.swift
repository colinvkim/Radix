import AppKit
import SwiftUI

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let help: (CGPoint) -> String?

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onHover = onHover
        view.onClick = onClick
        view.help = help
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.help = help
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var help: (CGPoint) -> String? = { _ in nil }

        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onHover(location)
            updateHelp(at: location)
        }

        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onHover(location)
            updateHelp(at: location)
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
            toolTip = nil
        }

        override func mouseDown(with event: NSEvent) {
            onClick(convert(event.locationInWindow, from: nil), event.clickCount)
        }

        private func updateHelp(at location: CGPoint) {
            toolTip = help(location)
        }
    }
}
