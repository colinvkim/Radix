//
//  SystemIntegration.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import AppKit
import Foundation

enum SystemIntegration {
    private static var isRunningInsideXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    @MainActor
    static func presentScanPanel() -> ScanTarget? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or mounted volume to analyze."

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return ScanTarget(url: url)
    }

    static func defaultTargets() -> [ScanTarget] {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let downloadsDirectory = homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        let desktopDirectory = homeDirectory.appending(path: "Desktop", directoryHint: .isDirectory)
        let documentsDirectory = homeDirectory.appending(path: "Documents", directoryHint: .isDirectory)
        let libraryDirectory = homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        let applicationsDirectory = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let startupDisk = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .volume)

        var targets = [startupDisk, ScanTarget(url: homeDirectory)]
        for url in [desktopDirectory, documentsDirectory, downloadsDirectory, libraryDirectory, applicationsDirectory] {
            if fileManager.fileExists(atPath: url.path) {
                targets.append(ScanTarget(url: url))
            }
        }

        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in mountedVolumes where volume.path != "/" {
            targets.append(ScanTarget(url: volume, kind: .volume))
        }

        return deduplicate(targets)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    static func moveToTrash(_ url: URL) throws {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }

    static func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    @discardableResult
    static func openFullDiskAccessSettings() -> Bool {
        guard !isRunningInsideXcodePreview else {
            return false
        }

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func prepareAndOpenFullDiskAccessSettings() -> Bool {
        guard !isRunningInsideXcodePreview else {
            return false
        }

        primeFullDiskAccessListEntry()
        return openFullDiskAccessSettings()
    }

    static func primeFullDiskAccessListEntry() {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let candidateDirectories = [
            homeDirectory.appending(path: "Library/Mail", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Library/Messages", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Library/Safari", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Library/HomeKit", directoryHint: .isDirectory),
            URL(filePath: "/Library/Application Support/com.apple.TCC", directoryHint: .isDirectory)
        ]

        for directory in candidateDirectories where fileManager.fileExists(atPath: directory.path) {
            _ = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
    }

    private static func deduplicate(_ targets: [ScanTarget]) -> [ScanTarget] {
        var seen = Set<String>()
        return targets.filter { target in
            seen.insert(target.id).inserted
        }
    }
}

enum PermissionAdvisor {
    private static let fullDiskAccessProtectedPathFragments = [
        "/Library/Mail",
        "/Library/Messages",
        "/Library/Safari",
        "/Library/HomeKit",
        "/Library/Application Support/com.apple.TCC",
    ]

    static func shouldSuggestFullDiskAccess(for snapshot: ScanSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.scanWarnings.contains(where: { warning in
            warning.category == .permissionDenied &&
                fullDiskAccessProtectedPathFragments.contains(where: { warning.path.contains($0) })
        })
    }
}
