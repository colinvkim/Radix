//
//  SunburstFreeSpaceVisualization.swift
//  Radix
//

import Foundation

struct SunburstVisualizationInput: Sendable {
    let rootNode: FileNodeRecord
    let treeStore: FileTreeStore
    let layoutIDComponent: String
}

enum SunburstFreeSpaceVisualization {
    private nonisolated static let visualRootSuffix = "\u{0}radix-volume-capacity"
    private nonisolated static let freeSpaceSuffix = "\u{0}radix-free-space"
    private nonisolated static let disabledLayoutComponent = "free-space:0"

    nonisolated static func input(
        snapshot: ScanSnapshot,
        focusNode: FileNodeRecord,
        showFreeSpace: Bool,
        availableCapacity: Int64?
    ) -> SunburstVisualizationInput {
        guard showFreeSpace,
              snapshot.target.kind == .volume,
              focusNode.id == snapshot.root.id,
              let availableCapacity,
              availableCapacity > 0 else {
            return SunburstVisualizationInput(
                rootNode: focusNode,
                treeStore: snapshot.treeStore,
                layoutIDComponent: disabledLayoutComponent
            )
        }

        let root = snapshot.root
        let visualRootID = visualRootID(for: root.id)
        let freeSpaceID = freeSpaceNodeID(for: root.id)
        let freeSpaceNode = FileNodeRecord(
            id: freeSpaceID,
            url: root.url,
            name: "Free Space",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: availableCapacity,
            logicalSize: availableCapacity,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let visualRootChildren = FileTreeStore.sortedChildren([root, freeSpaceNode])
        let visualRoot = FileNodeRecord.directory(
            id: visualRootID,
            url: root.url,
            name: root.name,
            children: visualRootChildren,
            lastModified: root.lastModified,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            childrenAreSorted: true
        )

        var nodesByID = snapshot.treeStore.nodesByID
        nodesByID[visualRoot.id] = visualRoot
        nodesByID[freeSpaceNode.id] = freeSpaceNode

        var childIDsByID = snapshot.treeStore.childIDsByID
        childIDsByID[visualRoot.id] = visualRootChildren.map(\.id)

        var parentIDByID = snapshot.treeStore.parentIDByID
        parentIDByID[root.id] = visualRoot.id
        parentIDByID[freeSpaceNode.id] = visualRoot.id

        let treeStore = FileTreeStore(
            rootID: visualRoot.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )

        return SunburstVisualizationInput(
            rootNode: treeStore.root,
            treeStore: treeStore,
            layoutIDComponent: "free-space:\(availableCapacity)"
        )
    }

    nonisolated static func isFreeSpaceNodeID(_ nodeID: String?) -> Bool {
        nodeID?.hasSuffix(freeSpaceSuffix) == true
    }

    private nonisolated static func visualRootID(for rootID: String) -> String {
        rootID + visualRootSuffix
    }

    private nonisolated static func freeSpaceNodeID(for rootID: String) -> String {
        rootID + freeSpaceSuffix
    }
}
