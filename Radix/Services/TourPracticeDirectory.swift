import Darwin
import Foundation

/// Owns only directories created by Radix for a workspace tour.
nonisolated struct TourPracticeDirectory: Sendable {
    let sessionID: UUID
    let containerURL: URL
    let target: ScanTarget

    private struct Ownership: Codable {
        let sessionID: UUID
        let processID: Int32
    }

    private static let markerName = ".radix-tour.json"
    private static var baseURL: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("com.colinkim.Radix.WorkspaceTours", isDirectory: true)
    }

    static func create() throws -> TourPracticeDirectory {
        let manager = FileManager.default
        let base = baseURL
        // The shared parent survives individual tours; reuse it after validating ownership.
        try manager.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isOwnedDirectory(base) else { throw CocoaError(.fileWriteNoPermission) }

        let id = UUID()
        let container = base.appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(
            at: container, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let ownership = Ownership(sessionID: id, processID: getpid())
            try JSONEncoder().encode(ownership).write(to: container.appendingPathComponent(markerName))
            let root = container.appendingPathComponent(String(localized: "Practice Folder"), isDirectory: true)
            let documents = root.appendingPathComponent(String(localized: "Documents"), isDirectory: true)
            let projects = documents.appendingPathComponent(String(localized: "Projects"), isDirectory: true)
            let downloads = root.appendingPathComponent(String(localized: "Downloads"), isDirectory: true)
            for directory in [projects, downloads] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let sampleText = String(localized: "These sample files were created for the Radix tour.") + "\n"
            let files: [(URL, Int)] = [
                (root.appendingPathComponent(String(localized: "Welcome.txt")), 1),
                (documents.appendingPathComponent(String(localized: "Notes.txt")), 64 * 1024),
                (projects.appendingPathComponent(String(localized: "Ideas.txt")), 160 * 1024),
                (downloads.appendingPathComponent(String(localized: "Example.txt")), 320 * 1024)
            ]
            for (url, bytes) in files {
                let text = String(repeating: sampleText, count: max(1, bytes / sampleText.utf8.count))
                try Data(text.utf8).write(to: url)
            }
            return TourPracticeDirectory(sessionID: id, containerURL: container, target: ScanTarget(url: root))
        } catch {
            // This path was just created exclusively for this attempt.
            try? manager.removeItem(at: container)
            throw error
        }
    }

    func remove() {
        guard let ownership = Self.ownership(of: containerURL),
              ownership.sessionID == sessionID,
              ownership.processID == getpid() else { return }
        try? FileManager.default.removeItem(at: containerURL)
    }

    static func removeAbandonedDirectories() {
        let base = baseURL
        guard isOwnedDirectory(base),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return }
        for entry in entries {
            guard let ownership = ownership(of: entry), ownership.processID > 0 else { continue }
            // A second Radix instance may still be using its practice directory.
            guard kill(ownership.processID, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func ownership(of directory: URL) -> Ownership? {
        guard directory.deletingLastPathComponent().standardizedFileURL == baseURL.standardizedFileURL,
              let id = UUID(uuidString: directory.lastPathComponent),
              isOwnedDirectory(baseURL), isOwnedDirectory(directory) else { return nil }
        let marker = directory.appendingPathComponent(markerName)
        guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) < 2048,
              let data = try? Data(contentsOf: marker),
              let ownership = try? JSONDecoder().decode(Ownership.self, from: data),
              ownership.sessionID == id else { return nil }
        return ownership
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
}
