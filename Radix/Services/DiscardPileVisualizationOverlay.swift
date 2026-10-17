import Foundation

nonisolated struct DiscardPileVisualizationPresentation: Sendable {
    let visualizationInput: DiskMapVisualizationInput
    let layoutID: String
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>

    init(
        snapshot: ScanSnapshot,
        focusNode: FileNodeRecord,
        showFreeSpace: Bool,
        availableCapacity: Int64?,
        maxRenderedDepth: Int,
        discardPileRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID> = []
    ) {
        let visualizationInput = DiskMapFreeSpaceVisualization.input(
            snapshot: snapshot,
            focusNode: focusNode,
            showFreeSpace: showFreeSpace,
            availableCapacity: availableCapacity
        )
        self.visualizationInput = visualizationInput
        layoutID = [
            snapshot.id.uuidString,
            focusNode.id,
            visualizationInput.rootNode.id,
            visualizationInput.treeContentID.uuidString,
            String(maxRenderedDepth),
            visualizationInput.layoutIDComponent,
        ].joined(separator: "|")
        self.discardPileRootNodeIDs = discardPileRootNodeIDs
        self.movingToTrashRootNodeIDs = movingToTrashRootNodeIDs
    }
}

nonisolated enum DiscardPileVisualizationOverlayRole: Equatable, Sendable {
    case queuedRoot
    case queuedDescendant
    case containsQueuedItem
    case movingToTrashRoot
    case movingToTrashDescendant
    case containsMovingToTrashItem

    var statusText: String {
        switch self {
        case .queuedRoot, .queuedDescendant:
            String(
                localized: "In Discard Pile",
                comment: "Chart hover status for an item included in the Discard Pile."
            )
        case .containsQueuedItem:
            String(
                localized: "Contains Items in Discard Pile",
                comment: "Chart hover status for a grouped region containing Discard Pile items."
            )
        case .movingToTrashRoot, .movingToTrashDescendant:
            String(
                localized: "Moving to Trash",
                comment: "Chart hover status for an item currently being moved to the Trash."
            )
        case .containsMovingToTrashItem:
            String(
                localized: "Contains Items Moving to Trash",
                comment: "Chart hover status for a grouped region containing items currently being moved to the Trash."
            )
        }
    }
}

