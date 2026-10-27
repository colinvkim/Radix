import Darwin
import Dispatch
import Foundation
import Testing

@testable import RadixCore

@MainActor
struct WorkspaceTourSessionControllerTests {
    @Test
    func testFinishingBeforePreparationRunsRemovesLateDirectoryWithoutPublishingTarget() async throws {
        let root = URL(filePath: "/private/tmp/radix-tour-cancellation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = open(root.path, O_EVTONLY)
        try #require(descriptor >= 0)
        let observation = TourDirectoryChanges()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .global()
        )
        source.setEventHandler { @Sendable in Task { await observation.record() } }
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.resume()
        defer { source.cancel() }
        let controller = WorkspaceTourSessionController(directoryRootURL: root)
        defer { controller.finish() }
        var targets: [ScanTarget] = []
        controller.onPrepared = { targets.append($0) }
        controller.onFailure = { Issue.record("Cancelled preparation must not publish an error: \($0)") }

        controller.begin(returningTo: makeReturnState())
        controller.finish()

        #expect(!controller.isActive)
        #expect(controller.savedWorkspace == nil)
        try await waitUntil("cancelled preparation removes its late directory", timeout: 15) {
            guard await observation.observed else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true
        }
        #expect(targets.isEmpty)
        #expect(controller.directory == nil)
        #expect(!controller.isActive)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func testFinishingPreparedSessionClearsStateAndRemovesItsDirectory() async throws {
        let fixture = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "tours", directoryHint: .isDirectory)
        let sentinel = fixture.appending(path: "outside-sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let controller = WorkspaceTourSessionController(directoryRootURL: root)
        defer { controller.finish() }
        var targets: [ScanTarget] = []
        controller.onPrepared = { targets.append($0) }
        controller.onFailure = { Issue.record("Practice preparation failed: \($0)") }

        controller.begin(returningTo: makeReturnState())
        let sessionID = try #require(controller.sessionID)
        controller.begin(returningTo: makeReturnState())
        #expect(controller.sessionID == sessionID)
        try await waitUntil("tour directory prepared") { targets.count == 1 }
        let directory = try #require(controller.directory)
        #expect(directory.containerURL.deletingLastPathComponent() == root)
        #expect(controller.contains(directory.target))
        #expect(controller.contains(ScanTarget(url: directory.target.url.appending(path: "child"))))
        #expect(!controller.contains(ScanTarget(url: URL(filePath: directory.target.url.path + "-other"))))
        #expect(!controller.contains(nil))
        #expect(controller.savedWorkspace?.visualization == .treemap)
        controller.restoreDefaultPreferences()
        #expect(controller.savedWorkspace?.visualization == .sunburst)

        controller.finish()

        #expect(!controller.isActive)
        #expect(controller.sessionID == nil)
        #expect(controller.directory == nil)
        #expect(controller.savedWorkspace == nil)
        try await waitUntil("tour directory removed") {
            !FileManager.default.fileExists(atPath: directory.containerURL.path)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func testPreparationFailureDoesNotPublishATarget() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "blocked-root")
        try Data("existing file".utf8).write(to: root)
        let controller = WorkspaceTourSessionController(directoryRootURL: root)
        defer { controller.finish() }
        var failed = false
        controller.onFailure = { _ in failed = true }
        controller.onPrepared = { _ in Issue.record("Failed preparation must not publish a scan target.") }

        controller.begin(returningTo: makeReturnState())
        try await waitUntil("tour preparation failure") { failed }

        #expect(controller.directory == nil)
        #expect(controller.isActive)
        controller.finish()
        #expect(!controller.isActive)
        #expect(try Data(contentsOf: root) == Data("existing file".utf8))
    }

    private func makeReturnState() -> WorkspaceTourSessionController.ReturnState {
        .init(
            scan: .init(
                snapshot: nil, completedSnapshot: nil, target: nil, phase: .idle,
                metrics: ScanMetrics(), executionMode: nil, errorMessage: nil, completionNotice: nil
            ),
            navigation: .empty,
            discardPile: .init(),
            sidebarTargetID: nil,
            visualization: .treemap
        )
    }
}

private actor TourDirectoryChanges {
    private(set) var observed = false

    func record() { observed = true }
}
