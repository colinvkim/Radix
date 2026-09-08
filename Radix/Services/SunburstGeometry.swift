//
//  SunburstGeometry.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

nonisolated struct SunburstSegment: Identifiable, Hashable, Sendable {
    let id: String
    let nodeID: String?
    let containerNodeID: String
    let label: String
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let depth: Int
    let colorToken: SunburstColorToken
    let totalSize: Int64
    let isAggregate: Bool
}

nonisolated enum SunburstLayout {
    nonisolated static let centerRadius: CGFloat = 0.22

    typealias CancellationCheck = () throws -> Void

    nonisolated static func segments(
        in treeStore: some DiskMapTreeReading,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90
    ) -> [SunburstSegment] {
        (try? segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            minimumAngle: minimumAngle,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func segments(
        in treeStore: some DiskMapTreeReading,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90,
        cancellationCheck: CancellationCheck
    ) throws -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let ringStart = centerRadius
        let ringWidth = (0.98 - ringStart) / CGFloat(max(depthLimit, 1))
        let denominator = max(Double(root.allocatedSize), Double(visibleChildren.count))

        var result: [SunburstSegment] = []
        try appendSegments(
            in: treeStore,
            children: visibleChildren,
            parentID: root.id,
            parentDenominator: denominator,
            startAngle: 0,
            endAngle: .pi * 2,
            depth: 0,
            depthLimit: depthLimit,
            ringStart: ringStart,
            ringWidth: ringWidth,
            branchContext: nil,
            colorBranchContext: nil,
            minimumAngle: minimumAngle,
            cancellationCheck: cancellationCheck,
            into: &result
        )
        return result
    }

    private nonisolated static func appendSegments(
        in treeStore: some DiskMapTreeReading,
        children: [FileNodeRecord],
        parentID: FileNodeRecord.ID,
        parentDenominator: Double,
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: CGFloat,
        ringWidth: CGFloat,
        branchContext: DiskMapColorBranch?,
        colorBranchContext: DiskMapColorBranchContext?,
        minimumAngle: Double,
        cancellationCheck: CancellationCheck,
        into segments: inout [SunburstSegment]
    ) throws {
        guard depth < depthLimit else { return }

        try cancellationCheck()
        var effectiveChildTotal = 0.0
        for start in stride(from: 0, to: children.count, by: 256) {
            try cancellationCheck()
            let end = min(start + 256, children.count)
            effectiveChildTotal = children[start..<end].reduce(effectiveChildTotal) { total, child in
                total + Double(max(child.allocatedSize, 1))
            }
        }
        let safeDenominator = max(parentDenominator, effectiveChildTotal)
        let totalAngle = endAngle - startAngle
        let grouped = try groupedChildren(
            children,
            denominator: safeDenominator,
            totalAngle: totalAngle,
            minimumAngle: minimumAngle,
            cancellationCheck: cancellationCheck
        )

        let colorBranchContext = try colorBranchContext ?? DiskMapColorBranchContext(
            in: treeStore,
            layoutRootID: parentID,
            layoutRootChildren: children,
            visibleNodeIDs: grouped.lazy.compactMap(\.nodeID),
            cancellationCheck: cancellationCheck
        )
        let siblingIndexes = try colorableIndexes(for: grouped, cancellationCheck: cancellationCheck)
        let siblingCount = max(siblingIndexes.count, 1)
        var cursor = startAngle
        for entry in grouped {
            try cancellationCheck()
            let proportion = Double(entry.totalSize) / safeDenominator
            let segmentEnd = cursor + (totalAngle * proportion)
            let siblingIndex = siblingIndexes[entry.id] ?? 0
            let branch = branchContext ?? colorBranchContext.branch(forNodeID: entry.nodeID)
                ?? DiskMapColorBranch(id: entry.colorID, index: siblingIndex, count: siblingCount)
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
            let segment = SunburstSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                containerNodeID: parentID,
                label: entry.label,
                startAngle: .radians(cursor),
                endAngle: .radians(segmentEnd),
                innerRadius: ringStart + CGFloat(depth) * ringWidth,
                outerRadius: ringStart + CGFloat(depth + 1) * ringWidth - 0.015,
                depth: depth,
                colorToken: colorToken,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate
            )
            segments.append(segment)

            if let node = entry.node,
               depth + 1 < depthLimit,
               node.isDirectory,
               node.allocatedSize > 0 {
                let childNodes = try treeStore.children(of: node.id, cancellationCheck: cancellationCheck)
                guard !childNodes.isEmpty else {
                    cursor = segmentEnd
                    continue
                }

                try appendSegments(
                    in: treeStore,
                    children: childNodes,
                    parentID: node.id,
                    parentDenominator: Double(node.allocatedSize),
                    startAngle: cursor,
                    endAngle: segmentEnd,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    ringStart: ringStart,
                    ringWidth: ringWidth,
                    branchContext: branch,
                    colorBranchContext: colorBranchContext,
                    minimumAngle: minimumAngle,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }

            cursor = segmentEnd
        }
    }

    private nonisolated static func groupedChildren(
        _ children: [FileNodeRecord],
        denominator: Double,
        totalAngle: Double,
        minimumAngle: Double,
        cancellationCheck: CancellationCheck
    ) throws -> [GroupEntry] {
        guard children.count > 1 else {
            return children.map {
                GroupEntry(
                    id: $0.id,
                    nodeID: $0.id,
                    label: $0.displayName,
                    totalSize: max($0.allocatedSize, 1),
                    isAggregate: false,
                    colorID: $0.id,
                    node: $0
                )
            }
        }

        var visible: [GroupEntry] = []
        var groupedCount = 0
        var onlyGroupedChild: FileNodeRecord?
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let size = max(child.allocatedSize, 1)
            let angle = totalAngle * (Double(size) / max(denominator, 1))
            if angle < minimumAngle {
                groupedCount += 1
                if groupedCount == 1 {
                    onlyGroupedChild = child
                } else {
                    onlyGroupedChild = nil
                }
                groupedSize = ScanIntegerMath.addingClamped(groupedSize, size)
            } else {
                visible.append(
                    GroupEntry(
                        id: child.id,
                        nodeID: child.id,
                        label: child.displayName,
                        totalSize: size,
                        isAggregate: false,
                        colorID: child.id,
                        node: child
                    )
                )
            }
        }

        if groupedCount > 1 {
            visible.append(
                GroupEntry(
                    id: "aggregate-\(children.first?.id ?? UUID().uuidString)",
                    nodeID: nil,
                    label: String(localized: "Smaller Items", comment: "Disk map group for items too small to display individually."),
                    totalSize: groupedSize,
                    isAggregate: true,
                    colorID: "aggregate-\(children.first?.id ?? UUID().uuidString)",
                    node: nil
                )
            )
        } else if let onlyGroupedChild {
            visible.append(
                GroupEntry(
                    id: onlyGroupedChild.id,
                    nodeID: onlyGroupedChild.id,
                    label: onlyGroupedChild.displayName,
                    totalSize: max(onlyGroupedChild.allocatedSize, 1),
                    isAggregate: false,
                    colorID: onlyGroupedChild.id,
                    node: onlyGroupedChild
                )
            )
        }

        return visible
    }

    private nonisolated static func colorRole(for entry: GroupEntry) -> SunburstColorRole {
        if entry.isAggregate {
            return .aggregate
        }
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(entry.nodeID) {
            return .freeSpace
        }
        return .normal
    }

    private nonisolated static func colorableIndexes(
        for entries: [GroupEntry],
        cancellationCheck: CancellationCheck
    ) throws -> [String: Int] {
        var indexes: [String: Int] = [:]
        indexes.reserveCapacity(entries.count)

        for entry in entries where !entry.isAggregate {
            try cancellationCheck()
            indexes[entry.id] = indexes.count
        }

        return indexes
    }

    private nonisolated struct GroupEntry {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let colorID: String
        let node: FileNodeRecord?
    }
}

