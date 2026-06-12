import Foundation
import SwiftUI

private let cachedHomePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

extension ScanTarget {
    var sidebarTitle: String {
        switch url.path {
        case "/":
            return displayName
        case cachedHomePath:
            return "Home"
        case cachedHomePath + "/Desktop":
            return "Desktop"
        case cachedHomePath + "/Documents":
            return "Documents"
        case cachedHomePath + "/Downloads":
            return "Downloads"
        case cachedHomePath + "/Library":
            return "Library"
        case "/Applications":
            return "Applications"
        default:
            return displayName
        }
    }

    var sidebarSubtitle: String {
        return url.path
    }

    var sidebarSymbolName: String {
        switch url.path {
        case "/":
            return "internaldrive.fill"
        case cachedHomePath:
            return "house.fill"
        case cachedHomePath + "/Desktop":
            return "desktopcomputer"
        case cachedHomePath + "/Documents":
            return "doc.on.doc.fill"
        case cachedHomePath + "/Downloads":
            return "arrow.down.circle.fill"
        case cachedHomePath + "/Library":
            return "books.vertical.fill"
        case "/Applications":
            return "square.grid.2x2.fill"
        default:
            return kind == .volume ? "externaldrive.fill" : "folder.fill"
        }
    }

}

extension ScanWarningCategory {
    var symbolName: String {
        switch self {
        case .permissionDenied:
            return "hand.raised.fill"
        case .fileSystem:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum RadixSystemImages {
    static var quickLook: String {
        FileNodeAction.quickLook.systemImageName
    }

    static var revealInFinder: String {
        FileNodeAction.revealInFinder.systemImageName
    }

    static var copyPath: String {
        FileNodeAction.copyPath.systemImageName
    }
}

extension FullDiskAccessStatus {
    var fullDiskAccessBadgeTitle: String {
        switch self {
        case .granted:
            return "Enabled"
        case .notGranted:
            return "Not Enabled"
        case .unknown:
            return "Unknown"
        }
    }

    var fullDiskAccessSettingsSummary: String {
        switch self {
        case .granted:
            return "Full Disk Access is enabled."
        case .notGranted:
            return "Full Disk Access is not enabled."
        case .unknown:
            return "Full Disk Access could not be verified."
        }
    }

    var fullDiskAccessSystemImage: String {
        switch self {
        case .granted:
            return "checkmark.circle.fill"
        case .notGranted:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var fullDiskAccessColor: Color {
        switch self {
        case .granted:
            return .green
        case .notGranted:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}
