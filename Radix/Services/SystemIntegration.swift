//
//  SystemIntegration.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import AppKit
import Foundation

enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case notGranted
    case unknown
}

protocol SystemWorkspace {
    func activateFileViewerSelecting(_ fileURLs: [URL])
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: SystemWorkspace {}

protocol PathPasteboard {
    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PathPasteboard {}

enum SystemIntegration {
    typealias FullDiskAccessProbe = () throws -> Void
    private nonisolated static let requiredReadableDataVaultProbeCount = 2

    enum SystemIntegrationError: LocalizedError {
        case openFailed(path: String)
        case copyPathFailed(path: String)
        case quickLookUnavailable(path: String)
        case protectedTrashLocation(path: String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path):
                return "macOS could not open the item at \(path)."
            case .copyPathFailed(let path):
                return "macOS could not copy the path for \(path)."
            case .quickLookUnavailable(let path):
                return "The item at \(path) is no longer available for Quick Look."
            case .protectedTrashLocation(let path):
                return "Radix will not move the protected location at \(path) to the Trash."
            }
        }
    }

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

    nonisolated static func defaultTargets() -> [ScanTarget] {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let downloadsDirectory = homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        let desktopDirectory = homeDirectory.appending(path: "Desktop", directoryHint: .isDirectory)
        let documentsDirectory = homeDirectory.appending(path: "Documents", directoryHint: .isDirectory)
        let libraryDirectory = homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        let applicationsDirectory = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let startupDisk = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .volume)

