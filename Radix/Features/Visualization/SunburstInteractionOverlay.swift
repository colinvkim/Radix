import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SunburstDiscardPileDragItem {
    let payload: DiscardPileDragPayload
    let segment: SunburstSegment
}

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onPan: (CGSize) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let discardPileDragItem: (CGPoint) -> SunburstDiscardPileDragItem?
    let onDiscardPileDragActiveChange: (Bool) -> Void
    let help: (CGPoint) -> String?
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onHover = onHover
        view.onClick = onClick
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.discardPileDragItem = discardPileDragItem
        view.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
        view.help = help
        view.isPanEnabled = isPanEnabled
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.onPan = onPan
        nsView.onMagnify = onMagnify
        nsView.discardPileDragItem = discardPileDragItem
        nsView.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
        nsView.help = help
        nsView.isPanEnabled = isPanEnabled
    }

    final class InteractionView: NSView, NSDraggingSource {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
        var discardPileDragItem: (CGPoint) -> SunburstDiscardPileDragItem? = { _ in nil }
        var onDiscardPileDragActiveChange: (Bool) -> Void = { _ in }
        var help: (CGPoint) -> String? = { _ in nil }
        var isPanEnabled = false

        private static let dragThreshold: CGFloat = 3
        private static let discardPileDragImageSize = NSSize(width: 42, height: 42)
        private static let lineScrollScale: CGFloat = 10
        fileprivate static let maximumScrollPanDelta: CGFloat = 80
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var lastDragLocation: CGPoint?
        private var didPan = false
        private var didStartDiscardPileDrag = false

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
            didStartDiscardPileDrag = false
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

            if !didStartDiscardPileDrag,
               let discardPileDragItem = discardPileDragItem(mouseDownLocation),
               let draggingItem = discardPileDraggingItem(
                   for: discardPileDragItem,
                   at: mouseDownLocation
               ) {
                didStartDiscardPileDrag = true
                onDiscardPileDragActiveChange(true)
                beginDraggingSession(with: [draggingItem], event: event, source: self)
                return
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
            didStartDiscardPileDrag = false
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

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onDiscardPileDragActiveChange(false)
        }

        private func discardPileDraggingItem(
            for item: SunburstDiscardPileDragItem,
            at location: CGPoint
        ) -> NSDraggingItem? {
            guard let data = try? JSONEncoder().encode(item.payload) else { return nil }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(
                data,
                forType: NSPasteboard.PasteboardType(DiscardPileDragPayload.contentType.identifier)
            )

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let size = Self.discardPileDragImageSize
            draggingItem.setDraggingFrame(
                NSRect(
                    x: location.x - (size.width / 2),
                    y: location.y - (size.height / 2),
                    width: size.width,
                    height: size.height
                ),
                contents: discardPileDragImage(for: item.segment)
            )
            return draggingItem
        }

        private func discardPileDragImage(for segment: SunburstSegment) -> NSImage {
            let image = NSImage(size: Self.discardPileDragImageSize)
            image.lockFocus()
            defer { image.unlockFocus() }

            let bounds = NSRect(origin: .zero, size: Self.discardPileDragImageSize)
            let segmentPath = segmentGhostPath(
                for: segment,
                in: bounds.insetBy(dx: 4, dy: 4)
            )

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            dragColor(for: segment).withAlphaComponent(0.9).setFill()
            segmentPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.62).setStroke()
            segmentPath.lineWidth = 1.5
            segmentPath.stroke()

            return image
        }

        private func segmentGhostPath(for segment: SunburstSegment, in rect: NSRect) -> NSBezierPath {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerRadius = min(rect.width, rect.height) / 2
            let innerRadius = max(outerRadius - 10, outerRadius * 0.42)
            let span = positiveAngleSpan(from: segment.startAngle.radians, to: segment.endAngle.radians)
            let displaySpan = min(max(span, .pi / 3), .pi * 1.35)
            let midpoint = segment.startAngle.radians + (span / 2) - (.pi / 2)
            let startAngle = midpoint - (displaySpan / 2)
            let endAngle = midpoint + (displaySpan / 2)

            let path = NSBezierPath()
            path.move(to: point(on: center, radius: outerRadius, angle: startAngle))
            path.appendArc(
                withCenter: center,
                radius: outerRadius,
                startAngle: degrees(-startAngle),
                endAngle: degrees(-endAngle),
                clockwise: true
            )
            path.line(to: point(on: center, radius: innerRadius, angle: endAngle))
            path.appendArc(
                withCenter: center,
                radius: innerRadius,
                startAngle: degrees(-endAngle),
                endAngle: degrees(-startAngle),
                clockwise: false
            )
            path.close()
            return path
        }

        private func dragColor(for segment: SunburstSegment) -> NSColor {
            let components = SunburstColorResolver.components(for: segment.colorToken)
            return NSColor(
                calibratedHue: CGFloat(components.hue),
                saturation: CGFloat(components.saturation),
                brightness: CGFloat(components.brightness),
                alpha: 1
            )
        }

        private func positiveAngleSpan(from start: Double, to end: Double) -> Double {
            let fullCircle = Double.pi * 2
            let rawSpan = end - start
            guard rawSpan > 0 else { return fullCircle }

            let remainder = rawSpan.truncatingRemainder(dividingBy: fullCircle)
            return remainder == 0 ? fullCircle : remainder
        }

        private func point(on center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
            CGPoint(
                x: center.x + (cos(angle) * radius),
                y: center.y - (sin(angle) * radius)
            )
        }

        private func degrees(_ radians: Double) -> CGFloat {
            CGFloat(radians * 180 / .pi)
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
