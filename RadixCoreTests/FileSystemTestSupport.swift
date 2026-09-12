import Darwin
import Foundation

/// Probe the actual fixture volume instead of assuming APFS name and clone semantics.
enum TestFileSystem {
    static func supportsNativeNames(_ names: [[UInt8]]) throws -> Bool {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { close(descriptor) }
        for name in names {
            let child = (name + [0]).withUnsafeBytes {
                openat(
                    descriptor, $0.baseAddress!.assumingMemoryBound(to: CChar.self),
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
            }
            if child < 0 {
                guard [EILSEQ, EINVAL, EEXIST].contains(errno) else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno)!)
                }
                return false
            }
            close(child)
        }
        return true
    }

    static func supportsCloning() throws -> Bool {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source")
        let destination = directory.appending(path: "clone")
        try Data([1]).write(to: source)
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        guard [ENOTSUP, EXDEV].contains(errno) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return false
    }
}
