import AppKit
import Combine
import Foundation

nonisolated enum TrashIdentityVerificationResult: Equatable, Sendable {
    case matches
    case missingScannedIdentity
    case missingCurrentItem
    case mismatch
    case metadataUnavailable(String)
}

@MainActor
struct AppSystemActions {
    var open: (URL) throws -> Void
    var openInTerminal: (URL) async throws -> Void
    var reveal: (URL) -> Void
    var revealMany: ([URL]) -> Void
    var copyPath: (URL) throws -> Void
    var copyPaths: ([URL]) throws -> Void
    var moveToTrash: @MainActor (FileNodeRecord) async throws -> TrashIdentityVerificationResult
    var validateQuickLookSelection: ([FileNodeRecord], ScanSnapshotSource) async throws -> Void
    var prepareAndOpenFullDiskAccessSettings: () -> Bool
    var fullDiskAccessStatus: @MainActor () async -> FullDiskAccessStatus
    var defaultTargets: () -> [ScanTarget]
    var targetCapacityDescriptions: @MainActor () async -> [String: String]
    var volumeAvailableCapacityForImportantUsage: @MainActor (URL) async -> Int64?
    var trashSafetyPolicy: () -> TrashSafetyPolicy
    var presentOpenPanel: () -> ScanTarget?
    var presentExportScanPanel: (String) async -> URL?
    var presentImportScanPanel: () -> URL?
    var presentComparisonSnapshotPanel: () async -> URL?
    var fileExists: (URL) -> Bool
    var verifyTrashIdentity: (FileNodeRecord) -> TrashIdentityVerificationResult
    var isExistingDirectory: (URL) -> Bool
    var preferredSmartTargetIDs: () -> [String]
    var mountedVolumeEvents: () -> AnyPublisher<Void, Never>

    static let live = AppSystemActions(
        open: { try SystemIntegration.open($0) },
        openInTerminal: { try await SystemIntegration.openInTerminal($0) },
        reveal: { SystemIntegration.reveal($0) },
        revealMany: { SystemIntegration.reveal($0) },
        copyPath: { try SystemIntegration.copyPath($0) },
        copyPaths: { try SystemIntegration.copyPaths($0) },
        moveToTrash: { node in
            try await Task.detached(priority: .userInitiated) {
                try SystemIntegration.moveToTrash(node)
            }.value
        },
        validateQuickLookSelection: { nodes, source in
            let validation = Task.detached(priority: .userInitiated) {
                for node in nodes {
                    try Task.checkCancellation()
                    try FileActionValidation.validateLivePath(
                        node,
                        source: source,
                        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
                    )
                }
            }
            try await withTaskCancellationHandler {
                try await validation.value
            } onCancel: {
                validation.cancel()
            }
        },
        prepareAndOpenFullDiskAccessSettings: {
            SystemIntegration.prepareAndOpenFullDiskAccessSettings()
        },
        fullDiskAccessStatus: {
            await Task.detached(priority: .utility) {
                SystemIntegration.fullDiskAccessStatus()
            }.value
        },
        defaultTargets: {
            SystemIntegration.defaultTargets()
        },
        targetCapacityDescriptions: {
            await Task.detached(priority: .utility) {
                SystemIntegration.targetCapacityDescriptions()
            }.value
        },
        volumeAvailableCapacityForImportantUsage: { url in
            await Task.detached(priority: .utility) {
                SystemIntegration.volumeAvailableCapacityForImportantUsage(for: url)
            }.value
        },
        trashSafetyPolicy: {
            TrashSafetyPolicy.live()
        },
        presentOpenPanel: {
            SystemIntegration.presentScanPanel()
        },
        presentExportScanPanel: { defaultFileName in
            await SystemIntegration.presentExportScanPanel(defaultFileName: defaultFileName)
        },
        presentImportScanPanel: {
            SystemIntegration.presentImportScanPanel()
        },
        presentComparisonSnapshotPanel: {
            await SystemIntegration.presentComparisonSnapshotPanel()
        },
        fileExists: { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        verifyTrashIdentity: { node in
            SystemIntegration.verifyTrashIdentity(node)
        },
        isExistingDirectory: { url in
            Self.isExistingDirectoryURL(url)
        },
        preferredSmartTargetIDs: {
            Self.defaultPreferredSmartTargetIDs()
        },
        mountedVolumeEvents: {
            let workspaceNotifications = NSWorkspace.shared.notificationCenter
            return workspaceNotifications.publisher(for: NSWorkspace.didMountNotification)
                .merge(with: workspaceNotifications.publisher(for: NSWorkspace.didUnmountNotification))
                .merge(with: workspaceNotifications.publisher(for: NSWorkspace.didRenameVolumeNotification))
                .map { _ in () }
                .eraseToAnyPublisher()
        }
    )

    static let inert = AppSystemActions(
        open: { _ in },
        openInTerminal: { _ in },
        reveal: { _ in },
        revealMany: { _ in },
        copyPath: { _ in },
        copyPaths: { _ in },
        moveToTrash: { _ in .matches },
        validateQuickLookSelection: { _, _ in },
        prepareAndOpenFullDiskAccessSettings: { true },
        fullDiskAccessStatus: { .unknown },
        defaultTargets: { [] },
        targetCapacityDescriptions: { [:] },
        volumeAvailableCapacityForImportantUsage: { _ in nil },
        trashSafetyPolicy: {
            TrashSafetyPolicy.live()
        },
        presentOpenPanel: { nil },
        presentExportScanPanel: { _ in nil },
        presentImportScanPanel: { nil },
        presentComparisonSnapshotPanel: { nil },
        fileExists: { _ in false },
        verifyTrashIdentity: { _ in .matches },
        isExistingDirectory: { _ in false },
        preferredSmartTargetIDs: { [] },
        mountedVolumeEvents: { Empty().eraseToAnyPublisher() }
    )

    private static func defaultPreferredSmartTargetIDs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            "/",
            home,
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
            home + "/Library",
            "/Applications"
        ]
    }

    private static func isExistingDirectoryURL(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            return true
        }

        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        } catch {
            return false
        }
    }
}
