import Darwin
import Foundation
import Testing

@testable import RadixCore

struct PermanentDeletionRecoveryTests {
    @Test
    func interruptedCaptureWaitsForTheOwnerAndPreservesAReplacement() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "receipts")
        let parent = root.appending(path: "folder")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let target = parent.appending(path: "selected")
        let survivor = Data("surviving contents".utf8)
        let replacement = Data("replacement".utf8)
        try survivor.write(to: target)

        let stage = try registerStagingDirectory(for: target, journal: journal)
        let captured = stage.appending(path: target.lastPathComponent)
        let owner = open(stage.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(owner != -1)
        defer { close(owner) }
        try #require(flock(owner, LOCK_EX | LOCK_NB) == 0)
        try FileManager.default.moveItem(at: target, to: captured)
        #expect(await PermanentDeletionRecovery.restoreInterrupted(in: journal).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: captured) == survivor)

        try #require(flock(owner, LOCK_UN) == 0)
        try replacement.write(to: target)
        let conflicts = await PermanentDeletionRecovery.restoreInterrupted(in: journal)
        #expect(conflicts.first?.localizedDescription.contains(captured.path) == true)
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try Data(contentsOf: captured) == survivor)

        try FileManager.default.moveItem(at: target, to: root.appending(path: "replacement"))
        let renamedParent = root.appending(path: "renamed")
        try FileManager.default.moveItem(at: parent, to: renamedParent)
        async let first = PermanentDeletionRecovery.restoreInterrupted(in: journal)
        async let second = PermanentDeletionRecovery.restoreInterrupted(in: journal)
        let failures = await first + second
        #expect(failures.isEmpty)
        #expect(try Data(contentsOf: renamedParent.appending(path: target.lastPathComponent)) == survivor)
        #expect(!FileManager.default.fileExists(atPath: renamedParent.appending(path: stage.lastPathComponent).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
    }

    @Test
    func interruptingBeforeCaptureLeavesTheOriginalAlone() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "receipts")
        let target = root.appending(path: "selection")
        let contents = Data("original".utf8)
        try contents.write(to: target)
        let stage = try registerStagingDirectory(for: target, journal: journal)

        #expect(await PermanentDeletionRecovery.restoreInterrupted(in: journal).isEmpty)
        #expect(try Data(contentsOf: target) == contents)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
    }

    private func registerStagingDirectory(for target: URL, journal: URL) throws -> URL {
        let parent = target.deletingLastPathComponent()
        let stagingID = UUID()
        let stage = parent.appending(path: ".radix-delete-\(stagingID.uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var parentStatus = stat()
        var stagingStatus = stat()
        try #require(lstat(parent.path, &parentStatus) == 0)
        try #require(lstat(stage.path, &stagingStatus) == 0)
        _ = try PermanentDeletionRecovery.register(
            parentURL: parent, stagingID: stagingID, leaf: target.lastPathComponent,
            parentStatus: parentStatus, stagingStatus: stagingStatus, in: journal
        )
        return stage
    }
}
