import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserTableAdapter: NSViewRepresentable {
    let presentation: BrowserPresentation
    let controller: FileDragController
    let onDragActiveChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(adapter: self) }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.adapter = self
        DispatchQueue.main.async { view.attach?() }
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.attach = nil
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        var attach: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.attach?() } }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate, NSDraggingSource {
        var adapter: FileBrowserTableAdapter
        private var laidOutContentContext: FileBrowserDisplayContext?
        private weak var table: NSTableView?
        private lazy var pan: NSPanGestureRecognizer = {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(beginDrag(_:)))
            pan.delaysPrimaryMouseButtonEvents = true
            pan.delegate = self
            return pan
        }()
        private var press: (event: NSEvent, row: Int, context: FileBrowserDisplayContext)?
        private var session: FileDragSession?

        init(adapter: FileBrowserTableAdapter) {
            self.adapter = adapter
            super.init()
        }

        func attach(from view: NSView) {
            var ancestor = view.superview
            while let container = ancestor {
                if let candidate = Self.table(in: container) {
                    if table !== candidate {
                        detach()
                        table = candidate
                        candidate.addGestureRecognizer(pan)
                    }
                    refreshRowHeights(in: candidate)
                    return
                }
                ancestor = container.superview
            }
        }

        private func refreshRowHeights(in table: NSTableView) {
            let contentContext = adapter.presentation.context
            guard laidOutContentContext != contentContext else { return }
            let visibleRows = table.rows(in: table.visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            let end = min(NSMaxRange(visibleRows), table.numberOfRows)
            guard visibleRows.location < end else { return }
            laidOutContentContext = contentContext
            // A rescan can add a subtitle without changing the row's identity.
            // Invalidate after SwiftUI has updated the displayed cell contents.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: visibleRows.location..<end))
            }
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfColumns > 1 {
                return table
            }
            for child in view.subviews {
                if let table = table(in: child) { return table }
            }
            return nil
        }

        func detach() {
            table?.removeGestureRecognizer(pan)
            table = nil
            press = nil
            laidOutContentContext = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard event.type == .leftMouseDown, event.clickCount == 1,
                  !event.modifierFlags.contains(.control),
                  let table else { return false }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            let presentation = adapter.presentation
            guard presentation.nodes.indices.contains(row),
                  adapter.controller.canAttemptDrag(nodeID: presentation.nodes[row].id) else { return false }
            press = (event, row, presentation.context)
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer
        ) -> Bool {
            guard let press, let table, other.view === table, other is NSPanGestureRecognizer else { return false }
            // Let the table extend a modified selection before the drag reads it.
            return !press.event.modifierFlags.isDisjoint(with: [.command, .shift])
                && !table.selectedRowIndexes.contains(press.row)
        }

        @objc private func beginDrag(_ pan: NSPanGestureRecognizer) {
            let presentation = adapter.presentation
            guard pan.state == .began, session == nil, let press, let table,
                  press.context == presentation.context,
                  presentation.nodes.indices.contains(press.row),
                  table.numberOfRows == presentation.nodes.count else { return }
            let selection = table.selectedRowIndexes
            let rows = selection.contains(press.row) ? selection : IndexSet(integer: press.row)
            let ids = rows.map { presentation.nodes[$0].id }
            guard let session = adapter.controller.prepare(nodeIDs: ids) else { return }
            if rows != selection {
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
            let visible = table.rows(in: table.visibleRect)
            var previewRows = IndexSet()
            let items = rows.compactMap { row -> NSDraggingItem? in
                guard let writer = session.pasteboardWriter(for: presentation.nodes[row].id) else { return nil }
                if NSLocationInRange(row, visible) { previewRows.insert(row) }
                return NSDraggingItem(pasteboardWriter: writer)
            }
            guard let firstItem = items.first else { return }

            var offset = NSPoint.zero
            let image: NSImage
            if previewRows.isEmpty {
                // A selected offscreen folder can own every visible selected descendant.
                image = NSWorkspace.shared.icon(for: session.nodes.first?.isDirectory == true ? .folder : .data)
            } else {
                image = table.dragImageForRows(
                    with: previewRows, tableColumns: Array(table.tableColumns.prefix(1)), event: press.event, offset: &offset
                )
            }
            let point = table.convert(press.event.locationInWindow, from: nil)
            let frame = NSRect(
                x: point.x - image.size.width / 2 + offset.x,
                y: point.y - image.size.height / 2 + offset.y,
                width: image.size.width,
                height: image.size.height
            )
            firstItem.setDraggingFrame(frame, contents: image)
            for item in items.dropFirst() { item.setDraggingFrame(frame, contents: nil) }

            self.session = session
            session.begin()
            adapter.onDragActiveChange(session.canCollect)
            if #available(macOS 27, *) {
                if table.beginDraggingSession(items: items, gesture: pan, source: self) == nil {
                    session.end(operation: [])
                    self.session = nil
                    adapter.onDragActiveChange(false)
                }
            } else {
                table.beginDraggingSession(with: items, event: press.event, source: self)
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            self.session?.operationMask(for: context) ?? []
        }

        func draggingSession(
            _ draggingSession: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            let completed = session
            session = nil
            adapter.onDragActiveChange(false)
            completed?.end(at: screenPoint, operation: operation)
        }
    }
}
