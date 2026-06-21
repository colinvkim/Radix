import SwiftUI

enum WorkspaceFocusTarget: Hashable {
    case sidebar
    case chart
    case contents
}

enum SunburstViewportAction {
    case zoomIn
    case zoomOut
    case reset
}

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = (FileBrowserFindTarget) -> Void
}

private struct InspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct WorkspaceFocusActionKey: FocusedValueKey {
    typealias Value = (WorkspaceFocusTarget) -> Void
}

private struct SunburstViewportActionKey: FocusedValueKey {
    typealias Value = (SunburstViewportAction) -> Void
}

extension FocusedValues {
    var fileListFilterAction: ((FileBrowserFindTarget) -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }

    var inspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityKey.self] }
        set { self[InspectorVisibilityKey.self] = newValue }
    }

    var workspaceFocusAction: ((WorkspaceFocusTarget) -> Void)? {
        get { self[WorkspaceFocusActionKey.self] }
        set { self[WorkspaceFocusActionKey.self] = newValue }
    }

    var sunburstViewportAction: ((SunburstViewportAction) -> Void)? {
        get { self[SunburstViewportActionKey.self] }
        set { self[SunburstViewportActionKey.self] = newValue }
    }
}
