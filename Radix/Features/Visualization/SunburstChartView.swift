import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22

    let rootNode: FileNodeRecord
    let treeStore: FileTreeStore
    let selectedNodeID: String?
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void

    @State private var hoveredSegment: SunburstSegment?
    @State private var renderedSegments: [SunburstSegment]

    init(
        rootNode: FileNodeRecord,
        treeStore: FileTreeStore,
        selectedNodeID: String?,
        depthLimit: Int,
        layoutID: String,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void
    ) {
        self.rootNode = rootNode
        self.treeStore = treeStore
        self.selectedNodeID = selectedNodeID
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.onSelect = onSelect
        self.onZoom = onZoom
        _renderedSegments = State(initialValue: SunburstLayout.segments(in: treeStore, rootID: rootNode.id, depthLimit: depthLimit))
    }

    private var displayedNode: FileNodeRecord? {
        if let hoveredNodeID = hoveredSegment?.nodeID,
           let hoveredNode = treeStore.node(id: hoveredNodeID) {
            return hoveredNode
        }
        if let selectedNodeID,
           let selectedNode = treeStore.node(id: selectedNodeID) {
            return selectedNode
        }
        return rootNode
    }

    private var hoverSummary: ChartSummary? {
        guard let hoveredSegment else { return nil }

        if let hoveredNodeID = hoveredSegment.nodeID,
           let hoveredNode = treeStore.node(id: hoveredNodeID) {
            return summary(for: hoveredNode)
        }

        return ChartSummary(
            status: "Grouped Items",
            title: hoveredSegment.label,
            value: RadixFormatters.size(hoveredSegment.totalSize),
            detail: "Too small to show individually"
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let chartFrame = chartFrame(in: geometry.size)

            ZStack {
                Canvas { context, size in
                    for segment in renderedSegments {
                        let path = SunburstRenderer.path(for: segment, in: size)
                        context.fill(path, with: .color(fillColor(for: segment)))
                        context.stroke(
                            path,
                            with: .color(strokeColor(for: segment)),
                            lineWidth: strokeWidth(for: segment)
                        )
                    }
                }
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
            }
            .contentShape(Rectangle())
            .overlay {
                SunburstInteractionOverlay(
                    onHover: { location in
                        updateHover(at: location, in: chartFrame)
                    },
                    onClick: { location, clickCount in
                        handleClick(at: location, in: chartFrame, clickCount: clickCount)
                    }
                )
                .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if let hoverSummary {
                    FloatingSummaryCard(summary: hoverSummary)
                        .padding(.top, 16)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Select a segment to inspect it. Double-click a folder segment to zoom in.")
            .task(id: layoutID) {
                let store = treeStore
                let rootID = rootNode.id
                let depth = depthLimit
                let segments = await Task.detached(priority: .userInitiated) {
                    SunburstLayout.segments(in: store, rootID: rootID, depthLimit: depth)
                }.value
                guard !Task.isCancelled else { return }
                hoveredSegment = nil
                renderedSegments = segments
            }
        }
    }

    private func updateHover(at location: CGPoint?, in frame: CGRect) {
        guard let location else {
            hoveredSegment = nil
            return
        }

        hoveredSegment = hitTest(at: location, in: frame)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        onSelect(nodeID)

        if clickCount >= 2,
           treeStore.node(id: nodeID)?.isDirectory == true {
            onZoom(nodeID)
        }
    }

    private var accessibilityValue: String {
        let node = displayedNode ?? rootNode
        return "\(node.name), \(RadixFormatters.size(node.allocatedSize)), \(node.itemKind)"
    }

    private func fillColor(for segment: SunburstSegment) -> Color {
        if segment.isAggregate {
            let base = Color(nsColor: .tertiaryLabelColor)
            return base.opacity(segment.id == hoveredSegment?.id ? 0.4 : 0.22)
        }

        let palette: [Color] = [
            Color(nsColor: .systemBlue),
            Color(nsColor: .systemTeal),
            Color(nsColor: .systemGreen),
            Color(nsColor: .systemOrange),
            Color(nsColor: .systemIndigo),
            Color(nsColor: .systemPink)
        ]
        let base = palette[abs(segment.colorKey.hashValue) % palette.count]
        let opacity = max(0.24, 0.78 - (Double(segment.depth) * 0.09) - (segment.isAggregate ? 0.16 : 0))
        if segment.id == hoveredSegment?.id {
            return base.opacity(min(opacity + 0.18, 0.95))
        }
        if segment.nodeID == selectedNodeID {
            return base.opacity(min(opacity + 0.1, 0.9))
        }
        if let nodeID = segment.nodeID, treeStore.isAncestor(nodeID, of: selectedNodeID) {
            return base.opacity(min(opacity + 0.04, 0.84))
        }
        if selectedNodeID != nil {
            return base.opacity(opacity * 0.82)
        }
        return base.opacity(opacity)
    }

    private func strokeColor(for segment: SunburstSegment) -> Color {
        if segment.id == hoveredSegment?.id {
            return .primary.opacity(0.85)
        }
        if segment.isAggregate {
            return Color(nsColor: .separatorColor).opacity(0.55)
        }
        if segment.nodeID == selectedNodeID {
            return Color.white.opacity(0.5)
        }
        if let nodeID = segment.nodeID, treeStore.isAncestor(nodeID, of: selectedNodeID) {
            return Color.white.opacity(0.22)
        }
        return Color(nsColor: .separatorColor).opacity(0.4)
    }

    private func strokeWidth(for segment: SunburstSegment) -> CGFloat {
        if segment.id == hoveredSegment?.id {
            return 2.5
        }
        if segment.nodeID == selectedNodeID {
            return 2.5
        }
        if let nodeID = segment.nodeID, treeStore.isAncestor(nodeID, of: selectedNodeID) {
            return 1.5
        }
        return 1
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        let width = max(1, size.width - (inset * 2))
        let height = max(1, size.height - (inset * 2))
        return CGRect(x: inset, y: inset, width: width, height: height)
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> SunburstSegment? {
        guard frame.contains(location) else { return nil }

        let localPoint = CGPoint(
            x: location.x - frame.minX,
            y: location.y - frame.minY
        )
        return SunburstHitTester.segment(at: localPoint, in: frame.size, segments: renderedSegments)
    }

    private func summary(for node: FileNodeRecord) -> ChartSummary {
        let detail: String
        if node.id != rootNode.id,
           let percentText = RadixFormatters.percentage(part: node.allocatedSize, total: rootNode.allocatedSize) {
            detail = percentText + " of current focus"
        } else {
            detail = node.itemKind
        }

        return ChartSummary(
            status: node.itemKind,
            title: node.name,
            value: RadixFormatters.size(node.allocatedSize),
            detail: detail
        )
    }
}

private struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onHover = onHover
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }

        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

        override func mouseDown(with event: NSEvent) {
            onClick(convert(event.locationInWindow, from: nil), event.clickCount)
        }
    }
}

private struct ChartSummary {
    let status: String
    let title: String
    let value: String
    let detail: String
}

private struct FloatingSummaryCard: View {
    let summary: ChartSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(summary.title)
                .font(.headline.weight(.semibold))
                .lineLimit(2)

            Text(summary.value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
