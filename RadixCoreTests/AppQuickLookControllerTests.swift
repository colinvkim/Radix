import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppQuickLookControllerTests {
    private let first = makeTestFileNode(id: "/preview/a.txt", name: "a.txt", size: 10)
    private let second = makeTestFileNode(id: "/preview/b.txt", name: "b.txt", size: 20)

    @Test
    func selectionDoesNotOpenPreviewAndUnchangedPreviewDoesNotRevalidate() async throws {
        let delegate = PreviewDelegate(nodes: [first])
        var validations = 0
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = { _, _ in validations += 1 }
        let controller = AppQuickLookController(systemActions: actions)
        controller.delegate = delegate

        controller.syncVisiblePreview()
        #expect(!controller.isActive)
        #expect(validations == 0)
        controller.previewSelected()
        try await waitUntil { controller.session != nil }
        controller.syncVisiblePreview()
        controller.setPreviewSelection(first.url)
        #expect(validations == 1)
        #expect(controller.session?.selection == first.url)
    }

    @Test
    func groupUsesDisplayedOrderAndPreviewNavigationPreservesSelectedGroup() async throws {
        let delegate = PreviewDelegate(nodes: [first, second], primaryURL: first.url)
        let browser = FileBrowserModel()
        browser.updateContent(makeBrowserTestNavigation(children: [first, second], rootID: "/preview").browserContent())
        let controller = AppQuickLookController(systemActions: .inert)
        controller.delegate = delegate
        controller.fileBrowser = browser

        controller.previewSelected()
        try await waitUntil { controller.session != nil }
        #expect(controller.session?.urls == [second.url, first.url])
        #expect(controller.session?.selection == first.url)
        controller.setPreviewSelection(second.url)
        #expect(controller.session?.selection == second.url)
        #expect(delegate.quickLookSelectionContext.selectedNodes == [first, second])
        controller.setPreviewSelection(URL(filePath: "/outside.txt"))
        #expect(controller.session?.selection == second.url)

        controller.setPreviewSelection(nil)
        #expect(controller.session == nil)
        #expect(!controller.isActive)
        #expect(delegate.quickLookSelectionContext.selectedNodes == [first, second])
    }

    @Test
    func primaryItemPreviewStaysScopedToPrimarySelection() async throws {
        let delegate = PreviewDelegate(nodes: [first, second], primaryURL: second.url)
        let controller = AppQuickLookController(systemActions: .inert)
        controller.delegate = delegate
        controller.previewSelected(scope: .primaryItem)
        try await waitUntil { controller.session != nil }
        #expect(controller.session?.urls == [second.url])

        delegate.quickLookSelectionContext = .init(selectedNodes: [first, second], primaryURL: first.url, snapshotSource: .live)
        controller.syncVisiblePreview()
        try await waitUntil { controller.session?.selection == first.url }
        #expect(controller.session?.urls == [first.url])
    }

    @Test
    func changingGroupRetainsCurrentItemUntilItLeavesTheGroup() async throws {
        let delegate = PreviewDelegate(nodes: [first, second])
        let controller = AppQuickLookController(systemActions: .inert)
        controller.delegate = delegate
        controller.previewSelected()
        try await waitUntil { controller.session != nil }
        controller.setPreviewSelection(second.url)

        let third = makeTestFileNode(id: "/preview/c.txt", name: "c.txt")
        delegate.quickLookSelectionContext = .init(selectedNodes: [first, second, third], primaryURL: first.url, snapshotSource: .live)
        controller.syncVisiblePreview()
        try await waitUntil { controller.session?.urls.count == 3 }
        #expect(controller.session?.selection == second.url)
        delegate.quickLookSelectionContext = .init(selectedNodes: [third], primaryURL: third.url, snapshotSource: .live)
        controller.syncVisiblePreview()
        try await waitUntil { controller.session?.selection == third.url }
    }

    @Test
    func importedPreviewUsesReplacementAtSavedPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preview.txt")
        try Data("original".utf8).write(to: url)
        let identity = try ScanMetadataLoader().fileSystemIdentity(at: url)
        let node = makeTestFileNode(id: url.path, name: "preview.txt", fileIdentity: identity)
        try FileManager.default.moveItem(at: url, to: directory.appending(path: "original.txt"))
        try Data("replacement".utf8).write(to: url)
        #expect(SystemIntegration.verifyTrashIdentity(node) == .mismatch)

        let delegate = PreviewDelegate(nodes: [node], source: importedSource())
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = AppSystemActions.live.validateQuickLookSelection
        let controller = AppQuickLookController(systemActions: actions)
        controller.delegate = delegate

        controller.previewSelected()
        try await waitUntil { controller.session != nil || !delegate.errors.isEmpty }
        #expect(controller.session?.urls == [url])
        #expect(controller.session?.selection == url)
        #expect(delegate.errors.isEmpty)
    }

    @Test
    func automaticUpdatesRejectMissingImportedPathAndFailSilently() async throws {
        let source = importedSource()
        let delegate = PreviewDelegate(nodes: [first], source: source)
        var checked: [URL] = []
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = { nodes, source in
            for node in nodes {
                checked.append(node.url)
                try FileActionValidation.validateLivePath(
                    node, source: source, fileExists: { $0 != second.url })
            }
        }
        let controller = AppQuickLookController(systemActions: actions)
        controller.delegate = delegate
        controller.previewSelected()
        try await waitUntil { controller.session != nil }

        delegate.quickLookSelectionContext = .init(selectedNodes: [second], primaryURL: second.url, snapshotSource: source)
        controller.syncVisiblePreview()
        try await waitUntil { !controller.isActive }
        #expect(controller.session == nil)
        #expect(checked == [first.url, second.url])
        #expect(delegate.errors.isEmpty)
    }

    @Test
    func explicitFailureRejectsWholeGroupAndDismissalNeedsNoValidation() async throws {
        let delegate = PreviewDelegate(nodes: [first])
        var fails = false
        var validations = 0
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = { _, _ in
            validations += 1
            if fails { throw FileActionError.unavailable(path: "/missing") }
        }
        let controller = AppQuickLookController(systemActions: actions)
        controller.delegate = delegate
        controller.previewSelected()
        try await waitUntil { controller.session != nil }
        fails = true
        controller.toggleSelected()
        #expect(controller.session == nil)
        #expect(validations == 1)
        #expect(delegate.errors.isEmpty)

        delegate.quickLookSelectionContext = .init(selectedNodes: [first, second], primaryURL: first.url, snapshotSource: .live)
        controller.previewSelected()
        try await waitUntil { !controller.isActive }
        #expect(controller.session == nil)
        #expect(delegate.errors.count == 1)
    }

    @Test
    func disallowedSelectionsNeverReachFilesystemValidation() {
        let synthetic = makeTestFileNode(id: "/synthetic", name: "synthetic", isSynthetic: true)
        var validations = 0
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = { _, _ in validations += 1 }
        let controller = AppQuickLookController(systemActions: actions)
        let delegate = PreviewDelegate(nodes: [first, synthetic])
        controller.delegate = delegate
        controller.previewSelected()
        #expect(!controller.isActive)
        delegate.quickLookSelectionContext = .init(selectedNodes: [first], primaryURL: first.url, snapshotSource: importedSource(capability: .disabled))
        controller.previewSelected()
        #expect(!controller.isActive)
        delegate.quickLookSelectionContext = .init(selectedNodes: [], primaryURL: nil, snapshotSource: .live)
        controller.previewSelected()
        #expect(!controller.isActive)
        #expect(validations == 0)
        #expect(delegate.errors.count == 3)
    }

    @Test
    func cancelledPreparationCannotReopenAndLatestSelectionWins() async throws {
        let gate = PreviewValidationGate()
        var actions = AppSystemActions.inert
        actions.validateQuickLookSelection = { _, _ in try await gate.wait() }
        let delegate = PreviewDelegate(nodes: [first])
        let controller = AppQuickLookController(systemActions: actions)
        controller.delegate = delegate
        controller.previewSelected()
        try await waitUntil { gate.pending.count == 1 }
        controller.toggleSelected()
        gate.pending[0].resume()
        try await waitUntil { gate.returned == 1 }
        #expect(controller.session == nil)
        #expect(!controller.isActive)

        controller.previewSelected()
        try await waitUntil { gate.pending.count == 2 }
        delegate.quickLookSelectionContext = .init(selectedNodes: [second], primaryURL: second.url, snapshotSource: .live)
        controller.syncVisiblePreview()
        try await waitUntil { gate.pending.count == 3 }
        gate.pending[2].resume()
        try await waitUntil { controller.session?.selection == second.url }
        gate.pending[1].resume()
        try await waitUntil { gate.returned == 3 }
        #expect(controller.session?.selection == second.url)
    }
}

@MainActor
private final class PreviewDelegate: AppQuickLookControllerDelegate {
    var quickLookSelectionContext: AppQuickLookSelectionContext
    var errors: [Error] = []

    init(nodes: [FileNodeRecord], primaryURL: URL? = nil, source: ScanSnapshotSource = .live) {
        quickLookSelectionContext = .init(selectedNodes: nodes, primaryURL: primaryURL ?? nodes.first?.url, snapshotSource: source)
    }

    func appQuickLookController(_ controller: AppQuickLookController, didFailWith error: Error) {
        errors.append(error)
    }
}

@MainActor
private final class PreviewValidationGate {
    var pending: [CheckedContinuation<Void, Error>] = []
    var returned = 0

    func wait() async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
        returned += 1
    }
}

private func importedSource(capability: ImportedSnapshotLiveActionCapability = .pathValidation) -> ScanSnapshotSource {
    .imported(.init(sourceURL: URL(filePath: "/scan.radixscan"), pathMode: .absolute, liveActionCapability: capability))
}
