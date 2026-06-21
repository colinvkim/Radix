import AppKit
import SwiftUI

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onPan: (CGSize) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let help: (CGPoint) -> String?
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onHover = onHover
        view.onClick = onClick
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.help = help
        view.isPanEnabled = isPanEnabled
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
        nsView.help = help
        nsView.isPanEnabled = isPanEnabled
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
        var help: (CGPoint) -> String? = { _ in nil }
        var isPanEnabled = false

        private static let dragThreshold: CGFloat = 3
        private static let lineScrollScale: CGFloat = 10
        fileprivate static let maximumScrollPanDelta: CGFloat = 80
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var lastDragLocation: CGPoint?
        private var didPan = false

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
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseMoved(with event: NSEvent) {
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
            toolTip = nil
        }

        override func mouseDown(with event: NSEvent) {
            let location = eventLocation(event)
            mouseDownLocation = location
            lastDragLocation = location
            didPan = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation,
                  let lastDragLocation else { return }

            let location = eventLocation(event)
            if !didPan {
                guard didExceedDragThreshold(from: mouseDownLocation, to: location) else {
                    return
                }
                didPan = true
            }

            defer { self.lastDragLocation = location }
            guard isPanEnabled else { return }

            onPan(CGSize(
                width: location.x - lastDragLocation.x,
                height: location.y - lastDragLocation.y
            ))
            updatePointerFeedback(at: location)
        }

        override func mouseUp(with event: NSEvent) {
            let location = eventLocation(event)
            if !didPan {
                onClick(location, event.clickCount)
            }
            mouseDownLocation = nil
            lastDragLocation = nil
            didPan = false
        }

        override func magnify(with event: NSEvent) {
            let location = eventLocation(event)
            onMagnify(location, max(0.75, 1 + event.magnification))
            updatePointerFeedback(at: location)
        }

        override func scrollWheel(with event: NSEvent) {
            let location = eventLocation(event)
            let zoomModifiers: NSEvent.ModifierFlags = [.command, .option]

            if !event.modifierFlags.intersection(zoomModifiers).isEmpty {
                let scrollDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
                guard scrollDelta != 0 else { return }

                onMagnify(location, pow(1.0025, scrollDelta))
                updatePointerFeedback(at: location)
                return
            }

            if isPanEnabled {
                guard let panDelta = panDelta(for: event) else { return }
                onPan(panDelta)
                updatePointerFeedback(at: location)
                return
            }

            super.scrollWheel(with: event)
        }

        private func updateHelp(at location: CGPoint) {
            toolTip = help(location)
        }

        private func updatePointerFeedback(at location: CGPoint) {
            onHover(location)
            updateHelp(at: location)
        }

        private func eventLocation(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func didExceedDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
            let dx = end.x - start.x
            let dy = end.y - start.y
            return ((dx * dx) + (dy * dy)) >= (Self.dragThreshold * Self.dragThreshold)
        }

        private func panDelta(for event: NSEvent) -> CGSize? {
            var delta = CGSize(
                width: event.scrollingDeltaX,
                height: event.scrollingDeltaY
            )

            guard delta != .zero else { return nil }

            if !event.isDirectionInvertedFromDevice {
                delta.width *= -1
                delta.height *= -1
            }

            if !event.hasPreciseScrollingDeltas {
                delta.width *= Self.lineScrollScale
                delta.height *= Self.lineScrollScale
            }

            return CGSize(
                width: delta.width.clampedScrollPanDelta,
                height: delta.height.clampedScrollPanDelta
            )
        }
    }
}

private extension CGFloat {
    var clampedScrollPanDelta: CGFloat {
        Swift.min(
            Swift.max(self, -SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta),
            SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta
        )
    }
}