/// Presentation-only state for queued and in-flight Trash items. It derives
/// marks from rendered node IDs without rebuilding the scan tree or chart
/// geometry.
nonisolated struct DiscardPileVisualizationOverlay: Equatable, Sendable {
    static let empty = DiscardPileVisualizationOverlay()

    let queuedNodeIDs: Set<FileNodeRecord.ID>
    let queuedRootNodeIDs: Set<FileNodeRecord.ID>
    let containingQueuedNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    let containingMovingToTrashNodeIDs: Set<FileNodeRecord.ID>

    init(
        renderedNodeIDs: Set<FileNodeRecord.ID> = [],
        renderedAggregateContainerNodeIDs: Set<FileNodeRecord.ID> = [],
        queuedRootNodeIDs: Set<FileNodeRecord.ID> = [],
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID> = [],
        treeStore: (any DiskMapTreeReading)? = nil
    ) {
        guard !renderedNodeIDs.isEmpty || !renderedAggregateContainerNodeIDs.isEmpty,
              !queuedRootNodeIDs.isEmpty || !movingToTrashRootNodeIDs.isEmpty,
              let treeStore else {
            queuedNodeIDs = []
            self.queuedRootNodeIDs = []
            containingQueuedNodeIDs = []
            movingToTrashNodeIDs = []
            self.movingToTrashRootNodeIDs = []
            containingMovingToTrashNodeIDs = []
            return
        }

        let memberships = Self.renderedMemberships(
            renderedNodeIDs: renderedNodeIDs,
            queuedRootNodeIDs: queuedRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
            treeStore: treeStore
        )

        self.queuedNodeIDs = memberships.queued
        self.queuedRootNodeIDs = Self.visualRootNodeIDs(
            in: memberships.queued,
            renderedNodeIDs: renderedNodeIDs,
            treeStore: treeStore
        )
        self.containingQueuedNodeIDs = Self.containingNodeIDs(
            for: queuedRootNodeIDs,
            renderedMemberNodeIDs: memberships.queued,
            renderedNodeIDs: renderedNodeIDs,
            renderedAggregateContainerNodeIDs: renderedAggregateContainerNodeIDs,
            treeStore: treeStore
        )
        self.movingToTrashNodeIDs = memberships.movingToTrash
        self.movingToTrashRootNodeIDs = Self.visualRootNodeIDs(
            in: memberships.movingToTrash,
            renderedNodeIDs: renderedNodeIDs,
            treeStore: treeStore
        )
        self.containingMovingToTrashNodeIDs = Self.containingNodeIDs(
            for: movingToTrashRootNodeIDs,
            renderedMemberNodeIDs: memberships.movingToTrash,
            renderedNodeIDs: renderedNodeIDs,
            renderedAggregateContainerNodeIDs: renderedAggregateContainerNodeIDs,
            treeStore: treeStore
        )
    }

    func role(for nodeID: FileNodeRecord.ID?) -> DiscardPileVisualizationOverlayRole? {
        guard let nodeID else { return nil }
        if movingToTrashRootNodeIDs.contains(nodeID) {
            return .movingToTrashRoot
        }
        if movingToTrashNodeIDs.contains(nodeID) {
            return .movingToTrashDescendant
        }
        if queuedRootNodeIDs.contains(nodeID) {
            return .queuedRoot
        }
        if queuedNodeIDs.contains(nodeID) {
            return .queuedDescendant
        }
        if containingMovingToTrashNodeIDs.contains(nodeID) {
            return .containsMovingToTrashItem
        }
        if containingQueuedNodeIDs.contains(nodeID) {
            return .containsQueuedItem
        }
        return nil
    }

    func role(
        for nodeID: FileNodeRecord.ID?,
        aggregateContainerNodeID: FileNodeRecord.ID?
    ) -> DiscardPileVisualizationOverlayRole? {
        role(for: nodeID) ?? role(for: aggregateContainerNodeID)
    }

    func isQueued(_ nodeID: FileNodeRecord.ID?) -> Bool {
        guard let nodeID else { return false }
        return queuedNodeIDs.contains(nodeID)
    }

    func isMovingToTrash(_ nodeID: FileNodeRecord.ID?) -> Bool {
        guard let nodeID else { return false }
        return movingToTrashNodeIDs.contains(nodeID)
    }

    func allowsChartNodeAction(for nodeID: FileNodeRecord.ID?) -> Bool {
        !isQueued(nodeID) && !isMovingToTrash(nodeID)
    }

    private static func renderedMemberships(
        renderedNodeIDs: Set<FileNodeRecord.ID>,
        queuedRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: any DiskMapTreeReading
    ) -> (queued: Set<FileNodeRecord.ID>, movingToTrash: Set<FileNodeRecord.ID>) {
        var queuedNodeIDs = Set<FileNodeRecord.ID>()
        var movingToTrashNodeIDs = Set<FileNodeRecord.ID>()
        queuedNodeIDs.reserveCapacity(min(renderedNodeIDs.count, queuedRootNodeIDs.count * 2))
        movingToTrashNodeIDs.reserveCapacity(
            min(renderedNodeIDs.count, movingToTrashRootNodeIDs.count * 2)
        )

        for renderedNodeID in renderedNodeIDs {
            var candidateID: FileNodeRecord.ID? = renderedNodeID
            while let currentID = candidateID {
                if queuedRootNodeIDs.contains(currentID) {
                    queuedNodeIDs.insert(renderedNodeID)
                }
                if movingToTrashRootNodeIDs.contains(currentID) {
                    movingToTrashNodeIDs.insert(renderedNodeID)
                }
                if (queuedRootNodeIDs.isEmpty || queuedNodeIDs.contains(renderedNodeID))
                    && (movingToTrashRootNodeIDs.isEmpty
                        || movingToTrashNodeIDs.contains(renderedNodeID)) {
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
        }

        return (queuedNodeIDs, movingToTrashNodeIDs)
    }

    private static func visualRootNodeIDs(
        in renderedMemberNodeIDs: Set<FileNodeRecord.ID>,
        renderedNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: any DiskMapTreeReading
    ) -> Set<FileNodeRecord.ID> {
        var visualRootNodeIDs = Set<FileNodeRecord.ID>()
        visualRootNodeIDs.reserveCapacity(renderedMemberNodeIDs.count)
        for memberNodeID in renderedMemberNodeIDs {
            var candidateID = treeStore.parentID(of: memberNodeID)
            var hasRenderedMemberAncestor = false
            while let currentID = candidateID {
                if renderedNodeIDs.contains(currentID) {
                    hasRenderedMemberAncestor = renderedMemberNodeIDs.contains(currentID)
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
            if !hasRenderedMemberAncestor {
                visualRootNodeIDs.insert(memberNodeID)
            }
        }
        return visualRootNodeIDs
    }

    private static func containingNodeIDs(
        for sourceRootNodeIDs: Set<FileNodeRecord.ID>,
        renderedMemberNodeIDs: Set<FileNodeRecord.ID>,
        renderedNodeIDs: Set<FileNodeRecord.ID>,
        renderedAggregateContainerNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: any DiskMapTreeReading
    ) -> Set<FileNodeRecord.ID> {
        var containingNodeIDs = Set<FileNodeRecord.ID>()
        containingNodeIDs.reserveCapacity(sourceRootNodeIDs.count)
        for sourceRootNodeID in sourceRootNodeIDs {
            guard treeStore.node(id: sourceRootNodeID) != nil,
                  !renderedNodeIDs.contains(sourceRootNodeID) else {
                continue
            }

            var candidateID = treeStore.parentID(of: sourceRootNodeID)
            while let currentID = candidateID {
                if renderedNodeIDs.contains(currentID)
                    || renderedAggregateContainerNodeIDs.contains(currentID) {
                    if !renderedMemberNodeIDs.contains(currentID) {
                        containingNodeIDs.insert(currentID)
                    }
                    break
                }
                candidateID = treeStore.parentID(of: currentID)
            }
        }
        return containingNodeIDs
    }
}

nonisolated struct DiscardPileVisualizationOverlayCache {
    private struct Key: Equatable {
        let treeContentID: UUID
        let renderedLayoutVersion: Int
        let queuedRootNodeIDs: Set<FileNodeRecord.ID>
        let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    }

    private var cached: (key: Key, overlay: DiscardPileVisualizationOverlay)?

    mutating func overlay(
        renderedLayoutVersion: Int,
        queuedRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: DiskMapTreeStore,
        renderedNodeIDs: () -> Set<FileNodeRecord.ID>,
        renderedAggregateContainerNodeIDs: () -> Set<FileNodeRecord.ID> = { [] }
    ) -> DiscardPileVisualizationOverlay {
        let key = Key(
            treeContentID: treeStore.contentID,
            renderedLayoutVersion: renderedLayoutVersion,
            queuedRootNodeIDs: queuedRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs
        )
        if let cached, cached.key == key {
            return cached.overlay
        }

        let overlay = DiscardPileVisualizationOverlay(
            renderedNodeIDs: renderedNodeIDs(),
            renderedAggregateContainerNodeIDs: renderedAggregateContainerNodeIDs(),
            queuedRootNodeIDs: queuedRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
            treeStore: treeStore
        )
        cached = (key, overlay)
        return overlay
    }
}
