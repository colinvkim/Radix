import Darwin
import Foundation

nonisolated enum PermanentDeletion {
    nonisolated enum Outcome: Sendable {
        case removed(coveredMarks: [FileNodeRecord])
        case unchanged(TrashIdentityVerificationResult)
        case incomplete(error: any Error)
    }

    typealias VerifyCoveredMarks = @Sendable (_ matches: (FileNodeRecord, String) -> Bool) -> [FileNodeRecord]

    private struct EntryChanged: LocalizedError {
        var errorDescription: String? {
            String(localized: "An item moved or changed during deletion.")
        }
    }

    private struct PartialDeletion: LocalizedError {
        let path: String
        let cause: any Error

        var errorDescription: String? {
            String(localized: "Could not finish deleting \"\(path)\". Some contents may already have been deleted.", comment: "Error after a permanent deletion stops partway through a folder.")
                + "\n" + cause.localizedDescription
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
        guard let parentPath = parentURL.withUnsafeFileSystemRepresentation({ path in
            path.map { Array(UnsafeBufferPointer(start: $0, count: strlen($0) + 1)) }
        }) else { throw FileActionError.unsupported }
        let parent = open(parentPath, directoryFlags | O_NOFOLLOW_ANY)
        guard parent != -1 else { throw posixError(errno, path: confirmedURL.path) }
        defer { close(parent) }

        let actualParent = try directoryURL(for: parent)
        let actualURL = actualParent.appending(path: leaf)
        guard !policy.blocksPermanentDeletion(at: actualURL, isDirectory: isDirectory) else {
            throw FileActionError.unsupported
        }
        return try leaf.withCString { name in
            let original: stat
            do {
                original = try entryStatus(in: parent, name: name)
            } catch is EntryChanged {
                return .unchanged(.missingCurrentItem)
            }
            let nativeIdentity = FileIdentity(fileSystemStatus: original)
            guard nativeIdentity == scanned, nativeIdentity.birthTime == birthTime else {
                return .unchanged(.mismatch)
            }
            let verification = SystemIntegration.verifyTrashIdentity(node, at: actualURL)
            guard verification == .matches else { return .unchanged(verification) }

            let parentStatus = try descriptorStatus(parent)
            guard original.st_dev == parentStatus.st_dev else { throw FileActionError.unsupported }

            let coveredMarks = verifiedCoveredMarks { mark, relativePath in
                matches(mark, relativePath: relativePath, in: parent, leaf: leaf, original: original)
            }
            let location = ConfirmedParent(descriptor: parent, path: parentPath, status: parentStatus)
            var removedContents = false
            do {
                try removeEntry(in: location, name: leaf, expected: original, removedContents: &removedContents)
            } catch {
                guard removedContents else {
                    if error is EntryChanged { return .unchanged(.mismatch) }
                    throw error
                }
                if error is CancellationError { return .incomplete(error: error) }
                return .incomplete(error: PartialDeletion(path: confirmedURL.path, cause: error))
            }
            return .removed(coveredMarks: coveredMarks.filter {
                let current = SystemIntegration.verifyTrashIdentity($0)
                return current == .missingCurrentItem || current == .mismatch
            })
        }
    }

    private static func matches(
        _ mark: FileNodeRecord, relativePath: String, in parent: Int32, leaf: String, original: stat
    ) -> Bool {
        guard let scan = mark.fileIdentity?.scanFileSystemIdentity, let birthTime = scan.birthTime else { return false }
        let status: stat
        if relativePath.isEmpty {
            status = original
        } else {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard let name = components.last,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
            var directory = openat(parent, leaf, directoryFlags | O_NOFOLLOW_ANY)
            guard directory != -1 else { return false }
            defer { close(directory) }
            for component in components.dropLast() {
                let next = openat(directory, String(component), directoryFlags | O_NOFOLLOW_ANY)
                guard next != -1 else { return false }
                close(directory)
                directory = next
            }
            guard let child = try? String(name).withCString({ try entryStatus(in: directory, name: $0) }) else {
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

    private struct ConfirmedParent {
        let descriptor: Int32
        let path: [CChar]
        let status: stat
    }

    private static func removeEntry(
        in location: ConfirmedParent, name: String, expected: stat, removedContents: inout Bool
    ) throws {
        try Task.checkCancellation()
        let root = DirectoryEntry(name: Array(name.utf8CString), status: expected)
        var path = DeletionPath()
        path.append(root)
        guard expected.st_mode & S_IFMT == S_IFDIR else {
            try path.unlinkLast(relativeTo: location)
            return
        }

        var directory = try directoryStream(owning: openDirectory(in: location.descriptor, name: root.name, expected: expected))
        defer { closedir(directory) }

        while true {
            try Task.checkCancellation()
            let descriptor = dirfd(directory)
            if let childName = try nextName(in: directory) {
                let status = try entryStatus(in: descriptor, name: childName)
                guard status.st_dev == expected.st_dev else { throw posixError(EXDEV) }
                path.append(DirectoryEntry(name: childName, status: status))
                if status.st_mode & S_IFMT == S_IFDIR {
                    let child = try directoryStream(owning: openDirectory(in: descriptor, name: childName, expected: status))
                    closedir(directory)
                    directory = child
                } else {
                    try path.unlinkLast(relativeTo: location)
                    removedContents = true
                }
            } else {
                guard let ancestor = path.parent else {
                    try path.unlinkLast(relativeTo: location)
                    return
                }
                let enclosing = try openDirectory(in: descriptor, name: Array("..".utf8CString), expected: ancestor.status)
                do {
                    try path.unlinkLast(relativeTo: location)
                } catch {
                    close(enclosing)
                    throw error
                }
                removedContents = true
                let previous = try directoryStream(owning: enclosing)
                closedir(directory)
                directory = previous
            }
        }
    }

    // Keep the traversal path in filesystem bytes. Split only where a single
    // kernel lookup would exceed MAXPATHLEN. Each chunk is NUL-terminated.
    private struct DeletionPath {
        private let slash = CChar(UInt8(ascii: "/"))
        private var entries: [DirectoryEntry] = []
        private var prefixes: [DirectoryEntry] = []
        private var tail: [CChar] = []

        var parent: DirectoryEntry? { entries.dropLast().last }

        mutating func append(_ entry: DirectoryEntry) {
            if let parent = entries.last {
                if tail.count + entry.name.count > Int(MAXPATHLEN) {
                    prefixes.append(DirectoryEntry(name: tail, status: parent.status))
                    tail = []
                } else {
                    tail[tail.count - 1] = slash
                }
            }
            tail.append(contentsOf: entry.name)
            entries.append(entry)
        }

        mutating func unlinkLast(relativeTo location: ConfirmedParent) throws {
            let entry = entries[entries.count - 1]
            // An enumeration descriptor stays valid if its directory moves.
            // Resolve removals from the confirmed location, checking the selected
            // root as well as the enumerated parent and leaf.
            guard sameEntry(try entryStatus(in: AT_FDCWD, name: location.path), location.status) else {
                throw EntryChanged()
            }
            var anchor = location.descriptor
            defer { if anchor != location.descriptor { close(anchor) } }
            if entries.count > 2 {
                let root = entries[0]
                guard sameEntry(try entryStatus(in: anchor, name: root.name), root.status) else { throw EntryChanged() }
            }
            for prefix in prefixes {
                let next = try openDirectory(in: anchor, name: prefix.name, expected: prefix.status)
                if anchor != location.descriptor { close(anchor) }
                anchor = next
            }

            let parentLength = tail.count - entry.name.count
            if parentLength > 0, let parent {
                tail[parentLength - 1] = 0
                defer { tail[parentLength - 1] = slash }
                guard sameEntry(try entryStatus(in: anchor, name: tail), parent.status) else { throw EntryChanged() }
            }
            guard sameEntry(try entryStatus(in: anchor, name: tail), entry.status) else { throw EntryChanged() }
            try Task.checkCancellation()
            // The identity check and unlink are separate Darwin operations.
            let flags = entry.status.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
            guard unlinkat(anchor, tail, flags | AT_SYMLINK_NOFOLLOW_ANY) == 0 else { throw entryError(errno) }

            entries.removeLast()
            tail.removeLast(entry.name.count)
            if !tail.isEmpty {
                tail[tail.count - 1] = 0
            } else if let prefix = prefixes.popLast() {
                tail = prefix.name
            }
        }
    }

    private static func openDirectory(in parent: Int32, name: [CChar], expected: stat) throws -> Int32 {
        let descriptor = openat(parent, name, directoryFlags | O_NOFOLLOW_ANY)
        guard descriptor != -1 else { throw entryError(errno) }
        do {
            guard sameEntry(try descriptorStatus(descriptor), expected) else { throw EntryChanged() }
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
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY) == 0 else { throw entryError(errno) }
        return status
    }

    private static func entryError(_ code: Int32) -> any Error {
        switch code {
        case ENOENT, ENOTDIR, ELOOP: EntryChanged()
        default: posixError(code)
        }
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