        var targets = [startupDisk, ScanTarget(url: homeDirectory, kind: .folder)]
        for url in [desktopDirectory, documentsDirectory, downloadsDirectory, libraryDirectory, applicationsDirectory] {
            if fileManager.fileExists(atPath: url.path) {
                targets.append(ScanTarget(url: url, kind: .folder))
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

    nonisolated static func targetCapacityDescriptions() -> [String: String] {
        let fileManager = FileManager.default
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? [URL(filePath: "/", directoryHint: .isDirectory)]

        return targetCapacityDescriptions(
            mountedVolumes: mountedVolumes,
            capacityDescriptionForURL: capacityDescription(for:)
        )
    }

    nonisolated static func targetCapacityDescriptions(
        mountedVolumes: [URL],
        capacityDescriptionForURL: (URL) -> String?
    ) -> [String: String] {
        var descriptions: [String: String] = [:]
        descriptions.reserveCapacity(mountedVolumes.count)

        for volumeURL in mountedVolumes {
            guard let description = capacityDescriptionForURL(volumeURL) else { continue }
            descriptions[volumeURL.standardizedFileURL.path] = description
        }

        return descriptions
    }

    static func reveal(_ url: URL, workspace: SystemWorkspace = NSWorkspace.shared) {
        reveal([url], workspace: workspace)
    }

    static func reveal(_ urls: [URL], workspace: SystemWorkspace = NSWorkspace.shared) {
        workspace.activateFileViewerSelecting(urls)
    }

    static func open(_ url: URL, workspace: SystemWorkspace = NSWorkspace.shared) throws {
        guard workspace.open(url) else {
            throw SystemIntegrationError.openFailed(path: url.path)
        }
    }

    static func copyPath(_ url: URL, pasteboard: PathPasteboard = NSPasteboard.general) throws {
        pasteboard.clearContents()
        let copiedPath = pasteboard.setString(url.path, forType: .string)
        let copiedURL = pasteboard.setString(url.absoluteString, forType: .fileURL)

        guard copiedPath && copiedURL else {
            throw SystemIntegrationError.copyPathFailed(path: url.path)
        }
    }

    static func copyPaths(_ urls: [URL], pasteboard: PathPasteboard = NSPasteboard.general) throws {
        guard let firstURL = urls.first else { return }
        guard urls.count > 1 else {
            try copyPath(firstURL, pasteboard: pasteboard)
            return
        }

        pasteboard.clearContents()
        let paths = urls.map(\.path).joined(separator: "\n")

        guard pasteboard.setString(paths, forType: .string) else {
            throw SystemIntegrationError.copyPathFailed(path: firstURL.path)
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try validateCanMoveToTrash(url)
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }

    static func validateCanMoveToTrash(_ url: URL) throws {
        if let reason = TrashSafetyPolicy.blockReason(for: url) {
            throw SystemIntegrationError.protectedTrashLocation(path: reason.path)
        }
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
        _ = probeFullDiskAccess()
    }

    nonisolated static func fullDiskAccessStatus() -> FullDiskAccessStatus {
        probeFullDiskAccess()
    }

    private nonisolated static func probeFullDiskAccess() -> FullDiskAccessStatus {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let protectedDataVaultProbes = [
            ProtectedPathProbe(url: homeDirectory.appending(path: "Library/Mail", directoryHint: .isDirectory), kind: .directory),
            ProtectedPathProbe(url: homeDirectory.appending(path: "Library/Messages", directoryHint: .isDirectory), kind: .directory),
            ProtectedPathProbe(url: homeDirectory.appending(path: "Library/Safari", directoryHint: .isDirectory), kind: .directory),
            ProtectedPathProbe(url: homeDirectory.appending(path: "Library/HomeKit", directoryHint: .isDirectory), kind: .directory)
        ]
            .compactMap { candidate in
                makeFullDiskAccessProbe(for: candidate, using: fileManager)
            }

        let userTCCDatabaseProbe = makeFullDiskAccessProbe(
            for: ProtectedPathProbe(
                url: homeDirectory.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
                kind: .file
            ),
            using: fileManager
        )

        return fullDiskAccessStatus(
            userTCCDatabaseProbe: userTCCDatabaseProbe,
            protectedDataVaultProbes: protectedDataVaultProbes
        )
    }

    nonisolated static func fullDiskAccessStatus(
        userTCCDatabaseProbe: FullDiskAccessProbe?,
        protectedDataVaultProbes: [FullDiskAccessProbe]
    ) -> FullDiskAccessStatus {
        let foundProtectedCandidate = userTCCDatabaseProbe != nil || !protectedDataVaultProbes.isEmpty
        guard foundProtectedCandidate else { return .unknown }
        guard let userTCCDatabaseProbe,
              canReadFullDiskAccessProbe(userTCCDatabaseProbe) else {
            return .notGranted
        }

        let readableDataVaultProbeCount = protectedDataVaultProbes.reduce(into: 0) { count, probe in
            if canReadFullDiskAccessProbe(probe) {
                count += 1
            }
        }

        return readableDataVaultProbeCount >= requiredReadableDataVaultProbeCount ? .granted : .notGranted
    }

    private nonisolated static func makeFullDiskAccessProbe(
        for candidate: ProtectedPathProbe,
        using fileManager: FileManager
    ) -> FullDiskAccessProbe? {
        guard fileManager.fileExists(atPath: candidate.url.path) else { return nil }
        return {
            try candidate.probe(using: fileManager)
        }
    }

    private nonisolated static func canReadFullDiskAccessProbe(_ probe: FullDiskAccessProbe) -> Bool {
        do {
            try probe()
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func deduplicate(_ targets: [ScanTarget]) -> [ScanTarget] {
        var seen = Set<String>()
        return targets.filter { target in
            seen.insert(target.id).inserted
        }
    }

    private nonisolated static func capacityDescription(for url: URL) -> String? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
        } catch {
            return nil
        }

        guard let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }

        let totalText = capacityText(Int64(totalCapacity))
        let availableText = capacityText(Int64(availableCapacity))
        return "\(availableText) free of \(totalText)"
    }

    private nonisolated static func capacityText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct ProtectedPathProbe {
    enum Kind {
        case directory
        case file
    }

    var url: URL
    var kind: Kind

    nonisolated func probe(using fileManager: FileManager) throws {
        switch kind {
        case .directory:
            _ = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
        case .file:
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
        }
    }
}

enum PermissionAdvisor {
    // Fragments whose contents Full Disk Access actually unlocks. Note that the
    // TCC directory itself (/Library/Application Support/com.apple.TCC) is
    // root-owned/SIP-protected and stays unreadable even with FDA, so it must
    // not be listed here — matching it would suggest FDA for a grant that can
    // never resolve the warning.
    private static let fullDiskAccessProtectedPathFragments = [
        "/Library/Mail",
        "/Library/Messages",
        "/Library/Safari",
        "/Library/HomeKit",
    ]

    static func shouldSuggestFullDiskAccess(
        for snapshot: ScanSnapshot?,
        fullDiskAccessStatus: FullDiskAccessStatus
    ) -> Bool {
        // Don't nag for access that is already granted. Many system paths
        // (e.g. /Library/Caches/com.apple.iconservices.store) stay unreadable
        // regardless of FDA, so warning presence alone must not drive the prompt.
        guard fullDiskAccessStatus != .granted else { return false }
        guard let snapshot else { return false }
        return snapshot.scanWarnings.contains(where: { warning in
            warning.category == .permissionDenied &&
                fullDiskAccessProtectedPathFragments.contains(where: { warning.path.contains($0) })
        })
    }
}
