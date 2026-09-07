import Combine
import Foundation

@MainActor
final class WorkspaceTourSessionController: ObservableObject {
    struct ReturnState {
        let scan: ScanCoordinator.WorkspaceState
        let navigation: WorkspaceNavigationState
        let discardPile: DiscardPileState
        let sidebarTargetID: String?
        let visualization: ScanVisualizationMode
    }

    @Published private(set) var sessionID: UUID?
    private(set) var directory: TourPracticeDirectory?
    private var returnState: ReturnState?
    private var preparationTask: Task<Void, Never>?
    private weak var currentFileBrowser: FileBrowserModel?
    private var previousFileBrowser: FileBrowserModel?
    private var fileBrowserToRestore: (snapshotID: UUID, model: FileBrowserModel)?

    var onPrepared: ((ScanTarget) -> Void)?
    var onFailure: ((Error) -> Void)?

    var isActive: Bool { sessionID != nil }

    func begin(returningTo state: ReturnState) {
        guard !isActive else { return }
        let id = UUID()
        returnState = state
        previousFileBrowser = currentFileBrowser
        sessionID = id
        preparationTask = Task { [weak self] in
            do {
                let directory = try await Task.detached(priority: .userInitiated) {
                    try TourPracticeDirectory.create()
                }.value
                guard let self, !Task.isCancelled, sessionID == id else {
                    Task.detached(priority: .utility) { directory.remove() }
                    return
                }
                self.directory = directory
                preparationTask = nil
                onPrepared?(directory.target)
            } catch {
                guard let self, !Task.isCancelled, sessionID == id else { return }
                preparationTask = nil
                onFailure?(error)
            }
        }
    }

    func contains(_ target: ScanTarget?) -> Bool {
        guard let root = directory?.target.url.path, let path = target?.url.path else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    /// The caller restores the workspace before ending ownership of the session.
    var savedWorkspace: ReturnState? { returnState }

    func makeFileBrowser(snapshotID: UUID?) -> FileBrowserModel {
        let model: FileBrowserModel
        if let saved = fileBrowserToRestore, saved.snapshotID == snapshotID {
            model = saved.model
        } else {
            model = FileBrowserModel()
        }
        fileBrowserToRestore = nil
        currentFileBrowser = model
        return model
    }

    func finish() {
        preparationTask?.cancel()
        preparationTask = nil
        if let directory {
            Task.detached(priority: .utility) { directory.remove() }
        }
        if let previousFileBrowser, previousFileBrowser !== currentFileBrowser,
           let snapshotID = returnState?.scan.snapshot?.id {
            fileBrowserToRestore = (snapshotID, previousFileBrowser)
        }
        previousFileBrowser = nil
        directory = nil
        returnState = nil
        sessionID = nil
    }

    isolated deinit { finish() }
}
