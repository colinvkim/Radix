import Combine
import Foundation

struct AppQuickLookSelectionContext {
    let selectedNodes: [FileNodeRecord]
    let primaryURL: URL?
    let snapshotSource: ScanSnapshotSource
}

@MainActor
protocol AppQuickLookControllerDelegate: AnyObject {
    var quickLookSelectionContext: AppQuickLookSelectionContext { get }
    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error)
}

@MainActor
final class AppQuickLookController: ObservableObject {
    struct Session: Equatable {
        let urls: [URL]
        var selection: URL
    }

    enum SelectionScope {
        case selection
        case primaryItem
    }

    weak var delegate: (any AppQuickLookControllerDelegate)?
    weak var fileBrowser: FileBrowserModel?
    @Published private(set) var session: Session?

    private let validateSelection: ([FileNodeRecord], ScanSnapshotSource) async throws -> Void
    private var preparation: Task<Void, Never>?
    private var requestedScope: SelectionScope?

    var isActive: Bool { requestedScope != nil }

    init(systemActions: AppSystemActions) {
        validateSelection = systemActions.validateQuickLookSelection
    }

    isolated deinit {
        preparation?.cancel()
    }

    func closePreview() {
        preparation?.cancel()
        preparation = nil
        requestedScope = nil
        if session != nil { session = nil }
    }

    func previewSelected(scope: SelectionScope = .selection) {
        requestPreview(scope: scope, reportsErrors: true)
    }

    func toggleSelected() {
        if isActive {
            closePreview()
        } else {
            previewSelected()
        }
    }

    func syncVisiblePreview() {
        guard let requestedScope else { return }
        requestPreview(scope: requestedScope, reportsErrors: false)
    }

    func setPreviewSelection(_ url: URL?) {
        guard let url else {
            closePreview()
            return
        }
        guard var next = session, next.urls.contains(url), next.selection != url else { return }
        next.selection = url
        session = next
    }

    private func requestPreview(scope: SelectionScope, reportsErrors: Bool) {
        preparation?.cancel()
        preparation = nil
        guard let context = delegate?.quickLookSelectionContext else {
            closePreview()
            return
        }

        var nodes = context.selectedNodes
        if scope == .primaryItem {
            nodes = nodes.filter { $0.url == context.primaryURL }
        } else if let ordered = fileBrowser?.displayedNodes(ids: Set(nodes.map(\.id))),
                  ordered.count == nodes.count {
            nodes = ordered
        }

        guard !nodes.isEmpty, context.snapshotSource.allowsLivePathActions,
              nodes.allSatisfy({ $0.supportsFileActions && $0.url.isFileURL }) else {
            closePreview()
            if reportsErrors {
                delegate?.appQuickLookController(
                    self, didFailWith: nodes.isEmpty ? FileActionError.noSelection : FileActionError.unsupported
                )
            }
            return
        }

        let urls = nodes.map(\.url)
        let preferredURL = reportsErrors ? context.primaryURL : (session?.selection ?? context.primaryURL)
        let selection = preferredURL.flatMap { urls.contains($0) ? $0 : nil } ?? urls[0]
        let next = Session(urls: urls, selection: selection)
        requestedScope = scope
        guard next != session else { return }

        let validateSelection = self.validateSelection
        preparation = Task { [weak self] in
            do {
                try await validateSelection(nodes, context.snapshotSource)
                guard !Task.isCancelled, let self else { return }
                preparation = nil
                session = next
            } catch {
                guard !Task.isCancelled, let self else { return }
                closePreview()
                if reportsErrors {
                    delegate?.appQuickLookController(self, didFailWith: error)
                }
            }
        }
    }
}
