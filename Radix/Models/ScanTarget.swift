//
//  ScanTarget.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

nonisolated enum ScanTargetKind: String, Hashable, Codable, Sendable {
    case folder
    case volume
}

nonisolated struct ScanTarget: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let kind: ScanTargetKind

    nonisolated init(
        url: URL,
        kind: ScanTargetKind? = nil
    ) {
        let normalizedURL = ScanTarget.normalizedURL(from: url)
        self.id = normalizedURL.path
        self.url = normalizedURL
        self.displayName = ScanTarget.displayName(for: normalizedURL)
        self.kind = kind ?? ScanTarget.inferredKind(for: normalizedURL)
    }

    nonisolated init(
        id: String,
        url: URL,
        displayName: String,
        kind: ScanTargetKind
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.kind = kind
    }

    private nonisolated static func normalizedURL(from url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        for syntheticPrefix in ["/.nofollow", "/.resolve"] {
            guard path == syntheticPrefix || path.hasPrefix(syntheticPrefix + "/") else { continue }

            let trimmedPath = String(path.dropFirst(syntheticPrefix.count))
            let normalizedPath = trimmedPath.isEmpty ? "/" : trimmedPath
            let syntheticResolvedURL = URL(
                fileURLWithPath: normalizedPath,
                isDirectory: standardizedURL.hasDirectoryPath
            )
            return normalizedRootURL(from: syntheticResolvedURL)
        }

        return normalizedRootURL(from: standardizedURL)
    }

    private nonisolated static func normalizedRootURL(from url: URL) -> URL {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: resolvedURL.path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    nonisolated static func inferredKind(
        for url: URL,
        mountedVolumeURLs: [URL]? = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )
    ) -> ScanTargetKind {
        let path = url.standardizedFileURL.path
        if path == "/" {
            return .volume
        }

        guard let mountedVolumeURLs else {
            return .folder
        }

        let mountedVolumePaths = Set(mountedVolumeURLs.map { $0.standardizedFileURL.path })
        return mountedVolumePaths.contains(path) ? .volume : .folder
    }

    nonisolated static func displayName(for url: URL, knownPath: String? = nil) -> String {
        let path = knownPath ?? url.path
        if path == "/" {
            do {
                let volumeName = try url.resourceValues(forKeys: [.volumeNameKey]).volumeName
                return volumeName ?? "Startup Disk"
            } catch {
                return "Startup Disk"
            }
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? path : lastPathComponent
    }
}

nonisolated struct ScanOptions: Hashable, Codable, Sendable {
    var includeHiddenFiles = false
    var treatPackagesAsDirectories = false
    var autoSummarizeDirectories = true
    var exclusionPatterns: [String] = []
    var exclusionRootPath: String?
    /// Override for the minimum file count to trigger auto-summarization.
    /// When nil, the ScanEngine default (5,000) is used.
    var autoSummarizeMinFileCount: Int?
    /// Override for the maximum average file size to trigger auto-summarization.
    /// When nil, the ScanEngine default (4 KB) is used.
    var autoSummarizeMaxAverageFileSize: Int64?
    /// Override for the minimum depth at which auto-summarization applies.
    /// When nil, the ScanEngine default (2) is used.
    var autoSummarizeMinDepthForSummarization: Int?
    /// Override for bounded package/atomic summary parallelism.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var atomicSummaryWorkerLimit: Int?
    /// Override for bounded immediate-child metadata classification.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var directoryClassificationWorkerLimit: Int?
    /// Override for bounded ordinary directory traversal parallelism.
    /// When nil, the ScanEngine chooses a hardware-aware default.
    var directoryTraversalWorkerLimit: Int?

    /// Archive-only compatibility values. New scans leave these nil, so the
    /// synthesized encoder omits the retired keys. Legacy archives preserve
    /// their exact values and fingerprints, and remain unequal to scans with
    /// different cloud-storage coverage.
    private var includeCloudStorage: Bool?
    private var cloudStorageRootPath: String?
    private var iCloudDriveRootPath: String?

    init(
        includeHiddenFiles: Bool = false,
        treatPackagesAsDirectories: Bool = false,
        autoSummarizeDirectories: Bool = true,
        exclusionPatterns: [String] = [],
        exclusionRootPath: String? = nil,
        autoSummarizeMinFileCount: Int? = nil,
        autoSummarizeMaxAverageFileSize: Int64? = nil,
        autoSummarizeMinDepthForSummarization: Int? = nil,
        atomicSummaryWorkerLimit: Int? = nil,
        directoryClassificationWorkerLimit: Int? = nil,
        directoryTraversalWorkerLimit: Int? = nil
    ) {
        self.includeHiddenFiles = includeHiddenFiles
        self.treatPackagesAsDirectories = treatPackagesAsDirectories
        self.autoSummarizeDirectories = autoSummarizeDirectories
        self.exclusionPatterns = exclusionPatterns
        self.exclusionRootPath = exclusionRootPath
        self.autoSummarizeMinFileCount = autoSummarizeMinFileCount
        self.autoSummarizeMaxAverageFileSize = autoSummarizeMaxAverageFileSize
        self.autoSummarizeMinDepthForSummarization = autoSummarizeMinDepthForSummarization
        self.atomicSummaryWorkerLimit = atomicSummaryWorkerLimit
        self.directoryClassificationWorkerLimit = directoryClassificationWorkerLimit
        self.directoryTraversalWorkerLimit = directoryTraversalWorkerLimit
        self.includeCloudStorage = nil
        self.cloudStorageRootPath = nil
        self.iCloudDriveRootPath = nil
    }
}

nonisolated enum CloudStorageLocation {
    enum Impact: Equatable, Sendable {
        case storedInCloud
        case containsCloudStorage
    }

    private static let userRelativeRoots = [
        "Library/CloudStorage",
        "Library/Mobile Documents"
    ]

    static func contains(path: String) -> Bool {
        let normalizedPath = normalize(path)
        if managedRootsForCurrentUser.contains(where: { isEqualOrDescendant(normalizedPath, of: $0) }) {
            return true
        }
        return genericUserRoots(for: normalizedPath).contains {
            isEqualOrDescendant(normalizedPath, of: $0)
        }
    }

    static func impact(
        of url: URL,
        cloudRootExists: (URL) -> Bool
    ) -> Impact? {
        let normalizedPath = normalize(url.standardizedFileURL.path)
        let roots = Set(managedRootsForCurrentUser + genericUserRoots(for: normalizedPath))
        if roots.contains(where: { isEqualOrDescendant(normalizedPath, of: $0) }) {
            return .storedInCloud
        }
        let containsExistingRoot = roots.contains { root in
            isEqualOrDescendant(root, of: normalizedPath)
                && cloudRootExists(URL(filePath: root, directoryHint: .isDirectory))
        }
        return containsExistingRoot ? .containsCloudStorage : nil
    }

    private static let managedRootsForCurrentUser = userRelativeRoots.map { relativePath in
        normalize(
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: relativePath, directoryHint: .isDirectory)
                .path
        )
    }

    private static func genericUserRoots(for path: String) -> [String] {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return [] }
        let homePath = "/Users/\(components[1])"
        return userRelativeRoots.map { "\(homePath)/\($0)" }
    }

    private static func isEqualOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
