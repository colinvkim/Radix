//
//  SunburstChartView.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import AppKit
import SwiftUI

struct SunburstChartView: View {
    let rootNode: FileNode
    let index: FileTreeIndex
    let selectedNodeID: String?
    let depthLimit: Int
    let onSelect: (String) -> Void
    let onZoom: (String) -> Void

    @State private var hoveredSegment: SunburstSegment?

    private var segments: [SunburstSegment] {
        SunburstLayout.segments(for: rootNode, depthLimit: depthLimit)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor),
                                Color(nsColor: .underPageBackgroundColor)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Canvas { context, size in
                    for segment in segments {
                        let path = SunburstRenderer.path(for: segment, in: size)
                        let fillColor = color(for: segment)
                        context.fill(path, with: .color(fillColor))

                        let isSelected = segment.nodeID == selectedNodeID
                        let isOnSelectedBranch = segment.nodeID.map { index.isAncestor($0, of: selectedNodeID) } ?? false
                        let strokeColor: Color = isSelected ? .accentColor : isOnSelectedBranch ? .accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.45)
                        let strokeWidth: CGFloat = isSelected ? 3 : isOnSelectedBranch ? 2 : 1
                        context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                    }
                }
                .padding(24)

                VStack(spacing: 6) {
                    Text(rootNode.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(RadixFormatters.size(rootNode.allocatedSize))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )

                SunburstPointerOverlay { point in
                    hoveredSegment = point.flatMap { SunburstHitTester.segment(at: $0, in: geometry.size, segments: segments) }
                } onClick: { point, clickCount in
                    guard let segment = SunburstHitTester.segment(at: point, in: geometry.size, segments: segments),
                          let nodeID = segment.nodeID else {
                        return
                    }

                    onSelect(nodeID)
                    if clickCount > 1 {
                        onZoom(nodeID)
                    }
                }

                if let hoveredSegment {
                    HoverCard(segment: hoveredSegment, node: index.node(id: hoveredSegment.nodeID))
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
        }
    }

    private func color(for segment: SunburstSegment) -> Color {
        let palette: [Color] = [
            .blue,
            .teal,
            .mint,
            .cyan,
            .indigo,
            .orange
        ]
        let base = palette[abs(segment.colorKey.hashValue) % palette.count]
        let depthFade = max(0.42, 0.82 - (Double(segment.depth) * 0.08))
        let aggregateFade = segment.isAggregate ? 0.18 : 0
        let selectionBoost = segment.nodeID == selectedNodeID ? 0.14 : 0
        let opacity = min(1, max(0.28, depthFade - aggregateFade + selectionBoost))
        return base.opacity(opacity)
    }
}

private struct HoverCard: View {
    let segment: SunburstSegment
    let node: FileNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node?.name ?? segment.label)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(RadixFormatters.size(node?.allocatedSize ?? segment.totalSize))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(node?.url.path ?? "Grouped smaller items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
        .frame(width: 280, alignment: .leading)
    }
}

private enum SunburstLayout {
    static func segments(
        for root: FileNode,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90
    ) -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }

        let rootChildren = root.children
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let ringStart: CGFloat = 0.22
        let ringWidth = (0.98 - ringStart) / CGFloat(max(depthLimit, 1))
        let denominator = max(root.allocatedSize, Int64(visibleChildren.count))

        var result: [SunburstSegment] = []
        appendSegments(
            children: visibleChildren,
            parentDenominator: denominator,
            startAngle: 0,
            endAngle: .pi * 2,
            depth: 0,
            depthLimit: depthLimit,
            ringStart: ringStart,
            ringWidth: ringWidth,
            topColorKey: nil,
            minimumAngle: minimumAngle,
            into: &result
        )
        return result
    }

    private static func appendSegments(
        children: [FileNode],
        parentDenominator: Int64,
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: CGFloat,
        ringWidth: CGFloat,
        topColorKey: String?,
        minimumAngle: Double,
        into segments: inout [SunburstSegment]
    ) {
        guard depth < depthLimit else { return }

        let safeDenominator = max(parentDenominator, Int64(children.count))
        let totalAngle = endAngle - startAngle
        let grouped = groupedChildren(children, denominator: safeDenominator, totalAngle: totalAngle, minimumAngle: minimumAngle)

        var cursor = startAngle
        for entry in grouped {
            let proportion = Double(entry.totalSize) / Double(safeDenominator)
            let segmentEnd = cursor + (totalAngle * proportion)
            let colorKey = topColorKey ?? entry.colorKey
            let segment = SunburstSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                label: entry.label,
                startAngle: .radians(cursor),
                endAngle: .radians(segmentEnd),
                innerRadius: ringStart + CGFloat(depth) * ringWidth,
                outerRadius: ringStart + CGFloat(depth + 1) * ringWidth - 0.015,
                depth: depth,
                colorKey: colorKey,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate
            )
            segments.append(segment)

            if let node = entry.node,
               depth + 1 < depthLimit,
               node.isDirectory,
               !node.children.isEmpty,
               node.allocatedSize > 0 {
                appendSegments(
                    children: node.children,
                    parentDenominator: node.allocatedSize,
                    startAngle: cursor,
                    endAngle: segmentEnd,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    ringStart: ringStart,
                    ringWidth: ringWidth,
                    topColorKey: colorKey,
                    minimumAngle: minimumAngle,
                    into: &segments
                )
            }

            cursor = segmentEnd
        }
    }

    private static func groupedChildren(
        _ children: [FileNode],
        denominator: Int64,
        totalAngle: Double,
        minimumAngle: Double
    ) -> [GroupEntry] {
        guard children.count > 1 else {
            return children.map {
                GroupEntry(
                    id: $0.id,
                    nodeID: $0.id,
                    label: $0.name,
                    totalSize: max($0.allocatedSize, 1),
                    isAggregate: false,
                    colorKey: $0.id,
                    node: $0
                )
            }
        }

        var visible: [GroupEntry] = []
        var groupedNodes: [FileNode] = []
        var groupedSize: Int64 = 0

        for child in children {
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
                        colorKey: child.id,
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
                    colorKey: children.first?.id ?? "aggregate",
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
                    colorKey: onlyGrouped.id,
                    node: onlyGrouped
                )
            )
        }

        return visible
    }

    private struct GroupEntry {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let colorKey: String
        let node: FileNode?
    }
}

private enum SunburstRenderer {
    static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
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

private enum SunburstHitTester {
    static func segment(
        at point: CGPoint,
        in size: CGSize,
        segments: [SunburstSegment]
    ) -> SunburstSegment? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let maxRadius = min(size.width, size.height) / 2
        let distance = sqrt((dx * dx) + (dy * dy))

        var radians = atan2(dy, dx) + (.pi / 2)
        if radians < 0 {
            radians += (.pi * 2)
        }

        return segments.first { segment in
            let innerRadius = maxRadius * segment.innerRadius
            let outerRadius = maxRadius * segment.outerRadius
            return distance >= innerRadius &&
                distance <= outerRadius &&
                radians >= segment.startAngle.radians &&
                radians <= segment.endAngle.radians
        }
    }
}

private struct SunburstPointerOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
    }

    final class TrackingView: NSView {
        var onHover: ((CGPoint?) -> Void)?
        var onClick: ((CGPoint, Int) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
            let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseMoved(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(convert(event.locationInWindow, from: nil), event.clickCount)
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}
