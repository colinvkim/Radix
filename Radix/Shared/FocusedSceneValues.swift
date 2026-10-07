import SwiftUI

enum WorkspaceFocusTarget: Hashable {
    case chart
    case contents
}

enum ChartViewportAction {
    case zoomIn
    case zoomOut
    case reset
}

private struct DiscardPileUndoContextKey: FocusedValueKey {
    typealias Value = Bool
}

private struct WorkspaceWindowFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

private struct FileListFilterActionKey: FocusedValueKey {
    typealias Value = (FileBrowserFindTarget) -> Void
}

private struct FileListSearchActiveKey: FocusedValueKey {
    typealias Value = Bool
}

private struct ChartViewportActionKey: FocusedValueKey {
    typealias Value = (ChartViewportAction) -> Void
}

extension FocusedValues {
    var isDiscardPileUndoContext: Bool? {
        get { self[DiscardPileUndoContextKey.self] }
        set { self[DiscardPileUndoContextKey.self] = newValue }
    }

    var isWorkspaceWindowFocused: Bool? {
        get { self[WorkspaceWindowFocusedKey.self] }
        set { self[WorkspaceWindowFocusedKey.self] = newValue }
    }

    var fileListFilterAction: ((FileBrowserFindTarget) -> Void)? {
        get { self[FileListFilterActionKey.self] }
        set { self[FileListFilterActionKey.self] = newValue }
    }

    var isFileListSearchActive: Bool? {
        get { self[FileListSearchActiveKey.self] }
        set { self[FileListSearchActiveKey.self] = newValue }
    }

    var chartViewportAction: ((ChartViewportAction) -> Void)? {
        get { self[ChartViewportActionKey.self] }
        set { self[ChartViewportActionKey.self] = newValue }
    }
}
