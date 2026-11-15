import Darwin
import Foundation
import Testing

@testable import RadixCore

struct PermanentDeletionTests {
    @Test
    func deletesFolderAndCoveredMarkWithoutFollowingNestedLink() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        let folder = root.appending(path: "Selection", directoryHint: .isDirectory)
        let nested = folder.appending(path: "Nested", directoryHint: .isDirectory)
        let child = nested.appending(path: "child")
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let sentinel = outside.appending(path: "sentinel")
        let contents = Data("keep this".utf8)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: false)
        try contents.write(to: sentinel)
        try Data().write(to: child)
        try fileManager.createSymbolicLink(at: nested.appending(path: "link"), withDestinationURL: outside)
        let childNode = try scannedNode(at: child)
        let folderNode = try scannedNode(at: folder)

        let outcome = try PermanentDeletion.remove(folderNode, at: folder) { staged in
            let stagedChild = staged.appending(path: "Nested/child")
            return SystemIntegration.verifyTrashIdentity(childNode, at: stagedChild) == .matches ? [childNode] : []
        }

        guard case .removed(let coveredMarks) = outcome else {
            Issue.record("The confirmed folder was not removed.")
            return
        }
        #expect(coveredMarks.map(\.id) == [childNode.id])
        #expect(!fileManager.fileExists(atPath: folder.path))
        #expect(try Data(contentsOf: sentinel) == contents)
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["outside"])
    }

    @Test
    func deletesFinalLinkWithoutTouchingTarget() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        let target = root.appending(path: "target")
        let link = root.appending(path: "link")
        let contents = Data("target".utf8)
        try contents.write(to: target)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.lastPathComponent)

        let outcome = try PermanentDeletion.remove(scannedNode(at: link), at: link) { _ in [] }

        guard case .removed = outcome else {
            Issue.record("The confirmed symbolic link was not removed.")
            return
        }
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["target"])
        #expect(try Data(contentsOf: target) == contents)
    }

    @Test
    func leavesReplacementAtScannedPath() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        let target = root.appending(path: "file")
        let moved = root.appending(path: "original")
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try original.write(to: target)
        let node = try scannedNode(at: target)
        try fileManager.moveItem(at: target, to: moved)
        try replacement.write(to: target)

        let outcome = try PermanentDeletion.remove(node, at: target) { _ in [] }

        guard case .unchanged(.mismatch) = outcome else {
            Issue.record("Deletion must reject the replacement and report a changed identity.")
            return
        }
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try Data(contentsOf: moved) == original)
    }

    @Test
    func leavesItemWithOnlyUnboundResourceIdentity() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        let target = root.appending(path: "selected")
        let contents = Data("original".utf8)
        try contents.write(to: target)
        let values = try target.resourceValues(forKeys: [.fileResourceIdentifierKey, .creationDateKey])
        let identifier = try #require(values.fileResourceIdentifier as? Data)
        let birthTime = try #require(values.creationDate)
        let node = makeTestFileNode(
            id: target.path,
            name: target.lastPathComponent,
            fileIdentity: FileIdentity(resourceIdentifier: identifier, birthTime: birthTime)
        )

        let outcome = try PermanentDeletion.remove(node, at: target) { _ in [] }

        guard case .unchanged(.missingScannedIdentity) = outcome else {
            Issue.record("Permanent deletion requires scan evidence tied to a native file identity.")
            return
        }
        #expect(try Data(contentsOf: target) == contents)
    }

    @Test
    func leavesOtherHardLinkToSameFile() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        let target = root.appending(path: "selected")
        let retained = root.appending(path: "retained")
        let contents = Data("shared".utf8)
        try contents.write(to: target)
        try fileManager.linkItem(at: target, to: retained)

        let outcome = try PermanentDeletion.remove(scannedNode(at: target), at: target) { _ in [] }

        guard case .removed = outcome else {
            Issue.record("The selected hard link was not removed.")
            return
        }
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["retained"])
        #expect(try Data(contentsOf: retained) == contents)
    }

    @Test(.enabled(if: geteuid() != 0))
    func restoresSurvivingFolderAtOriginalPathAfterPartialDeletion() throws {
        let root = try makeCanonicalTemporaryDirectory()
        let fileManager = FileManager.default
        let target = root.appending(path: "selected", directoryHint: .isDirectory)
        let locked = target.appending(path: "locked", directoryHint: .isDirectory)
        let writable = locked.appending(path: "writable", directoryHint: .isDirectory)
        let child = writable.appending(path: "child")
        defer {
            _ = chmod(locked.path, 0o700)
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: writable, withIntermediateDirectories: true)
        try Data().write(to: child)
        try #require(chmod(locked.path, 0o500) == 0)

        let outcome = try PermanentDeletion.remove(scannedNode(at: target), at: target) { _ in [] }

        guard case .incomplete = outcome else {
            Issue.record("The partially removed folder must be reported as incomplete.")
            return
        }
        #expect(fileManager.fileExists(atPath: writable.path))
        #expect(!fileManager.fileExists(atPath: child.path))
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["selected"])
    }

    @Test
    func cancellationBeforeCaptureLeavesItemInPlace() async throws {
        let root = try makeCanonicalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "selected")
        let contents = Data("original".utf8)
        try contents.write(to: target)
        let node = try scannedNode(at: target)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PermanentDeletion.remove(node, at: target) { _ in [] }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: target) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["selected"])
    }

    private func makeCanonicalTemporaryDirectory() throws -> URL {
        let url = try makeTemporaryDirectory()
        let path = try #require(url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func scannedNode(at url: URL) throws -> FileNodeRecord {
        var status = stat()
        try #require(lstat(url.path, &status) == 0)
        let identity = FileIdentity(fileSystemStatus: status)
        if status.st_mode & S_IFMT == S_IFDIR {
            return makeTestDirectoryNode(id: url.path, name: url.lastPathComponent, children: [], fileIdentity: identity)
        }
        return makeTestFileNode(
            id: url.path,
            name: url.lastPathComponent,
            fileIdentity: identity,
            isSymbolicLink: status.st_mode & S_IFMT == S_IFLNK
        )
    }
}
