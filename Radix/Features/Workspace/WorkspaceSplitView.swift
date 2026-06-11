import AppKit
import SwiftUI

/// Pure SwiftUI replacement for `VSplitView`.
///
/// `VSplitView` (NSSplitView-backed) combined with `.inspector` makes AppKit
/// re-enter the Update Constraints in Window pass until NSWindow throws
/// `NSGenericException` ("more Update Constraints in Window passes than there
/// are views in the window"), crashing the app once scan content is visible.
struct WorkspaceSplitView<Top: View, Bottom: View>: View {
    private static var dividerHitHeight: CGFloat { 9 }

    let topMinHeight: CGFloat
    let bottomMinHeight: CGFloat
    private let top: Top
    private let bottom: Bottom

    @State private var topFraction: CGFloat = 0.56
    @State private var dragStartFraction: CGFloat?

    init(
        topMinHeight: CGFloat,
        bottomMinHeight: CGFloat,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.topMinHeight = topMinHeight
        self.bottomMinHeight = bottomMinHeight
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { proxy in
            let contentHeight = max(proxy.size.height - Self.dividerHitHeight, 0)

            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight(forContentHeight: contentHeight))
                    .clipped()

                divider(contentHeight: contentHeight)

                bottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func divider(contentHeight: CGFloat) -> some View {
        ZStack {
            Divider()
            PaneResizeHandle(
                onDragChanged: { translationHeight in
                    guard contentHeight > 0 else { return }

                    let baseFraction = dragStartFraction ?? topFraction
                    dragStartFraction = baseFraction
                    topFraction = clampedFraction(
                        baseFraction + (translationHeight / contentHeight),
                        contentHeight: contentHeight
                    )
                },
                onDragEnded: {
                    dragStartFraction = nil
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.dividerHitHeight)
        .accessibilityLabel("Resize panes")
    }

    private func topHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        clampedFraction(topFraction, contentHeight: contentHeight) * contentHeight
    }

    private func clampedFraction(_ fraction: CGFloat, contentHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return fraction }

        let minimums = constrainedMinimumHeights(for: contentHeight)
        let lowerBound = minimums.top / contentHeight
        let upperBound = max((contentHeight - minimums.bottom) / contentHeight, lowerBound)
        return min(max(fraction, lowerBound), upperBound)
    }

    private func constrainedMinimumHeights(for totalHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let minimumHeight = topMinHeight + bottomMinHeight
        guard minimumHeight > 0, totalHeight < minimumHeight else {
            return (topMinHeight, bottomMinHeight)
        }

        let scale = max(totalHeight, 0) / minimumHeight
        return (topMinHeight * scale, bottomMinHeight * scale)
    }
}

private struct PaneResizeHandle: NSViewRepresentable {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.invalidateCursorRects()
    }

    final class HandleView: NSView {
        var onDragChanged: (CGFloat) -> Void = { _ in }
        var onDragEnded: () -> Void = {}

        private var dragStartY: CGFloat?
        private var trackingArea: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshTracking()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            refreshTracking()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            guard !bounds.isEmpty else {
                trackingArea = nil
                return
            }

            let options: NSTrackingArea.Options = [
                .activeAlways,
                .cursorUpdate,
                .enabledDuringMouseDrag,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved
            ]
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func cursorUpdate(with event: NSEvent) {
            showResizeCursor()
        }

        override func mouseEntered(with event: NSEvent) {
            showResizeCursor()
        }

        override func mouseMoved(with event: NSEvent) {
            showResizeCursor()
        }

        override func mouseExited(with event: NSEvent) {
            if dragStartY == nil {
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragStartY = event.locationInWindow.y
            showResizeCursor()
        }

        override func mouseDragged(with event: NSEvent) {
            let dragStartY = dragStartY ?? event.locationInWindow.y
            self.dragStartY = dragStartY

            onDragChanged(dragStartY - event.locationInWindow.y)
            showResizeCursor()
        }

        override func mouseUp(with event: NSEvent) {
            dragStartY = nil
            onDragEnded()
            showResizeCursor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        func refreshTracking() {
            invalidateCursorRects()
            updateTrackingAreas()
        }

        func invalidateCursorRects() {
            window?.invalidateCursorRects(for: self)
        }

        private func showResizeCursor() {
            NSCursor.resizeUpDown.set()
        }
    }
}
