//
//  TrashSafetyPolicy.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import Foundation

enum TrashSafetyBlockReason: Equatable, Sendable {
    case protectedRoot(path: String)

    nonisolated var path: String {
        switch self {
        case .protectedRoot(let path):
            return path
        }
    }
}

struct TrashSafetyPolicy: Sendable {
    struct FirmlinkEntry: Equatable, Sendable {
        let visiblePath: String
        let dataRelativePath: String

        nonisolated init(visiblePath: String, dataRelativePath: String) {
            self.visiblePath = visiblePath
            self.dataRelativePath = dataRelativePath
        }
    }

    private nonisolated static let staticProtectedRootPaths = [
        "/",
        "/Applications",
        "/Library",
        "/System",
        "/System/Volumes",
        "/System/Volumes/Data",
        "/Users",
        "/Volumes",
        "/bin",
        "/dev",
        "/etc",
        "/private",
        "/sbin",
        "/tmp",
        "/usr",
        "/var"
    ]

    private nonisolated static let fallbackFirmlinkEntries = [
        FirmlinkEntry(visiblePath: "/AppleInternal", dataRelativePath: "AppleInternal"),
        FirmlinkEntry(visiblePath: "/Applications", dataRelativePath: "Applications"),
        FirmlinkEntry(visiblePath: "/Library", dataRelativePath: "Library"),
        FirmlinkEntry(visiblePath: "/System/Library/Caches", dataRelativePath: "System/Library/Caches"),
        FirmlinkEntry(visiblePath: "/System/Library/Assets", dataRelativePath: "System/Library/Assets"),
        FirmlinkEntry(visiblePath: "/System/Library/PreinstalledAssets", dataRelativePath: "System/Library/PreinstalledAssets"),
        FirmlinkEntry(visiblePath: "/System/Library/AssetsV2", dataRelativePath: "System/Library/AssetsV2"),
        FirmlinkEntry(visiblePath: "/System/Library/PreinstalledAssetsV2", dataRelativePath: "System/Library/PreinstalledAssetsV2"),
        FirmlinkEntry(visiblePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library", dataRelativePath: "System/Library/CoreServices/CoreTypes.bundle/Contents/Library"),
        FirmlinkEntry(visiblePath: "/System/Library/Speech", dataRelativePath: "System/Library/Speech"),
        FirmlinkEntry(visiblePath: "/Users", dataRelativePath: "Users"),
        FirmlinkEntry(visiblePath: "/Volumes", dataRelativePath: "Volumes"),
        FirmlinkEntry(visiblePath: "/cores", dataRelativePath: "cores"),
        FirmlinkEntry(visiblePath: "/opt", dataRelativePath: "opt"),
        FirmlinkEntry(visiblePath: "/pkg", dataRelativePath: "pkg"),
        FirmlinkEntry(visiblePath: "/private", dataRelativePath: "private"),
        FirmlinkEntry(visiblePath: "/usr/local", dataRelativePath: "usr/local"),
        FirmlinkEntry(visiblePath: "/usr/libexec/cups", dataRelativePath: "usr/libexec/cups"),
        FirmlinkEntry(visiblePath: "/usr/share/snmp", dataRelativePath: "usr/share/snmp")
    ]

    private nonisolated static let defaultFirmlinkEntries: [FirmlinkEntry] = {
        entriesFromFirmlinkFile(at: URL(fileURLWithPath: "/usr/share/firmlinks"))
            ?? fallbackFirmlinkEntries
    }()

    private let protectedRootPaths: Set<String>

    nonisolated init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        mountedVolumeURLs: [URL]? = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ),
        firmlinkEntries: [FirmlinkEntry] = TrashSafetyPolicy.defaultFirmlinkEntries
    ) {
        var paths = Set(Self.staticProtectedRootPaths.map(Self.standardizedPath(forPath:)))

        let homePath = Self.standardizedPath(for: homeDirectory)
        paths.insert(homePath)
        if let dataHomePath = Self.dataVolumePath(forAbsolutePath: homePath) {
            paths.insert(dataHomePath)
        }

        for volumeURL in mountedVolumeURLs ?? [] {
            paths.insert(Self.standardizedPath(for: volumeURL))
        }

        for entry in firmlinkEntries {
            paths.insert(Self.standardizedPath(forPath: entry.visiblePath))
            if let dataPath = Self.dataVolumePath(forRelativePath: entry.dataRelativePath) {
                paths.insert(dataPath)
            }
        }

        self.protectedRootPaths = paths
    }

    nonisolated static func live() -> TrashSafetyPolicy {
        TrashSafetyPolicy()
    }

    nonisolated static func blockReason(for url: URL) -> TrashSafetyBlockReason? {
        live().blockReason(for: url)
    }

    nonisolated func blockReason(for url: URL) -> TrashSafetyBlockReason? {
        let path = Self.standardizedPath(for: url)
        guard protectedRootPaths.contains(path) else { return nil }
        return .protectedRoot(path: path)
    }

    nonisolated static func parseFirmlinkEntries(_ contents: String) -> [FirmlinkEntry] {
        contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> FirmlinkEntry? in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }

                let parts = trimmedLine
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)

                guard let visiblePath = parts.first else { return nil }
                let dataRelativePath = parts.dropFirst().first ?? String(visiblePath.drop { $0 == "/" })
                guard !dataRelativePath.isEmpty else { return nil }

                return FirmlinkEntry(
                    visiblePath: visiblePath,
                    dataRelativePath: dataRelativePath
                )
            }
    }

    private nonisolated static func entriesFromFirmlinkFile(at url: URL) -> [FirmlinkEntry]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let entries = parseFirmlinkEntries(contents)
        return entries.isEmpty ? nil : entries
    }

    private nonisolated static func dataVolumePath(forAbsolutePath path: String) -> String? {
        dataVolumePath(forRelativePath: String(path.drop { $0 == "/" }))
    }

    private nonisolated static func dataVolumePath(forRelativePath path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        return standardizedPath(forPath: "/System/Volumes/Data/" + trimmedPath)
    }

    private nonisolated static func standardizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func standardizedPath(forPath path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
