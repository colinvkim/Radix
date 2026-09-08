//
//  TreemapGeometry.swift
//  Radix
//

import CoreGraphics
import Foundation

nonisolated struct TreemapSegment: Identifiable, Hashable, Sendable {
    let id: String
    let nodeID: String?
    let containerNodeID: String
    let label: String
    /// A unit-space rectangle. The renderer scales it to the current chart size.
    let rect: CGRect
    let depth: Int
    let colorToken: SunburstColorToken
    let totalSize: Int64
    let isAggregate: Bool
    let groupedItemCount: Int?
    let isDirectory: Bool
    let showsContainerHeader: Bool
}

nonisolated enum TreemapLayout {
    fileprivate nonisolated static let containerInset: CGFloat = 2
    fileprivate nonisolated static let containerHeaderHeight: CGFloat = 18
    private nonisolated static let minimumContainerWidth: CGFloat = 52
    private nonisolated static let minimumContainerHeight: CGFloat = 46

    typealias CancellationCheck = () throws -> Void

    nonisolated static func segments(
        in treeStore: some DiskMapTreeReading,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        minimumTileArea: CGFloat = 120
    ) -> [TreemapSegment] {
        (try? segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            size: size,
            minimumTileArea: minimumTileArea,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func segments(
        in treeStore: some DiskMapTreeReading,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        minimumTileArea: CGFloat = 120,
        cancellationCheck: CancellationCheck
    ) throws -> [TreemapSegment] {
        guard depthLimit > 0, size.width > 0, size.height > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let rootBounds = CGRect(origin: .zero, size: size)
        let rootEntries = try groupedChildren(
            visibleChildren,
            parentID: root.id,
            bounds: rootBounds,
            minimumTileArea: max(minimumTileArea, 1),
            cancellationCheck: cancellationCheck
        )
        let colorBranchContext = try DiskMapColorBranchContext(
            in: treeStore,
            layoutRootID: root.id,
            layoutRootChildren: rootChildren,
            visibleNodeIDs: rootEntries.lazy.compactMap(\.nodeID),
            cancellationCheck: cancellationCheck
        )

        var result: [TreemapSegment] = []
        try appendSegments(
            in: treeStore,
            entries: rootEntries,
            parentID: root.id,
            bounds: rootBounds,
            rootSize: size,
            depth: 0,
            depthLimit: depthLimit,
            branchContext: nil,
            colorBranchContext: colorBranchContext,
            minimumTileArea: max(minimumTileArea, 1),
            cancellationCheck: cancellationCheck,
            into: &result
        )
        return result
    }

    private nonisolated static func appendSegments(
        in treeStore: some DiskMapTreeReading,
        entries: [Entry],
        parentID: String,
        bounds: CGRect,
        rootSize: CGSize,
        depth: Int,
        depthLimit: Int,
        branchContext: DiskMapColorBranch?,
        colorBranchContext: DiskMapColorBranchContext,
        minimumTileArea: CGFloat,
        cancellationCheck: CancellationCheck,
        into segments: inout [TreemapSegment]
    ) throws {
        guard depth < depthLimit, bounds.width > 0, bounds.height > 0 else { return }
        try cancellationCheck()
        let tiles = try squarifiedTiles(
            for: entries,
            in: bounds,
            cancellationCheck: cancellationCheck
        )
        let siblingIndexes = try colorableIndexes(for: entries, cancellationCheck: cancellationCheck)
        let siblingCount = max(siblingIndexes.count, 1)

        for tile in tiles {
            try cancellationCheck()
            let entry = tile.entry
            let siblingIndex = siblingIndexes[entry.id] ?? 0
            let branch = branchContext ?? colorBranchContext.branch(forNodeID: entry.nodeID)
                ?? DiskMapColorBranch(id: entry.colorID, index: siblingIndex, count: siblingCount)

            let childBounds = childContentBounds(in: tile.rect)
            let childNodes: [FileNodeRecord]
            if childBounds != nil,
               let node = entry.node,
               node.isDirectory,
               depth + 1 < depthLimit {
                childNodes = try treeStore.children(of: node.id, cancellationCheck: cancellationCheck)
            } else {
                childNodes = []
            }

            let showsContainerHeader = !childNodes.isEmpty
            let colorToken = SunburstColorToken(
                branchID: branch.id,
                localID: entry.colorID,
                branchIndex: branch.index,
                branchCount: branch.count,
                siblingIndex: siblingIndex,
                siblingCount: siblingCount,
                depth: depth,
                role: colorRole(for: entry)
            )
            segments.append(TreemapSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                containerNodeID: parentID,
                label: entry.label,
                rect: normalized(tile.rect, in: rootSize),
                depth: depth,
                colorToken: colorToken,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate,
                groupedItemCount: entry.groupedItemCount,
                isDirectory: entry.node?.isDirectory == true,
                showsContainerHeader: showsContainerHeader
            ))

            if let node = entry.node,
               let childBounds,
               !childNodes.isEmpty {
                let childEntries = try groupedChildren(
                    childNodes,
                    parentID: node.id,
                    bounds: childBounds,
                    minimumTileArea: minimumTileArea,
                    cancellationCheck: cancellationCheck
                )
                try appendSegments(
                    in: treeStore,
                    entries: childEntries,
                    parentID: node.id,
                    bounds: childBounds,
                    rootSize: rootSize,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    branchContext: branch,
                    colorBranchContext: colorBranchContext,
                    minimumTileArea: minimumTileArea,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }
        }
    }

    private nonisolated static func groupedChildren(
        _ children: [FileNodeRecord],
        parentID: String,
        bounds: CGRect,
        minimumTileArea: CGFloat,
        cancellationCheck: CancellationCheck
    ) throws -> [Entry] {
        guard children.count > 1 else {
            return children.map(Entry.init(node:))
        }

        var totalWeight = 0.0
        for child in children {
            try cancellationCheck()
            totalWeight += Double(max(child.allocatedSize, 1))
        }
        let availableArea = max(bounds.width * bounds.height, 1)
        var visible: [Entry] = []
        var groupedCount = 0
        var onlyGroupedChild: FileNodeRecord?
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let layoutSize = max(child.allocatedSize, 1)
            let projectedArea = availableArea * CGFloat(Double(layoutSize) / max(totalWeight, 1))
            if projectedArea < minimumTileArea {
                groupedCount += 1
                if groupedCount == 1 {
                    onlyGroupedChild = child
                } else {
                    onlyGroupedChild = nil
                }
                groupedSize = ScanIntegerMath.addingClamped(
                    groupedSize,
                    max(child.allocatedSize, 0)
                )
            } else {
                visible.append(Entry(node: child))
            }
        }

        if groupedCount > 1 {
            visible.append(Entry(
                id: "treemap-aggregate-\(parentID)",
                nodeID: nil,
                label: String(localized: "Smaller Items", comment: "Disk map group for items too small to display individually."),
                totalSize: groupedSize,
                isAggregate: true,
                groupedItemCount: groupedCount,
                colorID: "treemap-aggregate-\(parentID)",
                node: nil
            ))
        } else if let onlyGroupedChild {
            visible.append(Entry(node: onlyGroupedChild))
        }

        return try CancellableSort.sorted(&visible, cancellationCheck: cancellationCheck) {
            if $0.totalSize == $1.totalSize {
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
            return $0.totalSize > $1.totalSize
        }
    }

    private nonisolated static func squarifiedTiles(
        for entries: [Entry],
        in bounds: CGRect,
        cancellationCheck: CancellationCheck
    ) throws -> [Tile] {
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        var totalWeight = 0.0
        for entry in entries {
            try cancellationCheck()
            totalWeight += Double(max(entry.totalSize, 1))
        }
        let scale = Double(bounds.width * bounds.height) / max(totalWeight, 1)
        var nextEntryIndex = 0
        var remainingBounds = bounds
        var row: [WeightedEntry] = []
        var rowArea = CGFloat(0)
        var rowMinimumArea = CGFloat.greatestFiniteMagnitude
        var rowMaximumArea = CGFloat(0)
        var result: [Tile] = []

        while nextEntryIndex < entries.count {
            try cancellationCheck()
            let entry = entries[nextEntryIndex]
            let next = WeightedEntry(entry: entry, area: CGFloat(Double(max(entry.totalSize, 1)) * scale))
            let shortSide = min(remainingBounds.width, remainingBounds.height)
            let candidateArea = rowArea + next.area
            let candidateMinimumArea = min(rowMinimumArea, next.area)
            let candidateMaximumArea = max(rowMaximumArea, next.area)
            if row.isEmpty || worstAspectRatio(
                sum: candidateArea,
                minimum: candidateMinimumArea,
                maximum: candidateMaximumArea,
                shortSide: shortSide
            ) <= worstAspectRatio(
                sum: rowArea,
                minimum: rowMinimumArea,
                maximum: rowMaximumArea,
                shortSide: shortSide
            ) {
                row.append(next)
                rowArea = candidateArea
                rowMinimumArea = candidateMinimumArea
                rowMaximumArea = candidateMaximumArea
                nextEntryIndex += 1
            } else {
                remainingBounds = try layoutRow(
                    row,
                    area: rowArea,
                    in: remainingBounds,
                    cancellationCheck: cancellationCheck,
                    into: &result
                )
                row.removeAll(keepingCapacity: true)
                rowArea = 0
                rowMinimumArea = .greatestFiniteMagnitude
                rowMaximumArea = 0
            }
        }

        if !row.isEmpty {
            _ = try layoutRow(row, area: rowArea, in: remainingBounds, cancellationCheck: cancellationCheck, into: &result)
        }

        return result
    }

    private nonisolated static func worstAspectRatio(
        sum: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        shortSide: CGFloat
    ) -> CGFloat {
        guard shortSide > 0, sum > 0, minimum > 0 else { return .infinity }

        let sumSquared = sum * sum
        let sideSquared = shortSide * shortSide
        return max(
            (sideSquared * maximum) / sumSquared,
            sumSquared / (sideSquared * minimum)
        )
    }

    @discardableResult
    private nonisolated static func layoutRow(
        _ row: [WeightedEntry],
        area rowArea: CGFloat,
        in bounds: CGRect,
        cancellationCheck: CancellationCheck,
        into result: inout [Tile]
    ) throws -> CGRect {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return bounds }

        if bounds.width >= bounds.height {
            let columnWidth = min(rowArea / bounds.height, bounds.width)
            var cursorY = bounds.minY
            for (index, weightedEntry) in row.enumerated() {
                try cancellationCheck()
                let height = index == row.count - 1
                    ? max(bounds.maxY - cursorY, 0)
                    : min(weightedEntry.area / max(columnWidth, .leastNonzeroMagnitude), bounds.maxY - cursorY)
                result.append(Tile(
                    entry: weightedEntry.entry,
                    rect: CGRect(x: bounds.minX, y: cursorY, width: columnWidth, height: height)
                ))
                cursorY += height
            }
            return CGRect(
                x: bounds.minX + columnWidth,
                y: bounds.minY,
                width: max(bounds.width - columnWidth, 0),
                height: bounds.height
            )
        }

        let rowHeight = min(rowArea / bounds.width, bounds.height)
        var cursorX = bounds.minX
        for (index, weightedEntry) in row.enumerated() {
            try cancellationCheck()
            let width = index == row.count - 1
                ? max(bounds.maxX - cursorX, 0)
                : min(weightedEntry.area / max(rowHeight, .leastNonzeroMagnitude), bounds.maxX - cursorX)
            result.append(Tile(
                entry: weightedEntry.entry,
                rect: CGRect(x: cursorX, y: bounds.minY, width: width, height: rowHeight)
            ))
            cursorX += width
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + rowHeight,
            width: bounds.width,
            height: max(bounds.height - rowHeight, 0)
        )
    }

    private nonisolated static func childContentBounds(in rect: CGRect) -> CGRect? {
        guard rect.width >= minimumContainerWidth,
              rect.height >= minimumContainerHeight else {
            return nil
        }

        var content = rect.insetBy(dx: containerInset, dy: containerInset)
        content.origin.y += containerHeaderHeight
        content.size.height -= containerHeaderHeight
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }

    private nonisolated static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    private nonisolated static func colorRole(for entry: Entry) -> SunburstColorRole {
        if entry.isAggregate { return .aggregate }
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(entry.nodeID) { return .freeSpace }
        return .normal
    }

    private nonisolated static func colorableIndexes(
        for entries: [Entry],
        cancellationCheck: CancellationCheck
    ) throws -> [String: Int] {
        var indexes: [String: Int] = [:]
        for entry in entries where !entry.isAggregate {
            try cancellationCheck()
            indexes[entry.id] = indexes.count
        }
        return indexes
    }

    private nonisolated struct Entry {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let groupedItemCount: Int?
        let colorID: String
        let node: FileNodeRecord?

        nonisolated init(node: FileNodeRecord) {
            id = node.id
            nodeID = node.id
            label = node.displayName
            totalSize = max(node.allocatedSize, 0)
            isAggregate = false
            groupedItemCount = nil
            colorID = node.id
            self.node = node
        }

        nonisolated init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            isAggregate: Bool,
            groupedItemCount: Int?,
            colorID: String,
            node: FileNodeRecord?
        ) {
            self.id = id
            self.nodeID = nodeID
            self.label = label
            self.totalSize = max(totalSize, 0)
            self.isAggregate = isAggregate
            self.groupedItemCount = groupedItemCount
            self.colorID = colorID
            self.node = node
        }
    }

    private nonisolated struct WeightedEntry {
        let entry: Entry
        let area: CGFloat
    }

    private nonisolated struct Tile {
        let entry: Entry
        let rect: CGRect
    }
}

