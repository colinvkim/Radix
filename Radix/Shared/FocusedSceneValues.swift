import SwiftUI

enum FileBrowserSearchScope: String, CaseIterable, Identifiable {
    case currentContents
    case entireScan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentContents:
            return "Current Contents"
        case .entireScan:
            return "Entire Scan"
        }
    }
}

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = (FileBrowserSearchScope) -> Void
}

extension FocusedValues {
    var fileListFilterAction: ((FileBrowserSearchScope) -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }
}
