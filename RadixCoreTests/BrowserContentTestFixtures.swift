import Foundation

@testable import RadixCore

@MainActor
func makeBrowserTestNavigation(
    snapshot: ScanSnapshot,
    focusedNodeID: String? = nil
) -> WorkspaceNavigationModel {
    let navigation = WorkspaceNavigationModel()
    navigation.updateScanContext(snapshot: snapshot)
    if let focusedNodeID {
        navigation.setFocusedNodeID(focusedNodeID)
    }
    return navigation
}

@MainActor
func makeBrowserTestNavigation(
    children: [FileNodeRecord],
    rootID: String = "/root"
) -> WorkspaceNavigationModel {
    let root = makeTestDirectoryNode(id: rootID, name: URL(filePath: rootID).lastPathComponent, children: children)
    let store = FileTreeStore(root: root, childrenByID: [root.id: children])
    return makeBrowserTestNavigation(snapshot: makeTestSnapshot(root: root, store: store))
}
