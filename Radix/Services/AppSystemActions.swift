//
//  AppSystemActions.swift
//  Radix
//

import AppKit
import Combine
import Foundation

@MainActor
struct AppQuickLookActions {
    var isPreviewVisible: () -> Bool
    var isPreviewPanelKeyWindow: () -> Bool
    var present: (URL) throws -> Void
    var toggle: (URL) throws -> Void
    var updateVisiblePreview: (URL?) -> Void
    var close: () -> Void

    static let live = AppQuickLookActions(
        isPreviewVisible: { SystemIntegration.isQuickLookPreviewVisible },
        isPreviewPanelKeyWindow: { SystemIntegration.isQuickLookPreviewPanelKeyWindow },
        present: { try SystemIntegration.presentQuickLookPreview(for: $0) },
        toggle: { try SystemIntegration.toggleQuickLookPreview(for: $0) },
        updateVisiblePreview: { SystemIntegration.updateVisibleQuickLookPreview(for: $0) },
        close: { SystemIntegration.closeQuickLookPreview() }
    )

    static let disabled = AppQuickLookActions(
        isPreviewVisible: { false },
        isPreviewPanelKeyWindow: { false },
        present: { _ in },
        toggle: { _ in },
        updateVisiblePreview: { _ in },
        close: {}
    )
}

@MainActor
final class AppEventMonitorToken {
    private var removeAction: (() -> Void)?

    init(remove: @escaping () -> Void) {
        removeAction = remove
    }

    func remove() {
        guard let removeAction else { return }
        self.removeAction = nil
        removeAction()
    }

    deinit {
        MainActor.assumeIsolated {
            remove()
        }
    }
}

@MainActor
struct AppSystemActions {
    var open: (URL) throws -> Void
    var reveal: (URL) -> Void
    var revealMany: ([URL]) -> Void
    var copyPath: (URL) throws -> Void
    var copyPaths: ([URL]) throws -> Void
    var moveToTrash: (URL) throws -> Void
    var quickLook: AppQuickLookActions
    var prepareAndOpenFullDiskAccessSettings: () -> Bool
    var fullDiskAccessStatus: () -> FullDiskAccessStatus
    var defaultTargets: () -> [ScanTarget]
    var targetCapacityDescriptions: () -> [String: String]
    var volumeAvailableCapacityForImportantUsage: (URL) -> Int64?
    var trashSafetyPolicy: () -> TrashSafetyPolicy
    var asyncFullDiskAccessStatus: (@Sendable () async -> FullDiskAccessStatus)?
    var asyncTargetCapacityDescriptions: (@Sendable () async -> [String: String])?
    var presentOpenPanel: () -> ScanTarget?
    var fileExists: (URL) -> Bool
    var isExistingDirectory: (URL) -> Bool
    var preferredSmartTargetIDs: () -> [String]
    var mountedVolumeEvents: () -> AnyPublisher<Void, Never>
    var installQuickLookKeyMonitor: (@escaping (NSEvent) -> Bool) -> AppEventMonitorToken?

    static let live = AppSystemActions(
        open: { try SystemIntegration.open($0) },
        reveal: { SystemIntegration.reveal($0) },
        revealMany: { SystemIntegration.reveal($0) },
        copyPath: { try SystemIntegration.copyPath($0) },
        copyPaths: { try SystemIntegration.copyPaths($0) },
        moveToTrash: { try SystemIntegration.moveToTrash($0) },
        quickLook: .live,
        prepareAndOpenFullDiskAccessSettings: {
            SystemIntegration.prepareAndOpenFullDiskAccessSettings()
        },
        fullDiskAccessStatus: {
            SystemIntegration.fullDiskAccessStatus()
        },
        defaultTargets: {
            SystemIntegration.defaultTargets()
        },
        targetCapacityDescriptions: {
            SystemIntegration.targetCapacityDescriptions()
        },
        volumeAvailableCapacityForImportantUsage: {
            SystemIntegration.volumeAvailableCapacityForImportantUsage(for: $0)
        },
        trashSafetyPolicy: {
            TrashSafetyPolicy.live()
        },
        asyncFullDiskAccessStatus: {
            await Task.detached(priority: .utility) {
                SystemIntegration.fullDiskAccessStatus()
            }.value
        },
        asyncTargetCapacityDescriptions: {
            await Task.detached(priority: .utility) {
                SystemIntegration.targetCapacityDescriptions()
            }.value
        },
        presentOpenPanel: {
            SystemIntegration.presentScanPanel()
        },
        fileExists: { url in
            FileManager.default.fileExists(atPath: url.path)
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
        },
        installQuickLookKeyMonitor: { handler in
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                handler(event) ? nil : event
            }) else {
                return nil
            }
            return AppEventMonitorToken {
                NSEvent.removeMonitor(monitor)
            }
        }
    )

    static let inert = AppSystemActions(
        open: { _ in },
        reveal: { _ in },
        revealMany: { _ in },
        copyPath: { _ in },
        copyPaths: { _ in },
        moveToTrash: { _ in },
        quickLook: .disabled,
        prepareAndOpenFullDiskAccessSettings: { true },
        fullDiskAccessStatus: { .unknown },
        defaultTargets: { [] },
        targetCapacityDescriptions: { [:] },
        volumeAvailableCapacityForImportantUsage: { _ in nil },
        trashSafetyPolicy: {
            TrashSafetyPolicy.live()
        },
        asyncFullDiskAccessStatus: nil,
        asyncTargetCapacityDescriptions: nil,
        presentOpenPanel: { nil },
        fileExists: { _ in false },
        isExistingDirectory: { _ in false },
        preferredSmartTargetIDs: { [] },
        mountedVolumeEvents: { Empty().eraseToAnyPublisher() },
        installQuickLookKeyMonitor: { _ in nil }
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

extension AppSystemActions {
    var usesAsyncFullDiskAccessStatus: Bool {
        asyncFullDiskAccessStatus != nil
    }

    var usesAsyncTargetCapacityDescriptions: Bool {
        asyncTargetCapacityDescriptions != nil
    }

    func currentFullDiskAccessStatus() -> FullDiskAccessStatus {
        fullDiskAccessStatus()
    }

    func loadCurrentFullDiskAccessStatus() async -> FullDiskAccessStatus {
        if let asyncFullDiskAccessStatus {
            return await asyncFullDiskAccessStatus()
        }
        return fullDiskAccessStatus()
    }

    func currentTargetCapacityDescriptions() -> [String: String] {
        targetCapacityDescriptions()
    }

    func loadCurrentTargetCapacityDescriptions() async -> [String: String] {
        if let asyncTargetCapacityDescriptions {
            return await asyncTargetCapacityDescriptions()
        }
        return currentTargetCapacityDescriptions()
    }
}
