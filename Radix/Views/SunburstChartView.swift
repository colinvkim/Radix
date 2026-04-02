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
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void

    @State private var hoveredSegment: SunburstSegment?

    private var segments: [SunburstSegment] {
        SunburstLayout.segments(for: rootNode, depthLimit: depthLimit)
    }

    private var displayedNode: FileNode? {
        if let hoveredNodeID = hoveredSegment?.nodeID,
           let hoveredNode = index.node(id: hoveredNodeID) {
            return hoveredNode
        }
        if let selectedNodeID,
           let selectedNode = index.node(id: selectedNodeID) {
            return selectedNode
        }
        return rootNode
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

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
                    Text(displayedNode?.name ?? rootNode.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(RadixFormatters.size(displayedNode?.allocatedSize ?? rootNode.allocatedSize))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let displayedNode, displayedNode.id != rootNode.id {
                        Text(displayedNode.itemKind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        onSelect(nil)
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
