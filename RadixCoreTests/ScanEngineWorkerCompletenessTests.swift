import Darwin
import Foundation
import Testing

@testable import RadixCore

struct ScanEngineWorkerCompletenessTests {
    @Test
    func immutableFullTreeMatchesAcrossTraversalWorkerCounts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            do { try FileManager.default.removeItem(at: rootURL) } catch { Issue.record(error) }
        }
        let fixture = try WorkerFixture(rootURL: rootURL)
        let before = try fixture.readState()
        var reference: ScanSnapshot?

        for workers in [1, 5, 12, 16, 16, 12, 5] {
            let options = ScanOptions(
                includeHiddenFiles: true,
                treatPackagesAsDirectories: true,
                autoSummarizeDirectories: false,
                atomicSummaryWorkerLimit: 1,
                directoryClassificationWorkerLimit: 1,
                directoryTraversalWorkerLimit: workers
            )
            var completions: [ScanSnapshot] = []
            for try await event in ScanEngine().scan(target: fixture.target, options: options) {
                if case .finished(let snapshot) = event { completions.append(snapshot) }
            }
            try #require(completions.count == 1, "Traversal workers \(workers)")
            let snapshot = completions[0]
            try fixture.expectComplete(snapshot, native: before, matching: reference)
            reference = reference ?? snapshot
        }

        #expect(try fixture.readState() == before)
    }
}

private enum FixtureEntry {
    case directory
    case file(Data)
}

private struct WorkerFixture {
    let target: ScanTarget
    let entries: [String: FixtureEntry]

    init(rootURL: URL) throws {
        target = ScanTarget(url: rootURL, kind: .folder)
        let root = target.url
        var manifest: [String: FixtureEntry] = ["": .directory]
        func addDirectory(_ path: String) throws {
            try FileManager.default.createDirectory(
                at: root.appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            manifest[path] = .directory
        }
        func addFile(_ path: String, seed: Int) throws {
            let data = Data(repeating: UInt8(truncatingIfNeeded: seed), count: 32 + seed % 113)
            try data.write(to: root.appending(path: path, directoryHint: .notDirectory))
            manifest[path] = .file(data)
        }

        for branch in 0..<24 {
            let path = String(format: "branch-%02d", branch)
            try addDirectory(path)
            try addDirectory(path + "/nested")
            try addDirectory(path + "/nested/empty")
            for file in 0..<4 {
                try addFile(path + "/file-\(file).bin", seed: branch * 5 + file)
            }
            try addFile(path + "/nested/payload.bin", seed: branch * 5 + 4)
        }
        try addDirectory("wide")
        for file in 0..<2_113 {
            try addFile(String(format: "wide/leaf-%04d.bin", file), seed: 120 + file)
        }
        for (offset, name) in [".hidden.bin", "percent%20literal.bin", "文件-🙂 space.bin"].enumerated() {
            try addFile(name, seed: 2_233 + offset)
        }
        entries = manifest
    }

    func readState() throws -> [Data: FixtureStamp] {
        let paths = [""] + (try FileManager.default.subpathsOfDirectory(atPath: target.url.path))
        try #require(Set(paths.map { Data($0.utf8) }) == Set(entries.keys.map { Data($0.utf8) }))
        try #require(paths.count == entries.count)
        var state: [Data: FixtureStamp] = [:]
        for path in paths {
            let url = path.isEmpty ? target.url : target.url.appending(path: path)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            switch try #require(entries[path]) {
            case .directory:
                try #require(metadata.st_mode & S_IFMT == S_IFDIR, "\(path)")
            case .file(let data):
                try #require(metadata.st_mode & S_IFMT == S_IFREG, "\(path)")
                #expect(metadata.st_nlink == 1, "\(path)")
                #expect(metadata.st_size == data.count, "\(path)")
                #expect(try Data(contentsOf: url) == data, "\(path)")
            }
            state[Data(path.utf8)] = FixtureStamp(metadata)
        }
        return state
    }

