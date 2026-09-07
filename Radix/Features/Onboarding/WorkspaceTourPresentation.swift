import AppKit
import Combine
import SwiftUI

enum WorkspaceTourAnchor: Hashable {
    case workspace, diskMap, folder, folderPath, visualization, inspector, search, rescan, discardPile

    var attachmentAlignment: Alignment {
        switch self {
        case .diskMap, .folder: .trailing
        case .search, .discardPile: .top
        default: .bottom
        }
    }

    var usesCapsuleTint: Bool {
        self == .visualization || self == .inspector || self == .rescan
    }
}

private extension WorkspaceTourController.Step {
    var controlAnchor: WorkspaceTourAnchor? {
        switch self {
        case .selectResult: .diskMap
        case .openFolder: .folder
        case .visualization: .visualization
        case .inspector: .inspector
        case .search: .search
        case .rescan: .rescan
        case .markForReview, .review: .discardPile
        case .scan, .removeMark, .finished: nil
        }
    }
}

/// General guidance stays in the workspace; only specific controls get a pointer.
@MainActor
final class WorkspaceTourPresentation: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var cardStep: WorkspaceTourController.Step?
    @Published private(set) var showsFolderNavigation = false

    private final class WeakAnchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private let popover = NSPopover()
    private struct PresentationID: Equatable {
        let step: WorkspaceTourController.Step
        let showsFolderNavigation: Bool
        let viewID: ObjectIdentifier
        let windowRect: NSRect
    }
    private var lastPresentation: PresentationID?
    private var anchors: [WorkspaceTourAnchor: [WeakAnchor]] = [:]
    private weak var tour: WorkspaceTourController?
    private weak var navigation: WorkspaceNavigationModel?
    private var canPresent = false
    private var refreshIsScheduled = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = false
        for notification in [
            NSWindow.didResizeNotification, NSWindow.didEndSheetNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSView.boundsDidChangeNotification
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] notification in
                let changedWindow = notification.object as? NSWindow
                let changedView = notification.object as? NSView
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let window = changedWindow ?? changedView?.window,
                       window !== self.visibleView(for: .workspace)?.window { return }
                    self.scheduleRefresh()
                }
            })
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        popover.delegate = nil
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        scheduleRefresh()
    }

    fileprivate func register(_ anchor: WorkspaceTourAnchor, view: NSView) {
        // The responsive header has two breadcrumb layouts; retain both so only
        // the visible one can supply the path's position.
        var candidates = anchors[anchor, default: []]
        candidates.removeAll { $0.view == nil }
        if !candidates.contains(where: { $0.view === view }) {
            candidates.append(WeakAnchor(view))
        }
        anchors[anchor] = candidates
        scheduleRefresh()
    }

    fileprivate func unregister(_ anchor: WorkspaceTourAnchor, view: NSView) {
        anchors[anchor]?.removeAll { $0.view == nil || $0.view === view }
        if anchors[anchor]?.isEmpty == true { anchors[anchor] = nil }
        scheduleRefresh()
    }

    func update(
        tour: WorkspaceTourController,
        navigation: WorkspaceNavigationModel,
        canPresent: Bool
    ) {
        self.tour = tour
        self.navigation = navigation
        self.canPresent = canPresent
        scheduleRefresh()
    }

    fileprivate func controlAnchor(for step: WorkspaceTourController.Step?) -> WorkspaceTourAnchor? {
        if step == .openFolder && showsFolderNavigation { return .folderPath }
        return step?.controlAnchor
    }

    func close() {
        canPresent = false
        scheduleRefresh()
    }

    private func hidePrompt() {
        popover.close()
        if cardStep != nil { cardStep = nil }
    }

    private func showCard(for step: WorkspaceTourController.Step) {
        if cardStep != step { cardStep = step }
    }

    private func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshIsScheduled = false
            refresh()
        }
    }

    private func visibleView(for anchor: WorkspaceTourAnchor, in window: NSWindow? = nil) -> NSView? {
        anchors[anchor]?.lazy.compactMap(\.view).first { view in
            view.window != nil && (window == nil || view.window === window)
                && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
        }
    }

    private func refresh() {
        let showsFolderNavigation = tour?.step == .openFolder && navigation?.isFocusedAtRoot == false
        if self.showsFolderNavigation != showsFolderNavigation {
            self.showsFolderNavigation = showsFolderNavigation
        }
        guard canPresent, let tour, let step = tour.step, step != .scan,
              let root = visibleView(for: .workspace), let window = root.window,
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else {
            hidePrompt()
            return
        }
        guard let anchor = controlAnchor(for: step), let view = visibleView(for: anchor, in: window) else {
            popover.close()
            showCard(for: step)
            return
        }
        let rect = view.visibleRect
        let id = PresentationID(
            step: step,
            showsFolderNavigation: showsFolderNavigation,
            viewID: ObjectIdentifier(view), windowRect: view.convert(rect, to: nil)
        )
        guard id != lastPresentation || !popover.isShown else { return }
        if lastPresentation?.viewID != id.viewID { popover.close() }
        lastPresentation = id
        let content = WorkspaceTourPromptView(
            step: step,
            showsFolderNavigation: showsFolderNavigation,
            stop: { [weak tour] in tour?.stop() },
            advance: { [weak tour] in tour?.advance() }
        )
        let hosting = NSHostingController(rootView: content.frame(width: 340))
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize

        let edge: NSRectEdge
        switch anchor {
        case .search, .discardPile:
            // Leave search results and the Discard Pile drop target unobstructed.
            edge = view.isFlipped ? .minY : .maxY
        case .diskMap, .folder:
            edge = .maxX
        default:
            edge = view.isFlipped ? .maxY : .minY
        }
        // Position directly at the target's edge without window-coordinate offsets.
        popover.show(
            relativeTo: rect,
            of: view,
            preferredEdge: edge
        )
        // AppKit can decline to show while a SwiftUI control is being laid out.
        // Keep the lesson available until its anchored presentation succeeds.
        if popover.isShown {
            if cardStep != nil { cardStep = nil }
        } else {
            showCard(for: step)
        }
    }
}

