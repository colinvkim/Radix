import AppKit

@MainActor
class ChartViewportInteractionView: ChartKeyboardInteractionView, NSDraggingSource {
    var onHover: (CGPoint?) -> Void = { _ in }
    var onClick: (CGPoint, Int) -> Void = { _, _ in }
    var onPan: (CGSize, CGPoint) -> Void = { _, _ in }
    var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
    var canStartPan: (CGPoint) -> Bool = { _ in false }
    var onDragActiveChange: (Bool) -> Void = { _ in }
    var help: (CGPoint) -> String? = { _ in nil }
    var isPanEnabled = false
    var fileDragSession: FileDragSession?

    private static let dragThreshold: CGFloat = 3

    private var trackingArea: NSTrackingArea?
    private enum PointerGesture {
        case idle
        case pressed(CGPoint, prefersPan: Bool)
        case click(CGPoint)
        case panning(CGPoint)
        case dragging
    }

    private var gesture = PointerGesture.idle

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
        focusForKeyboardInput()
        let location = eventLocation(event)
        gesture = .pressed(location, prefersPan: isPanEnabled && canStartPan(location))
    }

    override func mouseDragged(with event: NSEvent) {
        let location = eventLocation(event)
        let previous: CGPoint
        switch gesture {
        case .pressed(let origin, let prefersPan):
            guard didExceedDragThreshold(from: origin, to: location) else { return }
            if !prefersPan, let item = draggingItem(at: origin) {
                gesture = .dragging
                fileDragSession?.begin()
                onDragActiveChange(fileDragSession?.canCollect == true)
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
            guard isPanEnabled else {
                gesture = .click(origin)
                return
            }
            previous = origin
        case .panning(let lastLocation):
            previous = lastLocation
        case .idle, .click, .dragging:
            return
        }

        gesture = .panning(location)
        guard isPanEnabled else { return }
        onPan(
            CGSize(width: location.x - previous.x, height: location.y - previous.y),
            location
        )
        toolTip = nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { gesture = .idle }
        switch gesture {
        case .pressed:
            onClick(eventLocation(event), event.clickCount)
        case .click(let origin):
            onClick(origin, event.clickCount)
        case .idle, .panning, .dragging:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        let location = eventLocation(event)
        onMagnify(location, max(0.75, 1 + event.magnification))
        toolTip = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let location = eventLocation(event)
        let zoomModifiers: NSEvent.ModifierFlags = [.command, .option]

        if !event.modifierFlags.isDisjoint(with: zoomModifiers) {
            let factor = ChartScrollInput.zoomFactor(
                CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                isPrecise: event.hasPreciseScrollingDeltas
            )
            guard factor != 1 else { return }
            onMagnify(location, factor)
            toolTip = nil
            return
        }

        if isPanEnabled {
            guard let panDelta = panDelta(for: event) else { return }
            onPan(panDelta, location)
            toolTip = nil
            return
        }

        super.scrollWheel(with: event)
    }

    func draggingItem(at location: CGPoint) -> NSDraggingItem? {
        nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        fileDragSession?.operationMask(for: context) ?? []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let completedSession = fileDragSession
        fileDragSession = nil
        gesture = .idle
        onDragActiveChange(false)
        completedSession?.end(at: screenPoint, operation: operation)
    }

    private func updatePointerFeedback(at location: CGPoint) {
        onHover(location)
        toolTip = help(location)
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
        let delta = ChartScrollInput.panDelta(
            CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas
        )
        return delta == .zero ? nil : delta
    }
}
