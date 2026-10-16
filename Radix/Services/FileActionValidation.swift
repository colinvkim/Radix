import Foundation

/// Shared by explicit file actions and Quick Look's asynchronous selection updates.
nonisolated enum FileActionValidation {
    static func validateLivePath(
        _ node: FileNodeRecord,
        source: ScanSnapshotSource,
        fileExists: (URL) -> Bool
    ) throws {
        guard source.allowsLivePathActions else { throw FileActionError.unsupported }
        guard node.url.isFileURL, fileExists(node.url) else {
            throw FileActionError.unavailable(path: node.url.path)
        }
    }
}