struct WorkspaceTourCard: View {
    @ObservedObject var tour: WorkspaceTourController
    @ObservedObject var presentation: WorkspaceTourPresentation

    var body: some View {
        if let step = presentation.cardStep {
            WorkspaceTourPromptView(
                step: step,
                showsFolderNavigation: presentation.showsFolderNavigation,
                stop: tour.stop,
                advance: tour.advance
            )
            .frame(width: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }
}

struct WorkspaceTourHost: NSViewRepresentable {
    @ObservedObject var tour: WorkspaceTourController
    @ObservedObject var navigation: WorkspaceNavigationModel
    let presentation: WorkspaceTourPresentation
    let canPresent: Bool

    func makeNSView(context: Context) -> TourAnchorView {
        TourAnchorView(anchor: .workspace, presentation: presentation)
    }

    func updateNSView(_ view: TourAnchorView, context: Context) {
        presentation.update(tour: tour, navigation: navigation, canPresent: canPresent)
    }

    static func dismantleNSView(_ view: TourAnchorView, coordinator: ()) {
        view.presentation?.close()
    }
}

private struct TourAnchorRepresentable: NSViewRepresentable {
    let anchor: WorkspaceTourAnchor
    let presentation: WorkspaceTourPresentation

    func makeNSView(context: Context) -> TourAnchorView {
        TourAnchorView(anchor: anchor, presentation: presentation)
    }

    func updateNSView(_ view: TourAnchorView, context: Context) {}

    static func dismantleNSView(_ view: TourAnchorView, coordinator: ()) {
        view.presentation?.unregister(view.anchor, view: view)
    }
}

final class TourAnchorView: NSView {
    let anchor: WorkspaceTourAnchor
    weak var presentation: WorkspaceTourPresentation?

    init(anchor: WorkspaceTourAnchor, presentation: WorkspaceTourPresentation) {
        self.anchor = anchor
        self.presentation = presentation
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            presentation?.register(anchor, view: self)
        } else {
            presentation?.unregister(anchor, view: self)
        }
    }

    override func layout() {
        super.layout()
        if window != nil { presentation?.register(anchor, view: self) }
    }
}

private struct WorkspaceTourAnchorModifier: ViewModifier {
    @EnvironmentObject private var tour: WorkspaceTourController
    @EnvironmentObject private var presentation: WorkspaceTourPresentation
    let anchor: WorkspaceTourAnchor
    let enabled: Bool

    private var isCurrentTarget: Bool {
        enabled && presentation.controlAnchor(for: tour.step) == anchor
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isCurrentTarget && anchor != .discardPile && anchor != .diskMap {
                    if anchor.usesCapsuleTint {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.1))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    }
                }
            }
            .overlay(alignment: anchor.attachmentAlignment) {
                // Keep positioning views mounted independently of the decoration.
                if tour.isActive && enabled {
                    TourAnchorRepresentable(anchor: anchor, presentation: presentation)
                        .frame(width: 2, height: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func workspaceTourAnchor(_ anchor: WorkspaceTourAnchor, enabled: Bool = true) -> some View {
        modifier(WorkspaceTourAnchorModifier(anchor: anchor, enabled: enabled))
    }
}
