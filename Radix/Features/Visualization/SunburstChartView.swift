import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 12

    let rootNode: FileNode
    let index: FileTreeIndex
    let selectedNodeID: String?
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void

    @State private var hoveredSegment: SunburstSegment?
    @State private var renderedSegments: [SunburstSegment]
    @State private var renderScale: CGFloat = 1
    @State private var renderOpacity = 1.0

    init(
        rootNode: FileNode,
        index: FileTreeIndex,
        selectedNodeID: String?,
        depthLimit: Int,
        layoutID: String,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void
    ) {
        self.rootNode = rootNode
        self.index = index
        self.selectedNodeID = selectedNodeID
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.onSelect = onSelect
        self.onZoom = onZoom
        _renderedSegments = State(initialValue: SunburstLayout.segments(for: rootNode, depthLimit: depthLimit))
    }

    private var displayedSummary: ChartSummary {
        if let hoveredSegment {
            if let hoveredNodeID = hoveredSegment.nodeID,
               let hoveredNode = index.node(id: hoveredNodeID) {
                return summary(for: hoveredNode)
            }

            return ChartSummary(
                status: "Grouped Items",
                title: hoveredSegment.label,
                value: RadixFormatters.size(hoveredSegment.totalSize),
                detail: "Too small to show individually"
            )
        }

        if let selectedNodeID,
           let selectedNode = index.node(id: selectedNodeID) {
            return summary(for: selectedNode)
        }

        return summary(for: rootNode)
    }

    var body: some View {
        GeometryReader { geometry in
            let chartFrame = chartFrame(in: geometry.size)

            ZStack {
                Canvas { context, size in
                    for segment in backgroundSegments {
                        draw(segment, in: size, with: &context)
                    }

                    for segment in foregroundSegments {
                        draw(segment, in: size, with: &context)
                    }
                }
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .scaleEffect(renderScale)
                .opacity(renderOpacity)

                CenterSummaryCard(summary: displayedSummary)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.18), value: hoveredSegment?.id)
            .animation(.snappy(duration: 0.18), value: selectedNodeID)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoveredSegment = hitTest(at: location, in: chartFrame)
                case .ended:
                    hoveredSegment = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard let segment = hitTest(at: location, in: chartFrame),
                      let nodeID = segment.nodeID else {
                    onSelect(nil)
                    return
                }

                onSelect(nodeID)
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                guard let segment = hitTest(at: location, in: chartFrame),
                      let nodeID = segment.nodeID,
                      index.node(id: nodeID)?.isDirectory == true else {
                    return
                }

                onSelect(nodeID)
                onZoom(nodeID)
            }
            .interactivePointer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Select a segment to inspect it. Double-click a folder segment to zoom in.")
            .task(id: layoutID) {
                await refreshSegments()
            }
        }
    }

    private var accessibilityValue: String {
        let node = index.node(id: hoveredSegment?.nodeID) ??
            index.node(id: selectedNodeID) ??
            rootNode
        return "\(node.name), \(RadixFormatters.size(node.allocatedSize)), \(node.itemKind)"
    }

    private var backgroundSegments: [SunburstSegment] {
        renderedSegments.filter { !isForeground($0) }
    }

    private var foregroundSegments: [SunburstSegment] {
        renderedSegments.filter(isForeground)
    }

    private func draw(_ segment: SunburstSegment, in size: CGSize, with context: inout GraphicsContext) {
        let path = SunburstRenderer.path(for: segment, in: size)
        context.fill(path, with: .color(fillColor(for: segment)))
        context.stroke(
            path,
            with: .color(strokeColor(for: segment)),
            lineWidth: strokeWidth(for: segment)
        )
    }

    private func isForeground(_ segment: SunburstSegment) -> Bool {
        segment.id == hoveredSegment?.id ||
            segment.nodeID == selectedNodeID ||
            {
                guard let nodeID = segment.nodeID else { return false }
                return index.isAncestor(nodeID, of: selectedNodeID)
            }()
    }

    private func fillColor(for segment: SunburstSegment) -> Color {
        let palette: [Color] = [
            Color(nsColor: .systemBlue),
            Color(nsColor: .systemTeal),
            Color(nsColor: .systemGreen),
            Color(nsColor: .systemOrange),
            Color(nsColor: .systemIndigo),
            Color(nsColor: .systemPink)
        ]

        let base: Color
        if segment.isAggregate {
            base = Color(nsColor: .tertiaryLabelColor)
        } else {
            base = palette[abs(segment.colorKey.hashValue) % palette.count]
        }

        let baseOpacity = segment.isAggregate
            ? 0.18
            : max(0.24, 0.8 - (Double(segment.depth) * 0.09))

        if segment.id == hoveredSegment?.id {
            return base.opacity(min(baseOpacity + 0.24, 0.96))
        }

        if hoveredSegment != nil {
            return base.opacity(baseOpacity * 0.42)
        }

        if segment.nodeID == selectedNodeID {
            return base.opacity(min(baseOpacity + 0.14, 0.9))
        }

        if let nodeID = segment.nodeID, index.isAncestor(nodeID, of: selectedNodeID) {
            return base.opacity(baseOpacity * 0.9)
        }

        return base.opacity(baseOpacity)
    }

    private func strokeColor(for segment: SunburstSegment) -> Color {
        if segment.id == hoveredSegment?.id {
            return .primary.opacity(0.95)
        }

        if segment.nodeID == selectedNodeID {
            return .accentColor
        }

        if let nodeID = segment.nodeID, index.isAncestor(nodeID, of: selectedNodeID) {
            return .accentColor.opacity(0.45)
        }

        return Color(nsColor: .separatorColor).opacity(0.32)
    }

    private func strokeWidth(for segment: SunburstSegment) -> CGFloat {
        if segment.id == hoveredSegment?.id {
            return 3
        }

        if segment.nodeID == selectedNodeID {
            return 4
        }

        if let nodeID = segment.nodeID, index.isAncestor(nodeID, of: selectedNodeID) {
            return 2
        }

        return 1
    }

    private func percentageText(part: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        return (Double(part) / Double(total))
            .formatted(.percent.precision(.fractionLength(1)))
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

    private func refreshSegments() async {
        let node = rootNode
        let depth = depthLimit

        withAnimation(.easeOut(duration: 0.12)) {
            hoveredSegment = nil
            renderScale = 0.985
            renderOpacity = 0.72
        }

        let segments = await Task.detached(priority: .userInitiated) {
            SunburstLayout.segments(for: node, depthLimit: depth)
        }.value

        guard !Task.isCancelled else { return }

        renderedSegments = segments

        withAnimation(.snappy(duration: 0.28, extraBounce: 0.03)) {
            renderScale = 1
            renderOpacity = 1
        }
    }

    private func summary(for node: FileNode) -> ChartSummary {
        let detail: String
        if node.id != rootNode.id,
           let percentText = percentageText(part: node.allocatedSize, total: rootNode.allocatedSize) {
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

private struct ChartSummary {
    let status: String
    let title: String
    let value: String
    let detail: String
}

private struct CenterSummaryCard: View {
    let summary: ChartSummary

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(summary.status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(summary.title)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(summary.value)
                .font(.title3.weight(.semibold))

            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
