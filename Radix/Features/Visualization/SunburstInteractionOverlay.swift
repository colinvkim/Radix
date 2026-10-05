import AppKit
import SwiftUI

struct SunburstFileDragItem {
    let session: FileDragSession
    let segment: SunburstSegment
}

struct SunburstInteractionOverlay: NSViewRepresentable {
    let attachViewport: (NSView) -> Void
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onQuickLook: () -> Bool
    let onMove: (ChartSpatialSelectionDirection) -> Bool
    let onPan: (CGSize, CGPoint) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let canStartPan: (CGPoint) -> Bool
    let fileDragItem: (CGPoint) -> SunburstFileDragItem?
    let onDiscardPileDragActiveChange: (Bool) -> Void
    let help: (CGPoint) -> String?
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        update(nsView)
    }

    private func update(_ view: InteractionView) {
        attachViewport(view)
        view.onHover = onHover
        view.onClick = onClick
        view.onMove = onMove
        view.onQuickLook = onQuickLook
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.canStartPan = canStartPan
        view.fileDragItem = fileDragItem
        view.onDragActiveChange = onDiscardPileDragActiveChange
        view.help = help
        view.isPanEnabled = isPanEnabled
    }

    final class InteractionView: ChartViewportInteractionView {
        var fileDragItem: (CGPoint) -> SunburstFileDragItem? = { _ in nil }

        private static let dragImageSize = NSSize(width: 42, height: 42)
        override func draggingItem(at location: CGPoint) -> NSDraggingItem? {
            guard let item = fileDragItem(location) else { return nil }
            guard let nodeID = item.session.nodes.first?.id,
                  let writer = item.session.pasteboardWriter(for: nodeID) else { return nil }
            fileDragSession = item.session
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let size = Self.dragImageSize
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
            NSImage(size: Self.dragImageSize, flipped: false) { bounds in
                let segmentPath = self.segmentGhostPath(
                    for: segment,
                    in: bounds.insetBy(dx: 4, dy: 4)
                )

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                self.dragColor(for: segment).withAlphaComponent(0.9).setFill()
                segmentPath.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.white.withAlphaComponent(0.62).setStroke()
                segmentPath.lineWidth = 1.5
                segmentPath.stroke()

                return true
            }
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
