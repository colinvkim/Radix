import AppKit
import Foundation
import SwiftUI

extension ScanTarget {
    var sidebarTitle: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.path {
        case "/":
            return displayName
        case homePath:
            return "Home"
        case homePath + "/Desktop":
            return "Desktop"
        case homePath + "/Documents":
            return "Documents"
        case homePath + "/Downloads":
            return "Downloads"
        case homePath + "/Library":
            return "Library"
        case "/Applications":
            return "Applications"
        default:
            return displayName
        }
    }

    var sidebarSubtitle: String {
        if kind == .volume, let capacityDescription {
            return capacityDescription
        }
        return url.path
    }

    var sidebarSymbolName: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.path {
        case "/":
            return "internaldrive.fill"
        case homePath:
            return "house.fill"
        case homePath + "/Desktop":
            return "desktopcomputer"
        case homePath + "/Documents":
            return "doc.on.doc.fill"
        case homePath + "/Downloads":
            return "arrow.down.circle.fill"
        case homePath + "/Library":
            return "books.vertical.fill"
        case "/Applications":
            return "square.grid.2x2.fill"
        default:
            return kind == .volume ? "externaldrive.fill" : "folder.fill"
        }
    }

    private var capacityDescription: String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }

        let totalText = RadixFormatters.size(Int64(totalCapacity))
        let availableText = RadixFormatters.size(Int64(availableCapacity))
        return "\(availableText) free of \(totalText)"
    }
}

extension ScanWarningCategory {
    var symbolName: String {
        switch self {
        case .permissionDenied:
            return "hand.raised.fill"
        case .fileSystem:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }
}

extension URL {
    var navigationDisplayName: String {
        if path == "/" {
            let volumeName = try? resourceValues(forKeys: [.volumeNameKey]).volumeName
            return volumeName ?? "Macintosh HD"
        }

        let lastPathComponent = standardizedFileURL.lastPathComponent
        return lastPathComponent.isEmpty ? path : lastPathComponent
    }
}

extension View {
    func interactivePointer() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != isHovering else { return }
                isHovering = inside

                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                guard isHovering else { return }
                isHovering = false
                NSCursor.pop()
            }
    }
}
