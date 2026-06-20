import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22

    let rootNode: FileNodeRecord
    let parentNode: FileNodeRecord?
    let treeStore: FileTreeStore
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onNavigateToParent: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false

    init(
        rootNode: FileNodeRecord,
        parentNode: FileNodeRecord?,
        treeStore: FileTreeStore,
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>,
        depthLimit: Int,
        layoutID: String,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onNavigateToParent: @escaping () -> Void,
        chartModel: @autoclosure @escaping () -> SunburstChartModel = SunburstChartModel()
    ) {
        self.rootNode = rootNode
        self.parentNode = parentNode
        self.treeStore = treeStore
        self.selectedNodeID = selectedNodeID
        self.selectedAncestorIDs = selectedAncestorIDs
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onNavigateToParent = onNavigateToParent
        _chartModel = StateObject(wrappedValue: chartModel())
    }

    private var displayedNode: FileNodeRecord? {
        if isHoveringCenter, let parentNode {
            return parentNode
        }
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
                SunburstRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectionSegments: chartModel.selectionOverlaySegments(
                        selectedNodeID: selectedNodeID,
                        selectedAncestorIDs: selectedAncestorIDs
                    ),
                    chartFrame: chartFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                SunburstHoverOverlay(
                    segment: chartModel.hoveredSegment
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)

                if parentNode != nil,
                   isHoveringCenter,
                   !chartModel.isLayoutPending,
                   !chartModel.renderedSegments.isEmpty {
                    SunburstCenterAffordance()
                        .equatable()
                        .frame(
                            width: centerAffordanceSize(in: chartFrame),
                            height: centerAffordanceSize(in: chartFrame)
                        )
                        .position(x: chartFrame.midX, y: chartFrame.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

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
                    },
                    help: { location in
                        guard !chartModel.isLayoutPending else { return nil }
                        return help(at: location, in: chartFrame)
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
            .accessibilityHint(accessibilityHint)
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(centerHoverAnimation, value: isHoveringCenter)
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

    private var chartTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.985, anchor: .center))
    }

    private var chartTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.22)
    }

    private var centerHoverAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
    }

    private func updateHover(at location: CGPoint?, in frame: CGRect) {
        guard let location else {
            isHoveringCenter = false
            chartModel.setHoveredSegmentID(nil)
            return
        }

        if parentNode != nil, isCenterHit(at: location, in: frame) {
            isHoveringCenter = true
            chartModel.setHoveredSegmentID(nil)
            return
        }

        isHoveringCenter = false
        let nextSegment = hitTest(at: location, in: frame)
        chartModel.setHoveredSegmentID(nextSegment?.id)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        if isCenterHit(at: location, in: frame) {
            if clickCount == 1, parentNode != nil {
                onNavigateToParent()
            }
            return
        }

        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
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
        return "\(node.name), \(RadixFormatters.size(node.allocatedSize)), \(summaryStatus(for: node))"
    }

    private var accessibilityHint: String {
        if parentNode != nil {
            return "Select a segment to inspect it. Double-click a folder segment to zoom in. Click the center to go up."
        }

        return "Select a segment to inspect it. Double-click a folder segment to zoom in."
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        let width = max(1, size.width - (inset * 2))
        let height = max(1, size.height - (inset * 2))
        return CGRect(x: inset, y: inset, width: width, height: height)
    }

    private func centerAffordanceSize(in frame: CGRect) -> CGFloat {
        min(frame.width, frame.height) * SunburstLayout.centerRadius
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> SunburstSegment? {
        guard frame.contains(location) else { return nil }

        let localPoint = CGPoint(
            x: location.x - frame.minX,
            y: location.y - frame.minY
        )
        return chartModel.segment(at: localPoint, in: frame.size)
    }

    private func isCenterHit(at location: CGPoint, in frame: CGRect) -> Bool {
        guard frame.contains(location) else { return false }

        let localPoint = CGPoint(
            x: location.x - frame.minX,
            y: location.y - frame.minY
        )
        return SunburstCenterHitTester.contains(point: localPoint, in: frame.size)
    }

    private func help(at location: CGPoint, in frame: CGRect) -> String? {
        guard let parentNode, isCenterHit(at: location, in: frame) else { return nil }
        return "Go up to \(parentNode.name)"
    }

    private func summary(for node: FileNodeRecord) -> ChartSummary {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return ChartSummary(
                status: summaryStatus(for: node),
                title: node.name,
                value: RadixFormatters.size(node.allocatedSize),
                detail: "APFS available capacity"
            )
        }

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

    private func summaryStatus(for node: FileNodeRecord) -> String {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return "Available Space"
        }
        return node.itemKind
    }
}

private struct SunburstCenterAffordance: View, Equatable {
    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .shadow(color: Color.black.opacity(0.14), radius: 2, y: 1)
    }
}

private struct SunburstRenderedChartLayer: View {
    let segments: [SunburstSegment]
    let renderVersion: Int
    let selectionSegments: [SunburstSelectionOverlaySegment]
    let chartFrame: CGRect

    var body: some View {
        ZStack {
            SunburstBaseCanvas(
                segments: segments,
                renderVersion: renderVersion
            )
            .equatable()

            SunburstSelectionOverlay(segments: selectionSegments)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
