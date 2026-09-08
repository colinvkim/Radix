import Foundation

nonisolated struct TreemapTooltipContent: Equatable, Sendable {
    let systemImageName: String
    let title: String
    let sizeAndSignificance: String
    let location: String
    let metadata: String
    let status: String?

    var accessibilityDescription: String {
        [title, status, sizeAndSignificance, location, metadata]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    static func content(
        for segment: TreemapSegment,
        rootNode: FileNodeRecord,
        treeStore: some DiskMapTreeReading,
        discardPileRole: DiscardPileVisualizationOverlayRole? = nil
    ) -> TreemapTooltipContent {
        guard let nodeID = segment.nodeID,
              let node = treeStore.node(id: nodeID) else {
            return aggregateContent(
                for: segment,
                rootNode: rootNode,
                treeStore: treeStore,
                discardPileRole: discardPileRole
            )
        }

        let metadata: String
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            metadata = String(localized: "APFS available capacity", comment: "Tooltip metadata describing free space on an APFS volume.")
        } else if node.isDirectory {
            metadata = fileCountDescription(node.descendantFileCount)
        } else if let lastModified = node.lastModified {
            metadata = String(localized: "Modified \(RadixFormatters.date(lastModified))", comment: "Tooltip metadata showing when a file was modified.")
        } else {
            metadata = String(localized: "Modification date unavailable", comment: "Tooltip metadata shown when a file's modification date is unavailable.")
        }

        return TreemapTooltipContent(
            systemImageName: node.systemImageName,
            title: node.displayName,
            sizeAndSignificance: sizeAndSignificance(
                size: node.allocatedSize,
                rootNode: rootNode
            ),
            location: pathDescription(
                to: treeStore.parentID(of: node.id) ?? rootNode.id,
                relativeTo: rootNode,
                treeStore: treeStore
            ),
            metadata: metadata,
            status: discardPileRole?.statusText
        )
    }

    private static func aggregateContent(
        for segment: TreemapSegment,
        rootNode: FileNodeRecord,
        treeStore: some DiskMapTreeReading,
        discardPileRole: DiscardPileVisualizationOverlayRole?
    ) -> TreemapTooltipContent {
        let itemCount = segment.groupedItemCount ?? 0
        return TreemapTooltipContent(
            systemImageName: "square.grid.3x3.fill",
            title: segment.label,
            sizeAndSignificance: sizeAndSignificance(
                size: segment.totalSize,
                rootNode: rootNode
            ),
            location: pathDescription(
                to: segment.containerNodeID,
                relativeTo: rootNode,
                treeStore: treeStore
            ),
            metadata: itemCount == 1
                ? String(localized: "1 grouped item", comment: "Tooltip metadata for one item represented by an aggregate segment.")
                : String(localized: "\(itemCount.formatted(.number)) grouped items", comment: "Tooltip metadata for multiple items represented by an aggregate segment."),
            status: discardPileRole?.statusText
        )
    }

    private static func sizeAndSignificance(
        size: Int64,
        rootNode: FileNodeRecord
    ) -> String {
        let formattedSize = RadixFormatters.size(size)
        guard let percentage = RadixFormatters.percentage(
            part: size,
            total: rootNode.allocatedSize
        ) else {
            return formattedSize
        }
        return String(localized: "\(formattedSize) · \(percentage) of \(rootNode.name)", comment: "Tooltip text showing an item's size and percentage of its parent.")
    }

    private static func pathDescription(
        to nodeID: String,
        relativeTo rootNode: FileNodeRecord,
        treeStore: some DiskMapTreeReading
    ) -> String {
        let path = treeStore.path(to: nodeID)
        let relativePath: ArraySlice<FileNodeRecord>
        if let rootIndex = path.firstIndex(where: { $0.id == rootNode.id }) {
            relativePath = path[rootIndex...]
        } else {
            relativePath = path[...]
        }

        let names = relativePath.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? rootNode.name : names.joined(separator: " › ")
    }

    private static func fileCountDescription(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 file", comment: "Tooltip metadata for a directory containing one file.")
            : String(localized: "\(count.formatted(.number)) files", comment: "Tooltip metadata for a directory containing multiple files.")
    }
}