nonisolated enum TreemapRenderer {
    private nonisolated static let displayInset: CGFloat = 0.75

    nonisolated static func rect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        rect(
            for: segment,
            in: CGRect(origin: .zero, size: size)
        )
    }

    nonisolated static func rect(
        for segment: TreemapSegment,
        in contentFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: contentFrame.minX + (segment.rect.minX * contentFrame.width),
            y: contentFrame.minY + (segment.rect.minY * contentFrame.height),
            width: segment.rect.width * contentFrame.width,
            height: segment.rect.height * contentFrame.height
        )
    }

    nonisolated static func displayRect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        displayRect(
            for: segment,
            in: CGRect(origin: .zero, size: size)
        )
    }

    nonisolated static func displayRect(
        for segment: TreemapSegment,
        in contentFrame: CGRect
    ) -> CGRect {
        displayRect(for: rect(for: segment, in: contentFrame))
    }

    nonisolated static func navigationRect(
        for segment: TreemapSegment,
        in size: CGSize
    ) -> CGRect {
        navigationRect(
            for: segment,
            in: CGRect(origin: .zero, size: size)
        )
    }

    nonisolated static func navigationRect(
        for segment: TreemapSegment,
        in contentFrame: CGRect
    ) -> CGRect {
        let segmentRect = rect(for: segment, in: contentFrame)
        guard segment.showsContainerHeader else {
            return displayRect(for: segmentRect)
        }

        let headerHeight = min(
            TreemapLayout.containerInset + TreemapLayout.containerHeaderHeight,
            segmentRect.height
        )
        return displayRect(for: CGRect(
            x: segmentRect.minX,
            y: segmentRect.minY,
            width: segmentRect.width,
            height: headerHeight
        ))
    }

    private nonisolated static func displayRect(for rect: CGRect) -> CGRect {
        let inset = min(
            displayInset,
            min(rect.width, rect.height) * 0.12
        )
        return rect.insetBy(dx: inset, dy: inset)
    }

    nonisolated static func strokeRect(
        for segment: TreemapSegment,
        in size: CGSize,
        lineWidth: CGFloat
    ) -> CGRect? {
        strokeRect(
            for: segment,
            in: CGRect(origin: .zero, size: size),
            lineWidth: lineWidth
        )
    }

    nonisolated static func strokeRect(
        for segment: TreemapSegment,
        in contentFrame: CGRect,
        lineWidth: CGFloat
    ) -> CGRect? {
        let displayRect = displayRect(for: segment, in: contentFrame)
        let effectiveLineWidth = max(lineWidth, 0)
        guard min(displayRect.width, displayRect.height) >= effectiveLineWidth else {
            return nil
        }

        return displayRect.insetBy(
            dx: effectiveLineWidth / 2,
            dy: effectiveLineWidth / 2
        )
    }
}

