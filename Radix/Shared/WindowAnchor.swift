import SwiftUI

/// Resolves the window containing a SwiftUI control at the time of its action.
struct WindowAnchor: NSViewRepresentable {
    final class Source {
        fileprivate weak var view: NSView?
        var window: NSWindow? { view?.window }
    }

    let source: Source

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        source.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
