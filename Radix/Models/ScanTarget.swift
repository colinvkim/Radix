//
//  ScanTarget.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum ScanTargetKind: String, Hashable, Codable, Sendable {
    case folder
    case volume
}

struct ScanTarget: Identifiable, Hashable, Sendable {
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

    nonisolated static func displayName(for url: URL) -> String {
        if url.path == "/" {
            do {
                let volumeName = try url.resourceValues(forKeys: [.volumeNameKey]).volumeName
                return volumeName ?? "Startup Disk"
            } catch {
                return "Startup Disk"
            }
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }
}

nonisolated struct ScanOptions: Hashable, Codable, Sendable {
    var includeHiddenFiles = false
    var treatPackagesAsDirectories = false
    var autoSummarizeDirectories = true
    var includeCloudStorage = false
    var cloudStorageRootPath = ScanOptions.defaultCloudStorageRootPath
    var iCloudDriveRootPath = ScanOptions.defaultICloudDriveRootPath
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

    nonisolated static let defaultCloudStorageRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        .standardizedFileURL
        .path

    nonisolated static let defaultICloudDriveRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        .standardizedFileURL
        .path
}