nonisolated struct TreemapHitTestIndex: Sendable {
    private nonisolated static let columnCount = 32
    private nonisolated static let rowCount = 24

    private let segments: [TreemapSegment]
    private let segmentIndexesByBucket: [[Int]]

    nonisolated init(segments: [TreemapSegment]) {
        self.segments = segments
        var buckets = Array(
            repeating: [Int](),
            count: Self.columnCount * Self.rowCount
        )

        for (segmentIndex, segment) in segments.enumerated() {
            let columns = Self.bucketRange(
                minimum: segment.rect.minX,
                maximum: segment.rect.maxX,
                count: Self.columnCount
            )
            let rows = Self.bucketRange(
                minimum: segment.rect.minY,
                maximum: segment.rect.maxY,
                count: Self.rowCount
            )
            for row in rows {
                for column in columns {
                    buckets[(row * Self.columnCount) + column].append(segmentIndex)
                }
            }
        }

        for bucketIndex in buckets.indices {
            buckets[bucketIndex].sort { lhs, rhs in
                let left = segments[lhs]
                let right = segments[rhs]
                if left.depth == right.depth { return lhs > rhs }
                return left.depth > right.depth
            }
        }
        segmentIndexesByBucket = buckets
    }

    nonisolated func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        guard size.width > 0, size.height > 0 else { return nil }
        let unitPoint = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard unitPoint.x >= 0, unitPoint.x <= 1,
              unitPoint.y >= 0, unitPoint.y <= 1 else {
            return nil
        }

        let column = min(Int(unitPoint.x * CGFloat(Self.columnCount)), Self.columnCount - 1)
        let row = min(Int(unitPoint.y * CGFloat(Self.rowCount)), Self.rowCount - 1)
        let candidates = segmentIndexesByBucket[(row * Self.columnCount) + column]

        for index in candidates {
            let segment = segments[index]
            guard segment.rect.containsInclusively(unitPoint) else { continue }
            if TreemapRenderer.displayRect(for: segment, in: size).contains(point) {
                return segment
            }
        }
        return nil
    }

    private nonisolated static func bucketRange(
        minimum: CGFloat,
        maximum: CGFloat,
        count: Int
    ) -> ClosedRange<Int> {
        let lower = min(max(Int(floor(minimum * CGFloat(count))), 0), count - 1)
        let adjustedMaximum = max(maximum - CGFloat.ulpOfOne, minimum)
        let upper = min(max(Int(floor(adjustedMaximum * CGFloat(count))), 0), count - 1)
        return lower...max(lower, upper)
    }
}

private extension CGRect {
    nonisolated func containsInclusively(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
