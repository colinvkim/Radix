import Combine
import Foundation

/// Serializes app-level sheets and dialogs so SwiftUI is never asked to present
/// competing modal flows from the workspace window.
@MainActor
final class AppPresentationCoordinator: ObservableObject {
    enum Sheet: Hashable, Identifiable {
        case onboarding
        case discardPileReview
        case importPreview(URL)
        case comparisonSetup(UUID)

        var id: String {
            switch self {
            case .onboarding:
                "onboarding"
            case .discardPileReview:
                "discard-pile-review"
            case .importPreview(let url):
                "import-preview-\(url.absoluteString)"
            case .comparisonSetup(let id):
                "comparison-setup-\(id.uuidString)"
            }
        }

        fileprivate var kind: DestinationKind {
            switch self {
            case .onboarding: .onboarding
            case .discardPileReview: .discardPileReview
            case .importPreview: .importPreview
            case .comparisonSetup: .comparisonSetup
            }
        }
    }

    enum Dialog: Hashable {
        case error
        case trashConfirmation
        case cloudFileConfirmation

        fileprivate var kind: DestinationKind {
            switch self {
            case .error: .error
            case .trashConfirmation: .trashConfirmation
            case .cloudFileConfirmation: .cloudFileConfirmation
            }
        }
    }

    enum Destination: Hashable {
        case sheet(Sheet)
        case dialog(Dialog)

        fileprivate var kind: DestinationKind {
            switch self {
            case .sheet(let sheet): sheet.kind
            case .dialog(let dialog): dialog.kind
            }
        }
    }

    enum ArchiveImportDisposition: Equatable {
        case startNow
        case queued
    }

    enum DestinationKind: Hashable {
        case onboarding
        case discardPileReview
        case importPreview
        case comparisonSetup
        case error
        case trashConfirmation
        case cloudFileConfirmation
    }

    private enum QueueEntry: Hashable {
        case destination(Destination)
        case archiveImport(URL)
    }

    @Published private(set) var activeDestination: Destination?
    private var queue: [QueueEntry] = []

    init(initialDestination: Destination? = nil) {
        activeDestination = initialDestination
    }

    var activeSheet: Sheet? {
        guard case .sheet(let sheet) = activeDestination else { return nil }
        return sheet
    }

    var activeDialog: Dialog? {
        guard case .dialog(let dialog) = activeDestination else { return nil }
        return dialog
    }

    func present(_ destination: Destination) {
        if activeDestination?.kind == destination.kind {
            activeDestination = destination
            return
        }

        if let queuedIndex = queue.firstIndex(where: { entry in
            guard case .destination(let queuedDestination) = entry else { return false }
            return queuedDestination.kind == destination.kind
        }) {
            queue[queuedIndex] = .destination(destination)
            return
        }

        guard activeDestination == nil else {
            queue.append(.destination(destination))
            return
        }
        activeDestination = destination
    }

    /// Removes a presentation whether it is active or still waiting. If removing
    /// the active presentation exposes a deferred archive open, its URL is returned
    /// to the owner so it can begin reading the preview.
    func cancel(kind: DestinationKind) -> URL? {
        queue.removeAll { entry in
            guard case .destination(let destination) = entry else { return false }
            return destination.kind == kind
        }

        guard activeDestination?.kind == kind else { return nil }
        activeDestination = nil
        return advance()
    }

    func requestArchiveImport(_ url: URL) -> ArchiveImportDisposition {
        guard activeDestination != nil || !queue.isEmpty else {
            return .startNow
        }
        guard !queue.contains(.archiveImport(url)) else { return .queued }
        queue.append(.archiveImport(url))
        return .queued
    }

    func reset() {
        queue.removeAll(keepingCapacity: false)
        activeDestination = nil
    }

    private func advance() -> URL? {
        guard activeDestination == nil, !queue.isEmpty else { return nil }
        switch queue.removeFirst() {
        case .destination(let destination):
            activeDestination = destination
            return nil
        case .archiveImport(let url):
            return url
        }
    }
}
