import SwiftUI

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var fileListFilterAction: (() -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }
}
