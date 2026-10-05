import AppKit
import SwiftUI

/// Adds native file dragging to the existing SwiftUI table. All non-drag data
/// source messages remain with SwiftUI, including sorting and row updates.
struct FileBrowserDragAdapter: NSViewRepresentable {
    let nodes: [FileNodeRecord]
    let controller: FileDragController
    let onDragActiveChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.nodes = nodes
        context.coordinator.controller = controller
        context.coordinator.onDragActiveChange = onDragActiveChange
        // SwiftUI may replace its data source when it updates table contents.
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSOutlineViewDataSource {
        var nodes: [FileNodeRecord] = []
        var controller: FileDragController?
        var onDragActiveChange: (Bool) -> Void = { _ in }
        private weak var table: NSTableView?
        // Objective-C forwarding is synchronous on AppKit’s main thread.
        private nonisolated(unsafe) weak var original: (any NSTableViewDataSource)?
        private var session: FileDragSession?

        func attach(from view: NSView) {
            var ancestor = view.superview
            while let container = ancestor {
                if let candidate = Self.table(in: container) {
                    if table !== candidate { detach(); table = candidate }
                    if candidate.dataSource !== self {
                        original = candidate.dataSource
                        candidate.dataSource = self
                    }
                    return
                }
                ancestor = container.superview
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
            if let table, table.dataSource === self { table.dataSource = original }
            table = nil
            original = nil
        }

        // NSTableView uses Objective-C optional-method discovery. Forward every
        // method we do not implement instead of replacing SwiftUI's data source.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            MainActor.assumeIsolated {
                super.responds(to: selector) || original?.responds(to: selector) == true
            }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            dispatchPrecondition(condition: .onQueue(.main))
            return original
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            pasteboardWriter(forRow: row, in: tableView)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            pasteboardWriter(forRow: outlineView.row(forItem: item), in: outlineView)
        }

        private func pasteboardWriter(forRow row: Int, in tableView: NSTableView) -> (any NSPasteboardWriting)? {
            guard nodes.indices.contains(row), let controller else { return nil }
            if session == nil {
                let rows = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
                let ids = rows.compactMap { nodes.indices.contains($0) ? nodes[$0].id : nil }
                session = controller.prepare(nodeIDs: ids)
                tableView.setDraggingSourceOperationMask(session?.operationMask(for: .withinApplication) ?? [], forLocal: true)
                tableView.setDraggingSourceOperationMask(session?.operationMask(for: .outsideApplication) ?? [], forLocal: false)
            }
            return session?.pasteboardWriter(for: nodes[row].id)
        }

        func tableView(
            _ tableView: NSTableView, draggingSession: NSDraggingSession,
            willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
        ) {
            original?.tableView?(tableView, draggingSession: draggingSession, willBeginAt: screenPoint, forRowIndexes: rowIndexes)
            beginDrag()
        }

        func outlineView(
            _ outlineView: NSOutlineView, draggingSession: NSDraggingSession,
            willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
        ) {
            (original as? any NSOutlineViewDataSource)?.outlineView?(
                outlineView, draggingSession: draggingSession, willBeginAt: screenPoint, forItems: draggedItems
            )
            beginDrag()
        }

        private func beginDrag() {
            session?.begin()
            onDragActiveChange(session?.canCollect == true)
        }

        func tableView(
            _ tableView: NSTableView, draggingSession: NSDraggingSession,
            endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            original?.tableView?(tableView, draggingSession: draggingSession, endedAt: screenPoint, operation: operation)
            endDrag(operation: operation)
        }

        func outlineView(
            _ outlineView: NSOutlineView, draggingSession: NSDraggingSession,
            endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            (original as? any NSOutlineViewDataSource)?.outlineView?(
                outlineView, draggingSession: draggingSession, endedAt: screenPoint, operation: operation
            )
            endDrag(operation: operation)
        }

        private func endDrag(operation: NSDragOperation) {
            let completed = session
            session = nil
            onDragActiveChange(false)
            completed?.end(operation: operation)
        }
    }
}