    func expectComplete(
        _ snapshot: ScanSnapshot,
        native: [Data: FixtureStamp],
        matching reference: ScanSnapshot?
    ) throws {
        try #require(snapshot.isComplete)
        #expect(snapshot.scanWarnings.isEmpty)
        let store = snapshot.treeStore
        let ids = store.indexedNodeIDs()
        let expectedIDs = entries.keys.map { $0.isEmpty ? target.id : target.id + "/" + $0 }
        try #require(Set(ids.map { Data($0.utf8) }) == Set(expectedIDs.map { Data($0.utf8) }))
        try #require(ids.count == entries.count)
        var fileCount = 0
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        for (path, entry) in entries {
            let id = path.isEmpty ? target.id : target.id + "/" + path
            let node = try #require(store.node(id: id))
            let parentPath = (path as NSString).deletingLastPathComponent
            let parentID =
                path.isEmpty ? nil : parentPath.isEmpty ? target.id : target.id + "/" + parentPath
            #expect(
                store.parentID(of: id).map { Data($0.utf8) } == parentID.map { Data($0.utf8) }, "\(path)")
            #expect(Data(node.id.utf8) == Data(id.utf8), "\(path)")
            #expect(Data(node.url.path.utf8) == Data(id.utf8), "\(path)")
            #expect(
                Data(node.name.utf8)
                    == Data((path.isEmpty ? target.displayName : (path as NSString).lastPathComponent).utf8),
                "\(path)")
            #expect(node.isAccessible && node.isSelfAccessible, "\(path)")
            #expect(
                !node.isSymbolicLink && !node.isSynthetic && !node.isAutoSummarized && !node.isPackage,
                "\(path)")
            switch entry {
            case .directory:
                #expect(node.isDirectory, "\(path)")
                let children = entries.keys.filter {
                    !$0.isEmpty && ($0 as NSString).deletingLastPathComponent == path
                }
                #expect(
                    Set(store.childIDs(of: id).map { Data($0.utf8) })
                        == Set(children.map { Data((target.id + "/" + $0).utf8) }), "\(path)")
                #expect(store.childIDs(of: id).count == children.count, "\(path)")
                let descendants = entries.filter { path.isEmpty || $0.key.hasPrefix(path + "/") }.values
                let files = descendants.compactMap { entry -> Data? in
                    if case .file(let data) = entry { return data }
                    return nil
                }
                #expect(node.descendantFileCount == files.count, "\(path)")
                #expect(node.logicalSize == files.reduce(Int64(0)) { $0 + Int64($1.count) }, "\(path)")
            case .file(let data):
                #expect(!node.isDirectory, "\(path)")
                #expect(store.childIDs(of: id).isEmpty, "\(path)")
                #expect(node.logicalSize == data.count, "\(path)")
                #expect(node.descendantFileCount == 1, "\(path)")
                fileCount += 1
                logicalSize += Int64(data.count)
                allocatedSize += Int64(try #require(native[Data(path.utf8)]).blocks) * 512
            }

            if let reference {
                let expected = try #require(reference.treeStore.node(id: id))
                #expect(node == expected, "\(path)")
                #expect(node.fileIdentity?.darwinIdentity == expected.fileIdentity?.darwinIdentity, "\(path)")
                #expect(
                    Data(node.url.absoluteString.utf8) == Data(expected.url.absoluteString.utf8), "\(path)")
                #expect(node.url.hasDirectoryPath == expected.url.hasDirectoryPath, "\(path)")
                #expect(
                    store.childIDs(of: id).map { Data($0.utf8) }
                        == reference.treeStore.childIDs(of: id).map { Data($0.utf8) }, "\(path)")
            }
        }
        let stats = snapshot.aggregateStats
        #expect(stats.fileCount == fileCount)
        #expect(stats.directoryCount == entries.count - fileCount)
        #expect(stats.totalLogicalSize == logicalSize)
        #expect(stats.totalAllocatedSize == allocatedSize)
        #expect(stats.accessibleItemCount == entries.count)
        #expect(stats.inaccessibleItemCount == 0)
        if let reference {
            #expect(
                ids.map { Data($0.utf8) } == reference.treeStore.indexedNodeIDs().map { Data($0.utf8) })
        }
    }
}

private struct FixtureStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let linkCount: nlink_t
    let owner: uid_t
    let group: gid_t
    let size: off_t
    let blocks: blkcnt_t
    let flags: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let createdSeconds: Int
    let createdNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        mode = metadata.st_mode
        linkCount = metadata.st_nlink
        owner = metadata.st_uid
        group = metadata.st_gid
        size = metadata.st_size
        blocks = metadata.st_blocks
        flags = metadata.st_flags
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
        createdSeconds = metadata.st_birthtimespec.tv_sec
        createdNanoseconds = metadata.st_birthtimespec.tv_nsec
    }
}
