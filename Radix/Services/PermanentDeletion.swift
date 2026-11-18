import Darwin
import Foundation

nonisolated enum PermanentDeletion {
    nonisolated enum Outcome: Sendable {
        case removed(coveredMarks: [FileNodeRecord])
        case unchanged(TrashIdentityVerificationResult)
        case incomplete(error: any Error)
    }

    typealias VerifyCoveredMarks = @Sendable (_ matches: (FileNodeRecord, String) -> Bool) -> [FileNodeRecord]

    private struct PartialDeletion: LocalizedError {
        let path: String

        var errorDescription: String? {
            String(localized: "Could not finish deleting \"\(path)\". Some contents may already have been deleted.", comment: "Error after a permanent deletion stops partway through a folder.")
        }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    @concurrent
    static func remove(
        _ node: FileNodeRecord,
        at confirmedURL: URL,
        verifiedCoveredMarks: VerifyCoveredMarks
    ) async throws -> Outcome {
        try Task.checkCancellation()
        let policy = TrashSafetyPolicy.live()
        let isDirectory = node.isDirectory && !node.isSymbolicLink
        let leaf = confirmedURL.lastPathComponent
        guard node.supportsFileActions,
              !policy.blocksPermanentDeletion(at: node.url, isDirectory: isDirectory),
              !policy.blocksPermanentDeletion(at: confirmedURL, isDirectory: isDirectory),
              confirmedURL.isFileURL, !leaf.isEmpty, leaf != ".", leaf != "..", leaf != "/" else {
            throw FileActionError.unsupported
        }
        guard let scanned = node.fileIdentity?.scanFileSystemIdentity, let birthTime = scanned.birthTime else {
            return .unchanged(.missingScannedIdentity)
        }

        let parentURL = confirmedURL.deletingLastPathComponent()
        let parent = parentURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, directoryFlags | O_NOFOLLOW_ANY) } ?? -1
        }
        guard parent != -1 else { throw posixError(errno, path: confirmedURL.path) }
        defer { close(parent) }

        let actualParent = try directoryURL(for: parent)
        let actualURL = actualParent.appending(path: leaf)
        guard !policy.blocksPermanentDeletion(at: actualURL, isDirectory: isDirectory) else {
            throw FileActionError.unsupported
        }
        return try leaf.withCString { name in
            let original = try entryStatus(in: parent, name: name)
            let nativeIdentity = FileIdentity(fileSystemStatus: original)
            guard nativeIdentity == scanned, nativeIdentity.birthTime == birthTime else {
                return .unchanged(.mismatch)
            }
            let verification = SystemIntegration.verifyTrashIdentity(node, at: actualURL)
            guard verification == .matches else { return .unchanged(verification) }

            let parentStatus = try descriptorStatus(parent)
            guard original.st_dev == parentStatus.st_dev else { throw FileActionError.unsupported }

            let stagingName = ".radix-delete-\(UUID().uuidString)"
            guard mkdirat(parent, stagingName, 0o700) == 0 else { throw posixError(errno, path: confirmedURL.path) }
            let stagingStatus = try stagingName.withCString { try entryStatus(in: parent, name: $0) }
            guard stagingStatus.st_uid == geteuid(), stagingStatus.st_mode & S_IFMT == S_IFDIR else {
                throw FileActionError.unsupported
            }
            var staging: Int32 = -1
            var receipt: PermanentDeletionRecovery.Receipt?
            defer {
                stagingName.withCString { name in
                    if let current = try? entryStatus(in: parent, name: name),
                       sameEntry(current, stagingStatus), unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                        receipt?.finish()
                    }
                }
                if staging != -1 { close(staging) }
            }
            guard stagingStatus.st_mode & 0o777 == 0o700 else { throw FileActionError.unsupported }
            staging = openat(parent, stagingName, directoryFlags | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
            guard staging != -1 else { throw posixError(errno, path: confirmedURL.path) }

            guard sameEntry(try descriptorStatus(staging), stagingStatus) else { throw posixError(ESTALE) }
            try clearInheritedAccess(from: staging)

            try Task.checkCancellation()
            receipt = try PermanentDeletionRecovery.register(
                parentURL: actualParent, stagingName: stagingName, leaf: leaf,
                parentStatus: parentStatus, stagingStatus: stagingStatus
            )
            guard renameatx_np(parent, name, staging, name, UInt32(RENAME_EXCL)) == 0 else {
                throw posixError(errno, path: confirmedURL.path)
            }

            var removedContents = false
            let retained: Outcome
            do {
                let captured = try entryStatus(in: staging, name: name)
                if sameEntry(captured, original) {
                    let coveredMarks = verifiedCoveredMarks { mark, relativePath in
                        matches(mark, relativePath: relativePath, in: staging, leaf: leaf, captured: captured)
                    }
                    try removeEntry(in: staging, name: leaf, expected: captured, removedContents: &removedContents)
                    return .removed(coveredMarks: coveredMarks)
                }
                retained = .unchanged(.mismatch)
            } catch {
                retained = .incomplete(error: removedContents ? PartialDeletion(path: confirmedURL.path) : error)
            }

            guard renameatx_np(staging, name, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                let recoveryDirectory = (try? directoryURL(for: staging)) ?? actualParent.appending(path: stagingName)
                return .incomplete(error: PermanentDeletionRecovery.RestorationError(
                    path: confirmedURL.path, recoveryPath: recoveryDirectory.appending(path: leaf).path
                ))
            }
            if case .incomplete(let error) = retained, error is CancellationError { throw error }
            return retained
        }
    }

    private static func clearInheritedAccess(from descriptor: Int32) throws {
        // macOS can inherit an ACL even when the new directory has mode 0700.
        guard let inherited = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return }
            throw posixError(errno)
        }
        acl_free(UnsafeMutableRawPointer(inherited))
        guard let empty = acl_init(0) else { throw posixError(errno) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0 else { throw posixError(errno) }
    }

    private static func matches(
        _ mark: FileNodeRecord, relativePath: String, in staging: Int32, leaf: String, captured: stat
    ) -> Bool {
        guard let scan = mark.fileIdentity?.scanFileSystemIdentity, let birthTime = scan.birthTime else { return false }
        let status: stat
        if relativePath.isEmpty {
            status = captured
        } else {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard let name = components.last,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
            let parentPath = ([leaf] + components.dropLast().map(String.init)).joined(separator: "/")
            let parent = openat(staging, parentPath, directoryFlags | O_NOFOLLOW_ANY)
            guard parent != -1 else { return false }
            defer { close(parent) }
            guard let child = try? String(name).withCString({ try entryStatus(in: parent, name: $0) }) else {
                return false
            }
            status = child
        }
        let identity = FileIdentity(fileSystemStatus: status)
        return identity == scan && identity.birthTime == birthTime
    }

    private struct DirectoryEntry {
        let name: [CChar]
        let status: stat
    }

    private static func removeEntry(in parent: Int32, name: String, expected: stat, removedContents: inout Bool) throws {
        try Task.checkCancellation()
        guard expected.st_mode & S_IFMT == S_IFDIR else {
            guard sameEntry(try entryStatus(in: parent, name: name), expected) else { throw posixError(ESTALE) }
            guard unlinkat(parent, name, 0) == 0 else { throw posixError(errno) }
            return
        }

        let root = DirectoryEntry(name: Array(name.utf8CString), status: expected)
        var stack = [root]
        var directory = try directoryStream(owning: openDirectory(in: parent, name: root.name, expected: expected))
        defer { closedir(directory) }

        while let current = stack.last {
            try Task.checkCancellation()
            let descriptor = dirfd(directory)
            if let childName = try nextName(in: directory) {
                let status = try entryStatus(in: descriptor, name: childName)
                guard status.st_dev == expected.st_dev else { throw posixError(EXDEV) }
                if status.st_mode & S_IFMT == S_IFDIR {
                    let child = try directoryStream(owning: openDirectory(in: descriptor, name: childName, expected: status))
                    closedir(directory)
                    directory = child
                    stack.append(DirectoryEntry(name: childName, status: status))
                } else {
                    try Task.checkCancellation()
                    guard unlinkat(descriptor, childName, 0) == 0 else { throw posixError(errno) }
                    removedContents = true
                }
            } else {
                stack.removeLast()
                let enclosing: Int32
                if let ancestor = stack.last {
                    // A descriptor for each ancestor would exhaust the process limit on deep trees.
                    enclosing = try openDirectory(in: descriptor, name: Array("..".utf8CString), expected: ancestor.status)
                } else {
                    enclosing = parent
                }
                do {
                    guard sameEntry(try entryStatus(in: enclosing, name: current.name), current.status) else {
                        throw posixError(ESTALE)
                    }
                    try Task.checkCancellation()
                    guard unlinkat(enclosing, current.name, AT_REMOVEDIR) == 0 else { throw posixError(errno) }
                    removedContents = true
                } catch {
                    if enclosing != parent { close(enclosing) }
                    throw error
                }
                if enclosing != parent {
                    let previous = try directoryStream(owning: enclosing)
                    closedir(directory)
                    directory = previous
                }
            }
        }
    }

    private static func openDirectory(in parent: Int32, name: [CChar], expected: stat) throws -> Int32 {
        let descriptor = openat(parent, name, directoryFlags | O_NOFOLLOW)
        guard descriptor != -1 else { throw posixError(errno) }
        do {
            guard sameEntry(try descriptorStatus(descriptor), expected) else { throw posixError(ESTALE) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func directoryStream(owning descriptor: Int32) throws -> UnsafeMutablePointer<DIR> {
        guard let directory = fdopendir(descriptor) else {
            let error = posixError(errno)
            close(descriptor)
            throw error
        }
        return directory
    }

    private static func nextName(in directory: UnsafeMutablePointer<DIR>) throws -> [CChar]? {
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError(errno) }
                return nil
            }
            let count = Int(entry.pointee.d_namlen) + 1
            let name: [CChar]? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: count) { bytes in
                    guard strcmp(bytes, ".") != 0, strcmp(bytes, "..") != 0 else { return nil }
                    return Array(UnsafeBufferPointer(start: bytes, count: count))
                }
            }
            if let name { return name }
        }
    }

    private static func descriptorStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError(errno) }
        return status
    }

    private static func entryStatus(in parent: Int32, name: UnsafePointer<CChar>) throws -> stat {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(errno) }
        return status
    }

    private static func sameEntry(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_birthtimespec.tv_sec == second.st_birthtimespec.tv_sec &&
            first.st_birthtimespec.tv_nsec == second.st_birthtimespec.tv_nsec
    }

    private static func directoryURL(for descriptor: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw posixError(errno) }
        return buffer.withUnsafeBufferPointer { bytes in
            URL(fileURLWithFileSystemRepresentation: bytes.baseAddress!, isDirectory: true, relativeTo: nil)
        }
    }

    private static func posixError(_ code: Int32, path: String? = nil) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: path.map { [NSFilePathErrorKey: $0] })
    }
}