enum SunburstRenderer {
    nonisolated static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let innerRadius = maxRadius * segment.innerRadius
        let outerRadius = maxRadius * segment.outerRadius

        let start = segment.startAngle.radians - (.pi / 2)
        let end = segment.endAngle.radians - (.pi / 2)

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(end),
            endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

nonisolated enum SunburstCenterHitTester {
    nonisolated static func contains(
        point: CGPoint,
        in size: CGSize,
        radius: CGFloat = SunburstLayout.centerRadius
    ) -> Bool {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0, radius > 0 else { return false }

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt((dx * dx) + (dy * dy))
        return (distance / maxRadius) < radius
    }
}

nonisolated final class SunburstSegmentIndex: Sendable {
    private struct NodeEntry: Sendable {
        let segment: SunburstSegment
        let layoutIndex: Int
    }

    let depths: [Int]
    let segmentCount: Int

    private let segmentsByDepth: [Int: [SunburstSegment]]
    private let segmentByID: [SunburstSegment.ID: SunburstSegment]
    private let nodeEntryByID: [String: NodeEntry]

    nonisolated init(segments: [SunburstSegment]) {
        var segmentsByDepth: [Int: [SunburstSegment]] = [:]
        var segmentByID: [SunburstSegment.ID: SunburstSegment] = [:]
        segmentByID.reserveCapacity(segments.count)
        var nodeEntryByID: [String: NodeEntry] = [:]
        nodeEntryByID.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            segmentsByDepth[segment.depth, default: []].append(segment)
            segmentByID[segment.id] = segment
            if let nodeID = segment.nodeID {
                nodeEntryByID[nodeID] = NodeEntry(
                    segment: segment,
                    layoutIndex: index
                )
            }
        }

        depths = segmentsByDepth.keys.sorted()
        segmentCount = segments.count
        self.segmentsByDepth = segmentsByDepth
        self.segmentByID = segmentByID
        self.nodeEntryByID = nodeEntryByID
    }

