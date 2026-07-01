//
//  SunburstGeometry.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

struct SunburstSegment: Identifiable, Hashable, Sendable {
    let id: String
    let nodeID: String?
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

enum SunburstLayout {
    nonisolated static let centerRadius: CGFloat = 0.22

    typealias CancellationCheck = () throws -> Void

    nonisolated static func segments(
        in treeStore: FileTreeStore,
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
        in treeStore: FileTreeStore,
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
        let denominator = max(root.allocatedSize, Int64(visibleChildren.count))
        let colorBranchContext = ColorBranchContext(rootChildIDs: rootColorBranchIDs(in: treeStore))

        var result: [SunburstSegment] = []
        try appendSegments(
            in: treeStore,
            children: visibleChildren,
            parentDenominator: denominator,
            startAngle: 0,
            endAngle: .pi * 2,
            depth: 0,
            depthLimit: depthLimit,
            ringStart: ringStart,
            ringWidth: ringWidth,
            branchContext: nil,
            colorBranchContext: colorBranchContext,
            minimumAngle: minimumAngle,
            cancellationCheck: cancellationCheck,
            into: &result
        )
        return result
    }

    private nonisolated static func appendSegments(
        in treeStore: FileTreeStore,
        children: [FileNodeRecord],
        parentDenominator: Int64,
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: CGFloat,
        ringWidth: CGFloat,
        branchContext: ColorBranch?,
        colorBranchContext: ColorBranchContext,
        minimumAngle: Double,
        cancellationCheck: CancellationCheck,
        into segments: inout [SunburstSegment]
    ) throws {
        guard depth < depthLimit else { return }

        try cancellationCheck()
        let effectiveChildTotal = children.reduce(Int64(0)) { total, child in
            total + max(child.allocatedSize, 1)
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

        let siblingIndexes = colorableIndexes(for: grouped)
        let siblingCount = max(siblingIndexes.count, 1)
        var cursor = startAngle
        for entry in grouped {
            try cancellationCheck()
            let proportion = Double(entry.totalSize) / Double(safeDenominator)
            let segmentEnd = cursor + (totalAngle * proportion)
            let siblingIndex = siblingIndexes[entry.id] ?? 0
            let branch = branchContext ?? colorBranch(
                for: entry,
                in: treeStore,
                context: colorBranchContext,
                fallbackIndex: siblingIndex,
                fallbackCount: siblingCount
            )
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
                    parentDenominator: node.allocatedSize,
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
        denominator: Int64,
        totalAngle: Double,
        minimumAngle: Double,
        cancellationCheck: CancellationCheck
    ) throws -> [GroupEntry] {
        guard children.count > 1 else {
            return children.map {
                GroupEntry(
                    id: $0.id,
                    nodeID: $0.id,
                    label: $0.name,
                    totalSize: max($0.allocatedSize, 1),
                    isAggregate: false,
                    colorID: $0.id,
                    node: $0
                )
            }
        }

        var visible: [GroupEntry] = []
        var groupedNodes: [FileNodeRecord] = []
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let size = max(child.allocatedSize, 1)
            let angle = totalAngle * (Double(size) / Double(max(denominator, 1)))
            if angle < minimumAngle {
                groupedNodes.append(child)
                groupedSize += size
            } else {
                visible.append(
                    GroupEntry(
                        id: child.id,
                        nodeID: child.id,
                        label: child.name,
                        totalSize: size,
                        isAggregate: false,
                        colorID: child.id,
                        node: child
                    )
                )
            }
        }

        if groupedNodes.count > 1 {
            visible.append(
                GroupEntry(
                    id: "aggregate-\(children.first?.id ?? UUID().uuidString)",
                    nodeID: nil,
                    label: "Smaller Items",
                    totalSize: groupedSize,
                    isAggregate: true,
                    colorID: "aggregate-\(children.first?.id ?? UUID().uuidString)",
                    node: nil
                )
            )
        } else if let onlyGrouped = groupedNodes.first {
            visible.append(
                GroupEntry(
                    id: onlyGrouped.id,
                    nodeID: onlyGrouped.id,
                    label: onlyGrouped.name,
                    totalSize: max(onlyGrouped.allocatedSize, 1),
                    isAggregate: false,
                    colorID: onlyGrouped.id,
                    node: onlyGrouped
                )
            )
        }

        return visible
    }

    private nonisolated static func colorRole(for entry: GroupEntry) -> SunburstColorRole {
        if entry.isAggregate {
            return .aggregate
        }
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(entry.nodeID) {
            return .freeSpace
        }
        return .normal
    }

    private nonisolated static func colorBranch(
        for entry: GroupEntry,
        in treeStore: FileTreeStore,
        context: ColorBranchContext,
        fallbackIndex: Int,
        fallbackCount: Int
    ) -> ColorBranch {
        guard let branchID = topLevelBranchID(for: entry.nodeID, in: treeStore) else {
            return ColorBranch(id: entry.colorID, index: fallbackIndex, count: fallbackCount)
        }

        guard let branch = context.branch(id: branchID) else {
            return ColorBranch(id: branchID, index: fallbackIndex, count: fallbackCount)
        }

        return branch
    }

    private nonisolated static func rootColorBranchIDs(in treeStore: FileTreeStore) -> [String] {
        treeStore.children(of: treeStore.rootID)
            .map(\.id)
            .filter { !SunburstFreeSpaceVisualization.isFreeSpaceNodeID($0) }
    }

    private nonisolated static func topLevelBranchID(
        for nodeID: String?,
        in treeStore: FileTreeStore
    ) -> String? {
        guard let nodeID else { return nil }
        guard nodeID != treeStore.rootID else { return nodeID }

        var currentID = nodeID
        while let parentID = treeStore.parentIDByID[currentID] {
            if parentID == treeStore.rootID {
                return currentID
            }
            currentID = parentID
        }

        return nodeID
    }

    private nonisolated static func colorableIndexes(
        for entries: [GroupEntry]
    ) -> [String: Int] {
        var indexes: [String: Int] = [:]
        indexes.reserveCapacity(entries.count)

        for entry in entries where !entry.isAggregate {
            indexes[entry.id] = indexes.count
        }

        return indexes
    }

    private struct ColorBranch {
        let id: String
        let index: Int
        let count: Int
    }

    private struct ColorBranchContext {
        private let indexByID: [String: Int]
        private let count: Int

        init(rootChildIDs: [String]) {
            var indexByID: [String: Int] = [:]
            indexByID.reserveCapacity(rootChildIDs.count)

            for id in rootChildIDs where indexByID[id] == nil {
                indexByID[id] = indexByID.count
            }

            self.indexByID = indexByID
            self.count = max(indexByID.count, 1)
        }

        func branch(id: String) -> ColorBranch? {
            guard let index = indexByID[id] else { return nil }
            return ColorBranch(id: id, index: index, count: count)
        }
    }

    private struct GroupEntry {
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

enum SunburstHitTester {
    nonisolated static func segment(
        at point: CGPoint,
        in size: CGSize,
        segments: [SunburstSegment]
    ) -> SunburstSegment? {
        SunburstHitTestIndex(segments: segments).segment(at: point, in: size)
    }
}

enum SunburstCenterHitTester {
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

struct SunburstHitTestIndex: Sendable {
    private let rings: [Ring]

    nonisolated init(segments: [SunburstSegment]) {
        var ringSegmentsByDepth: [Int: [SunburstSegment]] = [:]
        for segment in segments {
            ringSegmentsByDepth[segment.depth, default: []].append(segment)
        }

        rings = ringSegmentsByDepth
            .map { depth, segments in
                Ring(depth: depth, segments: segments)
            }
            .sorted { $0.depth < $1.depth }
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

            let candidateIndex = max(lowerBound - 1, 0)
            let candidate = segments[candidateIndex]
            guard radians >= candidate.startAngle.radians,
                  radians <= candidate.endAngle.radians else {
                return nil
            }
            return candidate
        }
    }
}
