import Darwin
import Foundation

nonisolated enum PermanentDeletion {
    nonisolated enum Outcome: Sendable {
        case removed(coveredMarks: [FileNodeRecord])
        case unchanged(TrashIdentityVerificationResult)
        case incomplete(error: any Error)
    }

    private nonisolated enum Failure: LocalizedError {
        case partialDeletion(path: String)
        case recoveryRequired(path: String, recoveryPath: String)

        var errorDescription: String? {
            switch self {
            case .partialDeletion(let path):
                String(localized: "Could not finish deleting \"\(path)\". Some contents may already have been deleted.", comment: "Error after a permanent deletion stops partway through a folder.")
            case .recoveryRequired(let path, let recoveryPath):
                String(localized: "Could not restore \"\(path)\". Check \"\(recoveryPath)\" for the remaining item.", comment: "Error when an item left over after permanent deletion cannot be returned to its original path.")
            }
        }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    static func remove(
        _ node: FileNodeRecord,
        at confirmedURL: URL,
        verifiedCoveredMarks: (URL) -> [FileNodeRecord]
    ) throws -> Outcome {
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

        let actualURL = try directoryURL(for: parent).appending(path: leaf)
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

            var parentStatus = stat()
            guard fstat(parent, &parentStatus) == 0 else { throw posixError(errno) }
            guard original.st_dev == parentStatus.st_dev else { throw FileActionError.unsupported }

            let stagingName = ".radix-delete-\(UUID().uuidString)"
            guard mkdirat(parent, stagingName, 0o700) == 0 else { throw posixError(errno, path: confirmedURL.path) }
            let stagingStatus = try stagingName.withCString { try entryStatus(in: parent, name: $0) }
            guard stagingStatus.st_uid == geteuid(),
                  stagingStatus.st_mode & (S_IFMT | 0o777) == S_IFDIR | 0o700 else {
                throw FileActionError.unsupported
            }
            defer {
                stagingName.withCString { name in
                    if let current = try? entryStatus(in: parent, name: name),
                       sameEntry(current, stagingStatus) {
                        _ = unlinkat(parent, name, AT_REMOVEDIR)
                    }
                }
            }
            let staging = openat(parent, stagingName, directoryFlags | O_NOFOLLOW)
            guard staging != -1 else { throw posixError(errno, path: confirmedURL.path) }
            defer { close(staging) }

            var openedStaging = stat()
            guard fstat(staging, &openedStaging) == 0 else { throw posixError(errno) }
            guard sameEntry(openedStaging, stagingStatus) else { throw posixError(ESTALE) }
            try clearInheritedAccess(from: staging)

            let stagedURL = try directoryURL(for: staging).appending(path: leaf)
            try Task.checkCancellation()
            // Capture the entry before the final identity check so a replacement at the source path cannot be deleted.
            guard renameatx_np(parent, name, staging, name, UInt32(RENAME_EXCL)) == 0 else {
                throw posixError(errno, path: confirmedURL.path)
            }
            let retained: Outcome
            do {
                let captured = try entryStatus(in: staging, name: name)
                let capturedVerification: TrashIdentityVerificationResult = sameEntry(captured, original)
                    ? SystemIntegration.verifyTrashIdentity(node, at: stagedURL)
                    : .mismatch
                if capturedVerification == .matches {
                    let coveredMarks = verifiedCoveredMarks(stagedURL)
                    do {
                        try removeEntry(in: staging, name: name, expected: captured, device: original.st_dev)
                    } catch {
                        throw Failure.partialDeletion(path: confirmedURL.path)
                    }
                    return .removed(coveredMarks: coveredMarks)
                }
                retained = .unchanged(capturedVerification)
            } catch {
                retained = .incomplete(error: error)
            }

            guard renameatx_np(staging, name, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                return recoveryFailure(path: confirmedURL.path, staging: staging, stagedURL: stagedURL)
            }
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

    private static func recoveryFailure(path: String, staging: Int32, stagedURL: URL) -> Outcome {
        let recoveryURL = (try? directoryURL(for: staging).appending(path: stagedURL.lastPathComponent)) ?? stagedURL
        return .incomplete(error: Failure.recoveryRequired(path: path, recoveryPath: recoveryURL.path))
    }

    private static func removeEntry(
        in parent: Int32,
        name: UnsafePointer<CChar>,
        expected: stat? = nil,
        device: dev_t
    ) throws {
        let status = try entryStatus(in: parent, name: name)
        guard status.st_dev == device else { throw posixError(EXDEV) }
        if let expected, !sameEntry(status, expected) { throw posixError(ESTALE) }
        let isDirectory = status.st_mode & S_IFMT == S_IFDIR
        if isDirectory {
            let descriptor = openat(parent, name, directoryFlags | O_NOFOLLOW)
            guard descriptor != -1 else { throw posixError(errno) }
            guard let directory = fdopendir(descriptor) else {
                let error = posixError(errno)
                close(descriptor)
                throw error
            }
            defer { closedir(directory) }

            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0 else { throw posixError(errno) }
            guard sameEntry(openedStatus, status) else { throw posixError(ESTALE) }

            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw posixError(errno) }
                    break
                }
                let byteCount = Int(entry.pointee.d_namlen) + 1
                try withUnsafePointer(to: &entry.pointee.d_name) {
                    try $0.withMemoryRebound(to: CChar.self, capacity: byteCount) { child in
                        guard strcmp(child, ".") != 0, strcmp(child, "..") != 0 else { return }
                        try removeEntry(in: descriptor, name: child, device: device)
                    }
                }
            }
            guard sameEntry(try entryStatus(in: parent, name: name), status) else { throw posixError(ESTALE) }
        }

        guard unlinkat(parent, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw posixError(errno) }
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
