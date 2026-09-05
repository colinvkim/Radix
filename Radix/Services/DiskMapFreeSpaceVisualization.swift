//
//  DiskMapFreeSpaceVisualization.swift
//  Radix
//

import Foundation

nonisolated protocol DiskMapTreeReading: Sendable {
    var rootID: String { get }

    func node(id: String?) -> FileNodeRecord?
    func parentID(of id: String?) -> String?
    func children(of id: String?) -> [FileNodeRecord]
    func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord]
    func path(to id: String?) -> [FileNodeRecord]
}

extension FileTreeStore: DiskMapTreeReading {}

struct DiskMapVisualizationInput: Sendable {
    let rootNode: FileNodeRecord
    let treeStore: DiskMapTreeStore
    let treeContentID: UUID
    let layoutIDComponent: String
}

/// A read-only visualization facade over the scan tree. Volume-capacity nodes
/// are overlaid here instead of rebuilding every node and edge in a large scan.
nonisolated struct DiskMapTreeStore: DiskMapTreeReading {
    private struct VolumeCapacityOverlay: Sendable {
        let visualRootID: String
        let freeSpaceNode: FileNodeRecord
    }

    private let base: FileTreeStore
    private let volumeCapacityOverlay: VolumeCapacityOverlay?

    init(_ base: FileTreeStore) {
        self.base = base
        volumeCapacityOverlay = nil
    }

    fileprivate init(
        base: FileTreeStore,
        visualRootID: String,
        freeSpaceNode: FileNodeRecord
    ) {
        self.base = base
        volumeCapacityOverlay = VolumeCapacityOverlay(
            visualRootID: visualRootID,
            freeSpaceNode: freeSpaceNode
        )
    }

    var contentID: UUID { base.contentID }

    var rootID: String {
        volumeCapacityOverlay?.visualRootID ?? base.rootID
    }

    var root: FileNodeRecord {
        guard let volumeCapacityOverlay else { return base.root }
        return visualRoot(
            id: volumeCapacityOverlay.visualRootID,
            freeSpaceNode: volumeCapacityOverlay.freeSpaceNode
        )
    }

    func node(id: String?) -> FileNodeRecord? {
        guard let id else { return nil }
        if id == volumeCapacityOverlay?.visualRootID {
            return root
        }
        if id == volumeCapacityOverlay?.freeSpaceNode.id {
            return volumeCapacityOverlay?.freeSpaceNode
        }
        return base.node(id: id)
    }

    func parentID(of id: String?) -> String? {
        guard let id else { return nil }
        if id == volumeCapacityOverlay?.visualRootID {
            return nil
        }
        if let volumeCapacityOverlay,
           id == base.rootID || id == volumeCapacityOverlay.freeSpaceNode.id {
            return volumeCapacityOverlay.visualRootID
        }
        return base.parentID(of: id)
    }

    func parent(of id: String?) -> FileNodeRecord? {
        node(id: parentID(of: id))
    }

    func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        let resolvedID = id ?? rootID
        guard let volumeCapacityOverlay,
              resolvedID == volumeCapacityOverlay.visualRootID else {
            return try base.children(of: resolvedID, cancellationCheck: cancellationCheck)
        }
        try cancellationCheck()
        return FileTreeStore.sortedChildren([base.root, volumeCapacityOverlay.freeSpaceNode])
    }

    func path(to id: String?) -> [FileNodeRecord] {
        guard let id,
              let volumeCapacityOverlay else {
            return base.path(to: id)
        }
        if id == volumeCapacityOverlay.visualRootID {
            return [root]
        }
        if id == volumeCapacityOverlay.freeSpaceNode.id {
            return [root, volumeCapacityOverlay.freeSpaceNode]
        }
        guard base.node(id: id) != nil else { return [root] }
        return [root] + base.path(to: id)
    }

    func removingSubtrees(
        rootedAt nodeIDs: [String],
        cancellationCheck: () throws -> Void
    ) throws -> DiskMapTreeStore {
        let filteredBase = try base.removingSubtrees(
            rootedAt: nodeIDs,
            cancellationCheck: cancellationCheck
        )
        guard let volumeCapacityOverlay else {
            return DiskMapTreeStore(filteredBase)
        }
        return DiskMapTreeStore(
            base: filteredBase,
            visualRootID: volumeCapacityOverlay.visualRootID,
            freeSpaceNode: volumeCapacityOverlay.freeSpaceNode
        )
    }

    private func visualRoot(id: String, freeSpaceNode: FileNodeRecord) -> FileNodeRecord {
        let baseRoot = base.root
        return FileNodeRecord.directory(
            id: id,
            url: baseRoot.url,
            name: baseRoot.name,
            children: [baseRoot, freeSpaceNode],
            lastModified: baseRoot.lastModified,
            isPackage: baseRoot.isPackage,
            isAccessible: baseRoot.isSelfAccessible
        )
    }
}

enum DiskMapFreeSpaceVisualization {
    private nonisolated static let visualRootSuffix = "\u{0}radix-volume-capacity"
    private nonisolated static let freeSpaceSuffix = "\u{0}radix-free-space"
    private nonisolated static let disabledLayoutComponent = "free-space:0"

    nonisolated static func input(
        snapshot: ScanSnapshot,
        focusNode: FileNodeRecord,
        showFreeSpace: Bool,
        availableCapacity: Int64?
    ) -> DiskMapVisualizationInput {
        guard showFreeSpace,
              snapshot.target.kind == .volume,
              focusNode.id == snapshot.root.id,
              let availableCapacity,
              availableCapacity > 0 else {
            return DiskMapVisualizationInput(
                rootNode: focusNode,
                treeStore: DiskMapTreeStore(snapshot.treeStore),
                treeContentID: snapshot.treeStore.contentID,
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
        let treeStore = DiskMapTreeStore(
            base: snapshot.treeStore,
            visualRootID: visualRootID,
            freeSpaceNode: freeSpaceNode
        )

        return DiskMapVisualizationInput(
            rootNode: treeStore.root,
            treeStore: treeStore,
            treeContentID: snapshot.treeStore.contentID,
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
