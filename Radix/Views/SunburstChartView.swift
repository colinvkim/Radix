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
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))

                Canvas { context, size in
                    for segment in segments {
                        let path = SunburstRenderer.path(for: segment, in: size)
                        context.fill(path, with: .color(fillColor(for: segment)))
                        context.stroke(
                            path,
                            with: .color(strokeColor(for: segment)),
                            lineWidth: strokeWidth(for: segment)
                        )
                    }
                }
                .padding(28)

                VStack(spacing: 8) {
                    Text(displayedNode?.name ?? rootNode.name)
                        .font(.headline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Text(RadixFormatters.size(displayedNode?.allocatedSize ?? rootNode.allocatedSize))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(displayedNode?.itemKind ?? rootNode.itemKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if let hoveredSegment {
                    HoverSummary(segment: hoveredSegment, node: index.node(id: hoveredSegment.nodeID))
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

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
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
        }
    }

    private func fillColor(for segment: SunburstSegment) -> Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .indigo, .mint]
        let base = palette[abs(segment.colorKey.hashValue) % palette.count]
        let opacity = max(0.24, 0.78 - (Double(segment.depth) * 0.09) - (segment.isAggregate ? 0.16 : 0))
        return base.opacity(opacity)
    }

    private func strokeColor(for segment: SunburstSegment) -> Color {
        if segment.nodeID == selectedNodeID {
            return .accentColor
        }
        if let nodeID = segment.nodeID, index.isAncestor(nodeID, of: selectedNodeID) {
            return .accentColor.opacity(0.45)
        }
        return Color(nsColor: .separatorColor).opacity(0.4)
    }

    private func strokeWidth(for segment: SunburstSegment) -> CGFloat {
        if segment.nodeID == selectedNodeID {
            return 3
        }
        if let nodeID = segment.nodeID, index.isAncestor(nodeID, of: selectedNodeID) {
            return 2
        }
        return 1
    }
}

private struct HoverSummary: View {
    let segment: SunburstSegment
    let node: FileNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node?.name ?? segment.label)
                .font(.headline)
                .lineLimit(2)

            Text(RadixFormatters.size(node?.allocatedSize ?? segment.totalSize))
                .font(.subheadline.weight(.semibold))

            Text(node?.url.path ?? "Grouped smaller items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
