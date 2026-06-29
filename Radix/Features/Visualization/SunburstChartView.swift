import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22
    private static let loadingDiskMapDelay: Duration = .milliseconds(150)

    let rootNode: FileNodeRecord
    let parentNode: FileNodeRecord?
    let treeStore: FileTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    let layoutID: String
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onSegmentClick: () -> Void
    let onNavigateToParent: () -> Void
    let onCleanupListDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false
    @State private var showsLoadingDiskMapProgress = false
    @State private var viewportTransform = SunburstViewportTransform.identity

    init(
        rootNode: FileNodeRecord,
        parentNode: FileNodeRecord?,
        treeStore: FileTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>,
        depthLimit: Int,
        layoutID: String,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onSegmentClick: @escaping () -> Void,
        onNavigateToParent: @escaping () -> Void,
        onCleanupListDragActiveChange: @escaping (Bool) -> Void,
        chartModel: @autoclosure @escaping () -> SunburstChartModel = SunburstChartModel()
    ) {
        self.rootNode = rootNode
        self.parentNode = parentNode
        self.treeStore = treeStore
        self.snapshotID = snapshotID
        self.activeTarget = activeTarget
        self.trashSafetyPolicy = trashSafetyPolicy
        self.snapshotSource = snapshotSource
        self.selectedNodeID = selectedNodeID
        self.selectedAncestorIDs = selectedAncestorIDs
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onSegmentClick = onSegmentClick
        self.onNavigateToParent = onNavigateToParent
        self.onCleanupListDragActiveChange = onCleanupListDragActiveChange
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

    private var canAdjustViewport: Bool {
        !chartModel.isLayoutPending && !chartModel.renderedSegments.isEmpty
    }

    private var loadingDiskMapProgressTaskID: String {
        "\(layoutID)|\(chartModel.isLayoutPending)"
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)
            let chartFrame = viewportTransform.frame(for: baseChartFrame)
            let canAdjustViewport = self.canAdjustViewport

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

                    if showsLoadingDiskMapProgress {
                        ProgressView("Loading Disk Map…")
                            .controlSize(.small)
                            .transition(.opacity)
                    }
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
                        updateHover(at: location, in: baseChartFrame)
                    },
                    onClick: { location, clickCount in
                        guard !chartModel.isLayoutPending else { return }
                        handleClick(at: location, in: baseChartFrame, clickCount: clickCount)
                    },
                    onPan: { delta in
                        panViewport(by: delta, in: baseChartFrame)
                    },
                    onMagnify: { location, factor in
                        zoomViewport(by: factor, anchor: location, in: baseChartFrame, animated: false)
                    },
                    cleanupDragItem: { location in
                        cleanupListDragItem(at: location, in: baseChartFrame)
                    },
                    onCleanupDragActiveChange: onCleanupListDragActiveChange,
                    help: { location in
                        guard !chartModel.isLayoutPending else { return nil }
                        return help(at: location, in: baseChartFrame)
                    },
                    isPanEnabled: canAdjustViewport && viewportTransform.isZoomed
                )
                .accessibilityHidden(true)
                .allowsHitTesting(!chartModel.isLayoutPending)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: "Zoom In") {
                zoomViewport(by: 1.25, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: "Zoom Out") {
                zoomViewport(by: 0.8, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: "Reset Zoom") {
                resetViewport(animated: true)
            }
            .overlay(alignment: .topLeading) {
                if let hoverSummary {
                    FloatingSummaryCard(summary: hoverSummary)
                        .padding(.top, 16)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if canAdjustViewport {
                    SunburstViewportControls(
                        zoomText: viewportZoomText,
                        canZoomOut: viewportTransform.isZoomed,
                        canZoomIn: viewportTransform.scale < SunburstViewportTransform.maximumScale,
                        zoomOut: {
                            zoomViewport(by: 0.8, anchor: nil, in: baseChartFrame, animated: true)
                        },
                        zoomIn: {
                            zoomViewport(by: 1.25, anchor: nil, in: baseChartFrame, animated: true)
                        },
                        reset: {
                            resetViewport(animated: true)
                        }
                    )
                    .padding(.top, 16)
                    .padding(.trailing, 18)
                }
            }
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(centerHoverAnimation, value: isHoveringCenter)
            .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
            .onChange(of: baseChartFrame) { _, nextFrame in
                viewportTransform = viewportTransform.constrained(to: nextFrame)
            }
            .onChange(of: layoutID) { _, _ in
                resetViewport(animated: false)
            }
            .focusedSceneValue(\.sunburstViewportAction) { action in
                handleViewportAction(action, in: baseChartFrame)
            }
            .task(id: loadingDiskMapProgressTaskID) {
                await updateLoadingDiskMapProgress(isPending: chartModel.isLayoutPending)
            }
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

    private var loadingIndicatorAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
    }

    private var viewportAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)
    }

    private var viewportZoomText: String {
        "\(Int((viewportTransform.scale * 100).rounded()))%"
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
            onSegmentClick()
            onZoom(nodeID)
        } else {
            onSegmentClick()
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
        let chartSide = min(width, height)

        return CGRect(
            x: inset + ((width - chartSide) / 2),
            y: inset + ((height - chartSide) / 2),
            width: chartSide,
            height: chartSide
        )
    }

    private func centerAffordanceSize(in frame: CGRect) -> CGFloat {
        min(frame.width, frame.height) * SunburstLayout.centerRadius
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> SunburstSegment? {
        guard let chartPoint = viewportTransform.localChartPoint(for: location, in: frame) else {
            return nil
        }

        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func cleanupListDragItem(at location: CGPoint, in frame: CGRect) -> SunburstCleanupDragItem? {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID,
              !SunburstFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
              let node = treeStore.node(id: nodeID),
              canDragToCleanupList(node) else {
            return nil
        }

        return SunburstCleanupDragItem(
            payload: CleanupListDragPayload(
                snapshotID: snapshotID,
                nodeIDs: [nodeID]
            ),
            segment: segment
        )
    }

    private func canDragToCleanupList(_ node: FileNodeRecord) -> Bool {
        FileNodeActionAvailability(
            node: node,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy,
            snapshotSource: snapshotSource
        ).canMoveToTrash
    }

    private func isCenterHit(at location: CGPoint, in frame: CGRect) -> Bool {
        guard let chartPoint = viewportTransform.localChartPoint(for: location, in: frame) else {
            return false
        }

        return SunburstCenterHitTester.contains(
            point: chartPoint.point,
            in: chartPoint.size
        )
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

    private func zoomViewport(
        by factor: CGFloat,
        anchor: CGPoint?,
        in baseFrame: CGRect,
        animated: Bool
    ) {
        guard canAdjustViewport else { return }

        setViewportTransform(
            viewportTransform.zoomed(
                by: factor,
                anchor: anchor,
                in: baseFrame
            ),
            animated: animated
        )
    }

    private func panViewport(by delta: CGSize, in baseFrame: CGRect) {
        guard canAdjustViewport else { return }

        setViewportTransform(
            viewportTransform.panned(by: delta, in: baseFrame),
            animated: false
        )
    }

    private func resetViewport(animated: Bool) {
        setViewportTransform(.identity, animated: animated)
    }

    private func handleViewportAction(
        _ action: SunburstViewportAction,
        in baseFrame: CGRect
    ) {
        switch action {
        case .zoomIn:
            zoomViewport(by: 1.25, anchor: nil, in: baseFrame, animated: true)
        case .zoomOut:
            zoomViewport(by: 0.8, anchor: nil, in: baseFrame, animated: true)
        case .reset:
            resetViewport(animated: true)
        }
    }

    private func setViewportTransform(
        _ nextTransform: SunburstViewportTransform,
        animated: Bool
    ) {
        guard viewportTransform != nextTransform else { return }

        let update = {
            viewportTransform = nextTransform
        }

        if animated {
            withAnimation(viewportAnimation, update)
        } else {
            update()
        }
    }

    private func updateLoadingDiskMapProgress(isPending: Bool) async {
        guard isPending else {
            showsLoadingDiskMapProgress = false
            return
        }

        showsLoadingDiskMapProgress = false

        do {
            try await Task.sleep(for: Self.loadingDiskMapDelay)
        } catch {
            return
        }

        guard chartModel.isLayoutPending else { return }
        showsLoadingDiskMapProgress = true
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

private struct SunburstViewportControls: View {
    let zoomText: String
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            controlButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: "Zoom Out",
                action: zoomOut
            )
            .disabled(!canZoomOut)

            Text(zoomText)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)

            controlButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: "Zoom In",
                action: zoomIn
            )
            .disabled(!canZoomIn)

            Divider()
                .frame(height: 16)

            controlButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: "Reset Zoom",
                action: reset
            )
            .disabled(!canZoomOut)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func controlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
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
