import AppKit
import SwiftUI

struct TreemapFileDragItem {
    let session: FileDragSession
    let segment: TreemapSegment
}

struct TreemapInteractionOverlay: NSViewRepresentable {
    let attachViewport: (NSView) -> Void
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onQuickLook: () -> Bool
    let onMove: (ChartSpatialSelectionDirection) -> Bool
    let onPan: (CGSize, CGPoint) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let canStartPan: (CGPoint) -> Bool
    let fileDragItem: (CGPoint) -> TreemapFileDragItem?
    let onDiscardPileDragActiveChange: (Bool) -> Void
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
        view.isPanEnabled = isPanEnabled
    }

    final class InteractionView: ChartViewportInteractionView {
        var fileDragItem: (CGPoint) -> TreemapFileDragItem? = { _ in nil }

        private static let dragImageSize = NSSize(width: 54, height: 38)

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
                contents: dragImage(for: item.segment)
            )
            return draggingItem
        }

        private func dragImage(for segment: TreemapSegment) -> NSImage {
            NSImage(size: Self.dragImageSize, flipped: false) { bounds in
                let tileRect = bounds.insetBy(dx: 4, dy: 4)
                let path = NSBezierPath(roundedRect: tileRect, xRadius: 6, yRadius: 6)

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.shadowBlurRadius = 5
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                self.dragColor(for: segment).withAlphaComponent(0.9).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.white.withAlphaComponent(0.62).setStroke()
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
        }

        private func dragColor(for segment: TreemapSegment) -> NSColor {
            let appearance: TreemapColorAppearance = effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua ? .dark : .light
            let components = TreemapColorResolver.components(
                for: segment.colorToken,
                appearance: appearance
            )
            return NSColor(
                calibratedHue: CGFloat(components.hue),
                saturation: CGFloat(components.saturation),
                brightness: CGFloat(components.brightness),
                alpha: 1
            )
        }
    }
}
