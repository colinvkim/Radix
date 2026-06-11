import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22

    let rootNode: FileNodeRecord
    let treeStore: FileTreeStore
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void

    @StateObject private var chartModel: SunburstChartModel

    init(
        rootNode: FileNodeRecord,
        treeStore: FileTreeStore,
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>,
        depthLimit: Int,
        layoutID: String,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        chartModel: @autoclosure @escaping () -> SunburstChartModel = SunburstChartModel()
    ) {
        self.rootNode = rootNode
        self.treeStore = treeStore
        self.selectedNodeID = selectedNodeID
        self.selectedAncestorIDs = selectedAncestorIDs
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.onSelect = onSelect
        self.onZoom = onZoom
        _chartModel = StateObject(wrappedValue: chartModel())
    }

    private var displayedNode: FileNodeRecord? {
        if let hoveredNodeID = chartModel.hoveredSegment?.nodeID,
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
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }

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
                SunburstBaseCanvas(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)

                SunburstSelectionOverlay(
                    segments: chartModel.selectionOverlaySegments(
                        selectedNodeID: selectedNodeID,
                        selectedAncestorIDs: selectedAncestorIDs
                    )
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)

                SunburstHoverOverlay(
                    segment: chartModel.hoveredSegment
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)

                if chartModel.isLayoutPending {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.28)
                        .allowsHitTesting(false)

                    ProgressView("Loading Disk Map…")
                        .controlSize(.small)
                } else if chartModel.renderedSegments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                SunburstInteractionOverlay(
                    onHover: { location in
                        guard !chartModel.isLayoutPending else { return }
                        updateHover(at: location, in: chartFrame)
                    },
                    onClick: { location, clickCount in
                        guard !chartModel.isLayoutPending else { return }
                        handleClick(at: location, in: chartFrame, clickCount: clickCount)
                    }
                )
                .accessibilityHidden(true)
                .allowsHitTesting(!chartModel.isLayoutPending)
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
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    layoutID: layoutID
                )
            }
        }
    }

    private func updateHover(at location: CGPoint?, in frame: CGRect) {
        guard let location else {
            chartModel.setHoveredSegmentID(nil)
            return
        }

        let nextSegment = hitTest(at: location, in: frame)
        chartModel.setHoveredSegmentID(nextSegment?.id)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        if clickCount >= 2,
           treeStore.node(id: nodeID)?.isDirectory == true {
            onZoom(nodeID)
        } else {
            onSelect(nodeID)
        }
    }

    private var accessibilityValue: String {
        let node = displayedNode ?? rootNode
        return "\(node.name), \(RadixFormatters.size(node.allocatedSize)), \(node.itemKind)"
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
        return chartModel.segment(at: localPoint, in: frame.size)
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

private struct SunburstBaseCanvas: View, Equatable {
    let segments: [SunburstSegment]
    let renderVersion: Int

    static func == (lhs: SunburstBaseCanvas, rhs: SunburstBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
    }

    var body: some View {
        Canvas { context, size in
            for segment in segments {
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.baseStyle(for: segment)
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

private struct SunburstSelectionOverlay: View, Equatable {
    let segments: [SunburstSelectionOverlaySegment]

    var body: some View {
        Canvas { context, size in
            for overlaySegment in segments {
                let segment = overlaySegment.segment
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.selectionOverlayStyle(
                    for: segment,
                    role: overlaySegment.role
                )
                if style.fillOpacity > 0 {
                    context.fill(path, with: .color(style.fillColor))
                }
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

private struct SunburstHoverOverlay: View, Equatable {
    let segment: SunburstSegment?

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }

            let path = SunburstRenderer.path(for: segment, in: size)
            let style = SunburstChartStyler.hoverOverlayStyle(for: segment)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor))
            }
            context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        }
    }
}

private struct SunburstSegmentDrawingStyle {
    let fillBaseColor: Color
    let fillOpacity: Double
    let strokeColor: Color
    let strokeWidth: CGFloat

    var fillColor: Color {
        fillBaseColor.opacity(fillOpacity)
    }
}

private enum SunburstChartStyler {
    private static let palette: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPink)
    ]

    static func baseStyle(
        for segment: SunburstSegment
    ) -> SunburstSegmentDrawingStyle {
        if segment.isAggregate {
            return SunburstSegmentDrawingStyle(
                fillBaseColor: Color(nsColor: .tertiaryLabelColor),
                fillOpacity: 0.22,
                strokeColor: Color(nsColor: .separatorColor).opacity(0.55),
                strokeWidth: 1
            )
        }

        let baseOpacity = standardOpacity(for: segment)

        return SunburstSegmentDrawingStyle(
            fillBaseColor: baseColor(for: segment),
            fillOpacity: baseOpacity,
            strokeColor: Color(nsColor: .separatorColor).opacity(0.4),
            strokeWidth: 1
        )
    }

    static func selectionOverlayStyle(
        for segment: SunburstSegment,
        role: SunburstSelectionRole
    ) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity: Double
        let strokeColor: Color
        let strokeWidth: CGFloat

        switch role {
        case .ancestor:
            targetFillOpacity = min(base.fillOpacity + 0.04, 0.84)
            strokeColor = Color.white.opacity(0.22)
            strokeWidth = 1.5
        case .selected:
            targetFillOpacity = min(base.fillOpacity + 0.1, 0.9)
            strokeColor = Color.white.opacity(0.5)
            strokeWidth = 2.5
        }

        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
    }

    static func hoverOverlayStyle(for segment: SunburstSegment) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity = hoverFillOpacity(for: segment)
        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: .primary.opacity(0.85),
            strokeWidth: 2.5
        )
    }

    private static func baseColor(for segment: SunburstSegment) -> Color {
        if segment.isAggregate {
            return Color(nsColor: .tertiaryLabelColor)
        }

        let paletteIndex = StablePaletteIndex.index(for: segment.colorKey, count: palette.count)
        return palette[paletteIndex]
    }

    private static func standardOpacity(for segment: SunburstSegment) -> Double {
        max(0.24, 0.78 - (Double(segment.depth) * 0.09) - (segment.isAggregate ? 0.16 : 0))
    }

    private static func hoverFillOpacity(for segment: SunburstSegment) -> Double {
        if segment.isAggregate {
            return 0.4
        }

        return min(standardOpacity(for: segment) + 0.18, 0.95)
    }

    private static func overlayOpacity(from baseOpacity: Double, to targetOpacity: Double) -> Double {
        guard targetOpacity > baseOpacity else { return 0 }
        let remainingOpacity = max(1 - baseOpacity, .leastNonzeroMagnitude)
        return min(max((targetOpacity - baseOpacity) / remainingOpacity, 0), 1)
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
