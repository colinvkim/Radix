import Foundation

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
        if kind == .volume, let capacityDescription {
            return capacityDescription
        }
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

    private var capacityDescription: String? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        } catch {
            return nil
        }

        guard let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity = values.volumeAvailableCapacityForImportantUsage else { return nil }

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
        }
    }
}
