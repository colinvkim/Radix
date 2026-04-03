import SwiftUI

enum FileBrowserFindTarget {
    case currentContents
    case entireScan
}

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = (FileBrowserFindTarget) -> Void
}

extension FocusedValues {
    var fileListFilterAction: ((FileBrowserFindTarget) -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }
}