    nonisolated func segments(atDepth depth: Int) -> [SunburstSegment] {
        segmentsByDepth[depth] ?? []
    }

    nonisolated func segment(id: SunburstSegment.ID) -> SunburstSegment? {
        segmentByID[id]
    }

    nonisolated func segment(nodeID: String) -> SunburstSegment? {
        nodeEntryByID[nodeID]?.segment
    }

    nonisolated func indexedSegment(
        nodeID: String
    ) -> (layoutIndex: Int, segment: SunburstSegment)? {
        guard let entry = nodeEntryByID[nodeID] else { return nil }
        return (entry.layoutIndex, entry.segment)
    }
}

nonisolated struct SunburstHitTestIndex: Sendable {
    private let rings: [Ring]

    nonisolated init(segments: [SunburstSegment]) {
        var segmentsByDepth: [Int: [SunburstSegment]] = [:]
        for segment in segments {
            segmentsByDepth[segment.depth, default: []].append(segment)
        }

        rings = segmentsByDepth
            .map { depth, segments in
                Ring(depth: depth, segments: segments)
            }
            .sorted { $0.depth < $1.depth }
    }

    nonisolated init(segmentIndex: SunburstSegmentIndex) {
        rings = segmentIndex.depths.map { depth in
            Ring(
                depth: depth,
                segments: segmentIndex.segments(atDepth: depth)
            )
        }
    }

    nonisolated func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        guard !rings.isEmpty else { return nil }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0 else { return nil }

        let distance = sqrt((dx * dx) + (dy * dy))
        let normalizedDistance = distance / maxRadius
        guard let ring = rings.first(where: { $0.contains(normalizedDistance) }) else {
            return nil
        }

        var radians = atan2(dy, dx) + (.pi / 2)
        if radians < 0 {
            radians += (.pi * 2)
        }

        return ring.segment(containing: radians)
    }

    private struct Ring: Sendable {
        let depth: Int
        let minInnerRadius: CGFloat
        let maxOuterRadius: CGFloat
        let segments: [SunburstSegment]

        nonisolated init(depth: Int, segments: [SunburstSegment]) {
            self.depth = depth
            self.segments = segments.sorted { lhs, rhs in
                lhs.startAngle.radians < rhs.startAngle.radians
            }

            var minInnerRadius = CGFloat.greatestFiniteMagnitude
            var maxOuterRadius: CGFloat = 0
            for segment in segments {
                minInnerRadius = min(minInnerRadius, segment.innerRadius)
                maxOuterRadius = max(maxOuterRadius, segment.outerRadius)
            }

            self.minInnerRadius = minInnerRadius == .greatestFiniteMagnitude ? 0 : minInnerRadius
            self.maxOuterRadius = maxOuterRadius
        }

        nonisolated func contains(_ normalizedDistance: CGFloat) -> Bool {
            normalizedDistance >= minInnerRadius && normalizedDistance <= maxOuterRadius
        }

        nonisolated func segment(containing radians: Double) -> SunburstSegment? {
            guard !segments.isEmpty else { return nil }

            var lowerBound = 0
            var upperBound = segments.count
            while lowerBound < upperBound {
                let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
                if segments[midpoint].startAngle.radians <= radians {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }

            let candidate = segments[max(lowerBound - 1, 0)]
            guard radians >= candidate.startAngle.radians,
                  radians <= candidate.endAngle.radians else {
                return nil
            }
            return candidate
        }
    }
}
