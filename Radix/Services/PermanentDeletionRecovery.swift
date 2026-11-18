import Darwin
import Foundation

nonisolated enum PermanentDeletionRecovery {
    nonisolated struct RestorationError: LocalizedError {
        let path: String
        let recoveryPath: String

        var errorDescription: String? {
            String(localized: "Could not restore \"\(path)\". Check \"\(recoveryPath)\" for the remaining item.", comment: "Error when an item left over after permanent deletion cannot be returned to its original path.")
        }
    }

    nonisolated struct Receipt {
        fileprivate let url: URL

        func finish() {
            _ = unlink(url.path)
        }
    }

    private nonisolated struct DirectoryIdentity: Codable, Equatable {
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int

        init(_ status: stat) {
            inode = status.st_ino
            birthSeconds = status.st_birthtimespec.tv_sec
            birthNanoseconds = status.st_birthtimespec.tv_nsec
        }
    }

    private nonisolated struct Record: Codable {
        let parentURL: URL
        let parentBookmark: Data
        let parentIdentity: DirectoryIdentity
        let stagingIdentity: DirectoryIdentity
        let leaf: String
    }

    private static let liveDirectory = URL.applicationSupportDirectory.appending(path: "com.colinkim.Radix/Deletion Recovery")

    static func stagingName(for uuidString: String) -> String {
        ".radix-delete-\(uuidString)"
    }

    static func register(
        parentURL: URL, stagingID: UUID, leaf: String, parentStatus: stat, stagingStatus: stat,
        in directory: URL = liveDirectory
    ) throws -> Receipt {
        guard validLeaf(leaf) else { throw CocoaError(.fileWriteInvalidFileName) }
        let selected = parentURL.appending(path: leaf).path
        let storage = directory.resolvingSymlinksInPath().path
        let storagePaths = [storage, TrashSafetyPolicy.alternateStartupVolumePath(for: storage)].compactMap { $0 }
        guard !storagePaths.contains(where: {
            selected == $0 || selected.hasPrefix($0 + "/") || $0.hasPrefix(selected + "/")
        }) else { throw FileActionError.unsupported }

        let record = Record(
            parentURL: parentURL,
            parentBookmark: try parentURL.bookmarkData(),
            parentIdentity: DirectoryIdentity(parentStatus),
            stagingIdentity: DirectoryIdentity(stagingStatus),
            leaf: leaf
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let receipt = Receipt(url: directory.appending(path: stagingID.uuidString + ".json"))
        try JSONEncoder().encode(record).write(to: receipt.url, options: .atomic)
        return receipt
    }

    @concurrent
    static func restoreInterrupted(in directory: URL = liveDirectory) async -> [any Error] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            return [error]
        }

        var failures: [any Error] = []
        for url in urls where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
                guard validParent(record.parentURL), validLeaf(record.leaf) else { throw CocoaError(.fileReadCorruptFile) }
                try restore(record, stagingName: stagingName(for: id), receipt: Receipt(url: url))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Another instance may have finished this receipt after we listed it.
                continue
            } catch {
                failures.append(error)
            }
        }
        return failures
    }

    private static func restore(_ record: Record, stagingName: String, receipt: Receipt) throws {
        var stale = false
        let resolved = try? URL(
            resolvingBookmarkData: record.parentBookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        let parentURL = resolved.flatMap { validParent($0) ? $0 : nil }
        let reportedParent = parentURL ?? record.parentURL
        let failure = RestorationError(
            path: reportedParent.appending(path: record.leaf).path,
            recoveryPath: reportedParent.appending(path: stagingName).appending(path: record.leaf).path
        )
        guard let parentURL else { throw failure }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        let parent = open(parentURL.path, flags | O_NOFOLLOW_ANY)
        guard parent != -1 else { throw failure }
        defer { close(parent) }
        var status = stat()
        guard fstat(parent, &status) == 0, record.parentIdentity == DirectoryIdentity(status) else { throw failure }
        let parentDevice = status.st_dev

        let staging = openat(parent, stagingName, flags | O_NOFOLLOW)
        guard staging != -1 else {
            guard errno == ENOENT else { throw failure }
            receipt.finish()
            return
        }
        defer { close(staging) }
        guard flock(staging, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return }
            throw failure
        }
        guard fstat(staging, &status) == 0, status.st_dev == parentDevice, status.st_uid == geteuid(),
              record.stagingIdentity == DirectoryIdentity(status) else { throw failure }
        if renameatx_np(staging, record.leaf, parent, record.leaf, UInt32(RENAME_EXCL)) != 0 {
            guard errno == ENOENT, fstatat(staging, record.leaf, &status, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw failure }
        }
        if fstatat(parent, stagingName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard record.stagingIdentity == DirectoryIdentity(status),
                  unlinkat(parent, stagingName, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw failure }
        } else if errno != ENOENT { throw failure }
        receipt.finish()
    }

    private static func validParent(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0) &&
            (url.host == nil || url.host == "" || url.host == "localhost")
    }

    private static func validLeaf(_ leaf: String) -> Bool {
        !leaf.isEmpty && leaf != "." && leaf != ".." && !leaf.utf8.contains(0) && !leaf.contains("/")
    }
}
