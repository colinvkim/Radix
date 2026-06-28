//
//  SystemIntegration.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

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
    private nonisolated static let requiredReadableMacOS27SentinelCount = 2
    private nonisolated static let macOS27MajorVersion = 27

    private enum CurrentIdentityError: Error {
        case missingCurrentItem
        case metadataUnavailable(String)

        var verificationResult: TrashIdentityVerificationResult {
            switch self {
            case .missingCurrentItem:
                return .missingCurrentItem
            case .metadataUnavailable(let message):
                return .metadataUnavailable(message)
            }
        }
    }

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

    private static var radixScanArchiveContentType: UTType {
        UTType(exportedAs: ScanArchiveService.formatIdentifier, conformingTo: .package)
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

    @MainActor
    static func presentExportScanPanel(defaultFileName: String) async -> URL? {
        guard !Task.isCancelled else { return nil }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [radixScanArchiveContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName
        panel.prompt = "Export"

        let cancellationState = ExportPanelCancellationState()
        let presentation = ExportPanelPresentation(
            panel: panel,
            parentWindow: exportPanelParentWindow,
            cancellationState: cancellationState
        )
        let selectedURL = await withTaskCancellationHandler {
            await presentation.begin()
        } onCancel: {
            cancellationState.cancel()
            Task { @MainActor in
                presentation.cancel()
            }
        }
        return normalizedExportPanelURL(selectedURL)
    }

    @MainActor
    static func presentImportScanPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [radixScanArchiveContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.prompt = "Import"

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }

    @MainActor
    private static var exportPanelParentWindow: NSWindow? {
        NSApp.mainWindow ??
            NSApp.keyWindow ??
            NSApp.windows.first { window in
                window.isVisible && !window.isMiniaturized
            }
    }

    private static func normalizedExportPanelURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if url.pathExtension.lowercased() == ScanArchiveService.fileExtension {
            return url
        }
        return url.appendingPathExtension(ScanArchiveService.fileExtension)
    }

    private nonisolated final class ExportPanelCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    @MainActor
    private final class ExportPanelPresentation {
        private let panel: NSSavePanel
        private let parentWindow: NSWindow?
        private let cancellationState: ExportPanelCancellationState
        private var continuation: CheckedContinuation<URL?, Never>?
        private var isFinished = false

        init(
            panel: NSSavePanel,
            parentWindow: NSWindow?,
            cancellationState: ExportPanelCancellationState
        ) {
            self.panel = panel
            self.parentWindow = parentWindow
            self.cancellationState = cancellationState
        }

        func begin() async -> URL? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !cancellationState.isCancelled, !Task.isCancelled else {
                    panel.orderOut(nil)
                    finish(returning: nil)
                    return
                }

                let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    Task { @MainActor in
                        self?.complete(response: response)
                    }
                }
                if let parentWindow {
                    panel.beginSheetModal(for: parentWindow, completionHandler: completionHandler)
                } else {
                    panel.begin(completionHandler: completionHandler)
                }
            }
        }

        func cancel() {
            guard !isFinished else { return }

            panel.cancel(nil)
            panel.orderOut(nil)
            finish(returning: nil)
        }

        private func complete(response: NSApplication.ModalResponse) {
            let selectedURL = response == .OK && !cancellationState.isCancelled ? panel.url : nil
            panel.orderOut(nil)
            finish(returning: selectedURL)
        }

        private func finish(returning url: URL?) {
            guard !isFinished else { return }

            isFinished = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: url)
        }
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
                .volumeAvailableCapacityKey,
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

    nonisolated static func volumeAvailableCapacityForImportantUsage(for url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
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

    nonisolated static func moveToTrash(_ url: URL) throws {
        try validateCanMoveToTrash(url)
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }

    nonisolated static func verifyTrashIdentity(_ node: FileNodeRecord) -> TrashIdentityVerificationResult {
        guard !node.isSynthetic else { return .matches }
        guard let scannedIdentity = node.fileIdentity else {
            return .missingScannedIdentity
        }

        switch currentFileSystemIdentity(for: node.url) {
        case .success(let currentIdentity):
            if node.isSymbolicLink || scannedIdentity.isFileSystemIdentity {
                return currentIdentity == scannedIdentity ? .matches : .mismatch
            }
        case .failure(let error):
            return error.verificationResult
        }

        switch currentResourceIdentity(for: node.url) {
        case .success(let currentIdentity):
            return currentIdentity == scannedIdentity ? .matches : .mismatch
        case .failure(let error):
            return error.verificationResult
        }
    }

    nonisolated static func validateCanMoveToTrash(_ url: URL) throws {
        if let reason = TrashSafetyPolicy.blockReason(for: url) {
            throw SystemIntegrationError.protectedTrashLocation(path: reason.path)
        }
    }

    private nonisolated static func currentFileSystemIdentity(for url: URL) -> Result<FileIdentity, CurrentIdentityError> {
        var fileStat = stat()
        errno = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }

        guard result == 0 else {
            return .failure(currentIdentityError(errnoCode: errno))
        }

        return .success(FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)))
    }

    private nonisolated static func currentResourceIdentity(for url: URL) -> Result<FileIdentity, CurrentIdentityError> {
        do {
            let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            guard let identifierData = values.fileResourceIdentifier as? Data else {
                return .failure(.metadataUnavailable("file resource identifier unavailable"))
            }
            return .success(FileIdentity(resourceIdentifier: identifierData))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                return .failure(.missingCurrentItem)
            }
            return .failure(.metadataUnavailable(ScanWarningFactory.diagnosticErrorDescription(error)))
        }
    }

    private nonisolated static func currentIdentityError(errnoCode: Int32) -> CurrentIdentityError {
        if errnoCode == ENOENT || errnoCode == ENOTDIR {
            return .missingCurrentItem
        }
        let message: String
        if let cString = strerror(errnoCode) {
            message = String(cString: cString)
        } else {
            message = "errno \(errnoCode)"
        }
        return .metadataUnavailable(message)
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
        let macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        guard macOSMajorVersion < macOS27MajorVersion else {
            let timeMachinePreferencesProbe = makeFullDiskAccessProbe(
                for: ProtectedPathProbe(
                    url: URL(filePath: "/Library/Preferences/com.apple.TimeMachine.plist"),
                    kind: .file
                ),
                using: fileManager
            )
            let stocksContainerProbe = makeFullDiskAccessProbe(
                for: ProtectedPathProbe(
                    url: homeDirectory.appending(path: "Library/Containers/com.apple.stocks", directoryHint: .isDirectory),
                    kind: .directory
                ),
                using: fileManager
            )
            let systemTCCDatabaseProbe = makeFullDiskAccessProbe(
                for: ProtectedPathProbe(
                    url: URL(filePath: "/Library/Application Support/com.apple.TCC/TCC.db"),
                    kind: .file
                ),
                using: fileManager
            )

            return fullDiskAccessStatus(
                macOSMajorVersion: macOSMajorVersion,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: timeMachinePreferencesProbe,
                stocksContainerProbe: stocksContainerProbe,
                systemTCCDatabaseProbe: systemTCCDatabaseProbe
            )
        }

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
            macOSMajorVersion: macOSMajorVersion,
            userTCCDatabaseProbe: userTCCDatabaseProbe,
            protectedDataVaultProbes: protectedDataVaultProbes,
            timeMachinePreferencesProbe: nil,
            stocksContainerProbe: nil,
            systemTCCDatabaseProbe: nil
        )
    }

    nonisolated static func fullDiskAccessStatus(
        macOSMajorVersion: Int,
        userTCCDatabaseProbe: FullDiskAccessProbe?,
        protectedDataVaultProbes: [FullDiskAccessProbe],
        timeMachinePreferencesProbe: FullDiskAccessProbe?,
        stocksContainerProbe: FullDiskAccessProbe?,
        systemTCCDatabaseProbe: FullDiskAccessProbe?
    ) -> FullDiskAccessStatus {
        guard macOSMajorVersion < macOS27MajorVersion else {
            return macOS27FullDiskAccessStatus(
                timeMachinePreferencesProbe: timeMachinePreferencesProbe,
                stocksContainerProbe: stocksContainerProbe,
                systemTCCDatabaseProbe: systemTCCDatabaseProbe
            )
        }

        return legacyFullDiskAccessStatus(
            userTCCDatabaseProbe: userTCCDatabaseProbe,
            protectedDataVaultProbes: protectedDataVaultProbes
        )
    }

    nonisolated static func fullDiskAccessStatus(
        userTCCDatabaseProbe: FullDiskAccessProbe?,
        protectedDataVaultProbes: [FullDiskAccessProbe]
    ) -> FullDiskAccessStatus {
        legacyFullDiskAccessStatus(
            userTCCDatabaseProbe: userTCCDatabaseProbe,
            protectedDataVaultProbes: protectedDataVaultProbes
        )
    }

    private nonisolated static func legacyFullDiskAccessStatus(
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

    private nonisolated static func macOS27FullDiskAccessStatus(
        timeMachinePreferencesProbe: FullDiskAccessProbe?,
        stocksContainerProbe: FullDiskAccessProbe?,
        systemTCCDatabaseProbe: FullDiskAccessProbe?
    ) -> FullDiskAccessStatus {
        let primaryProbes = [timeMachinePreferencesProbe, stocksContainerProbe]

        if primaryProbes.allSatisfy({ $0 != nil }) {
            return primaryProbes.allSatisfy { probe in
                guard let probe else { return false }
                return canReadFullDiskAccessProbe(probe)
            } ? .granted : .notGranted
        }

        let fallbackReadableCount = [timeMachinePreferencesProbe, stocksContainerProbe, systemTCCDatabaseProbe]
            .reduce(into: 0) { count, probe in
                if let probe, canReadFullDiskAccessProbe(probe) {
                    count += 1
                }
            }

        return fallbackReadableCount >= requiredReadableMacOS27SentinelCount ? .granted : .unknown
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
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
        } catch {
            return nil
        }

        return capacityDescription(
            totalCapacity: values.volumeTotalCapacity,
            availableCapacity: values.volumeAvailableCapacity,
            availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage
        )
    }

    nonisolated static func capacityDescription(
        totalCapacity: Int?,
        availableCapacity: Int?,
        availableCapacityForImportantUsage: Int64?
    ) -> String? {
        guard let totalCapacity,
              let resolvedAvailableCapacity = resolvedAvailableCapacity(
                  availableCapacity: availableCapacity,
                  availableCapacityForImportantUsage: availableCapacityForImportantUsage
              ) else {
            return nil
        }

        let totalText = capacityText(Int64(totalCapacity))
        let availableText = capacityText(resolvedAvailableCapacity)
        return "\(availableText) free of \(totalText)"
    }

    private nonisolated static func resolvedAvailableCapacity(
        availableCapacity: Int?,
        availableCapacityForImportantUsage: Int64?
    ) -> Int64? {
        if let availableCapacity {
            return Int64(availableCapacity)
        }
        return availableCapacityForImportantUsage
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
