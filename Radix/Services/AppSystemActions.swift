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
    var copyPath: (URL) throws -> Void
    var moveToTrash: (URL) throws -> Void
    var quickLook: AppQuickLookActions
    var prepareAndOpenFullDiskAccessSettings: () -> Bool
    var fullDiskAccessStatus: () -> FullDiskAccessStatus
    var defaultTargets: () -> [ScanTarget]
    var targetCapacityDescriptions: () -> [String: String]
    var presentOpenPanel: () -> ScanTarget?
    var fileExists: (URL) -> Bool
    var isExistingDirectory: (URL) -> Bool
    var preferredSmartTargetIDs: () -> [String]
    var mountedVolumeEvents: () -> AnyPublisher<Void, Never>
    var installQuickLookKeyMonitor: (@escaping (NSEvent) -> Bool) -> AppEventMonitorToken?

    static let live = AppSystemActions(
        open: { try SystemIntegration.open($0) },
        reveal: { SystemIntegration.reveal($0) },
        copyPath: { try SystemIntegration.copyPath($0) },
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
        copyPath: { _ in },
        moveToTrash: { _ in },
        quickLook: .disabled,
        prepareAndOpenFullDiskAccessSettings: { true },
        fullDiskAccessStatus: { .unknown },
        defaultTargets: { [] },
        targetCapacityDescriptions: { [:] },
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
