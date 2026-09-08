import AppKit
import SwiftUI

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22

    let rootNode: FileNodeRecord
    let parentNode: FileNodeRecord?
    let treeStore: DiskMapTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    let layoutID: String
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onSegmentClick: () -> Void
    let onNavigateToParent: () -> Void
    let onDiscardPileDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false
    private var viewport = ChartViewportState()
    @State private var layoutRetryGeneration = 0

    init(
        rootNode: FileNodeRecord,
        parentNode: FileNodeRecord?,
        treeStore: DiskMapTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        focusedWorkspaceTarget: FocusState<WorkspaceFocusTarget?>.Binding,
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>,
        depthLimit: Int,
        layoutID: String,
        discardPileRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onSegmentClick: @escaping () -> Void,
        onNavigateToParent: @escaping () -> Void,
        onDiscardPileDragActiveChange: @escaping (Bool) -> Void,
        chartModel: @autoclosure @escaping () -> SunburstChartModel = SunburstChartModel()
    ) {
        self.rootNode = rootNode
        self.parentNode = parentNode
        self.treeStore = treeStore
        self.snapshotID = snapshotID
        self.activeTarget = activeTarget
        self.trashSafetyPolicy = trashSafetyPolicy
        self.snapshotSource = snapshotSource
        self._focusedWorkspaceTarget = focusedWorkspaceTarget
        self.selectedNodeID = selectedNodeID
        self.selectedAncestorIDs = selectedAncestorIDs
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.discardPileRootNodeIDs = discardPileRootNodeIDs
        self.movingToTrashRootNodeIDs = movingToTrashRootNodeIDs
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onSegmentClick = onSegmentClick
        self.onNavigateToParent = onNavigateToParent
        self.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
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
        guard layoutPresentationState.canUseRenderedLayout else { return nil }
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }

        if let hoveredNodeID = hoveredSegment.nodeID,
           let hoveredNode = treeStore.node(id: hoveredNodeID) {
            return summary(
                for: hoveredNode,
                status: discardPileOverlay.role(for: hoveredNodeID)?.statusText
            )
        }

        return ChartSummary(
            status: discardPileOverlay.role(
                for: nil,
                aggregateContainerNodeID: hoveredSegment.containerNodeID
            )?.statusText ?? String(
                localized: "Grouped Items",
                comment: "Chart status for several small items grouped into one segment."
            ),
            title: hoveredSegment.label,
            value: RadixFormatters.size(hoveredSegment.totalSize),
            detail: String(localized: "Too small to show individually", comment: "Chart detail explaining why grouped items are combined.")
        )
    }

    private var discardPileOverlay: DiscardPileVisualizationOverlay {
        chartModel.discardPileOverlay(
            queuedRootNodeIDs: discardPileRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
            treeStore: treeStore
        )
    }

    private var canAdjustViewport: Bool {
        layoutPresentationState.canUseRenderedLayout
            && !chartModel.renderedSegments.isEmpty
    }

    private var layoutPresentationState: ChartLayoutPresentationState {
        ChartLayoutPresentationState(
            readiness: chartModel.layoutReadiness,
            layoutID: layoutRequestID
        )
    }

    private var layoutRequestID: String {
        "\(layoutID)|retry:\(layoutRetryGeneration)"
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)
            let chartFrame = viewport.transform.frame(for: baseChartFrame)
            let layoutTaskID = SunburstLayoutTaskID(
                layoutID: layoutID,
                retryGeneration: layoutRetryGeneration
            )
            let layoutPresentation = layoutPresentationState
            let canAdjustViewport = self.canAdjustViewport
            ZStack {
                SunburstRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectionSegments: chartModel.selectionOverlaySegments(
                        selectedNodeID: selectedNodeID,
                        selectedAncestorIDs: selectedAncestorIDs
                    ),
                    discardPileOverlay: discardPileOverlay,
                    chartFrame: chartFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                SunburstHoverOverlay(
                    segment: layoutPresentation.canUseRenderedLayout
                        && discardPileOverlay.allowsChartNodeAction(
                            for: chartModel.hoveredSegment?.nodeID
                        )
                        ? chartModel.hoveredSegment
                        : nil
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)

                if parentNode != nil,
                   isHoveringCenter,
                   layoutPresentation.canUseRenderedLayout,
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

                ChartLoadingOverlay(
                    presentation: layoutPresentation,
                    showsEmptyProgress: chartModel.layoutReadiness.failure == nil
                        && chartModel.renderedSegments.isEmpty,
                    requestID: layoutTaskID
                )
            }
            .contentShape(Rectangle())
            .overlay {
                SunburstInteractionOverlay(
                    onHover: { location in
                        guard layoutPresentation.canUseRenderedLayout else { return }
                        updateHover(at: location, in: baseChartFrame)
                    },
                    onClick: { location, clickCount in
                        guard layoutPresentation.canUseRenderedLayout else { return }
                        handleClick(
                            at: location,
                            in: baseChartFrame,
                            clickCount: clickCount,
                            discardPileOverlay: discardPileOverlay
                        )
                    },
                    onMove: { direction in
                        guard layoutPresentation.canUseRenderedLayout else { return false }
                        return handleSpatialMove(
                            direction,
                            in: baseChartFrame
                        )
                    },
                    onKeyboardFocus: {
                        focusedWorkspaceTarget = .chart
                    },
                    isKeyboardFocused: focusedWorkspaceTarget == .chart,
                    onPan: { delta, location in
                        let nextTransform = panViewport(
                            by: delta,
                            in: baseChartFrame
                        )
                        updateHover(
                            at: location,
                            in: baseChartFrame,
                            using: nextTransform
                        )
                    },
                    onMagnify: { location, factor in
                        let nextTransform = zoomViewport(
                            by: factor,
                            anchor: location,
                            in: baseChartFrame
                        )
                        updateHover(
                            at: location,
                            in: baseChartFrame,
                            using: nextTransform
                        )
                    },
                    canStartPan: { location in
                        canStartPan(at: location, in: baseChartFrame)
                    },
                    discardPileDragItem: { location in
                        discardPileDragItem(
                            at: location,
                            in: baseChartFrame,
                            discardPileOverlay: discardPileOverlay
                        )
                    },
                    onDiscardPileDragActiveChange: onDiscardPileDragActiveChange,
                    help: { location in
                        guard layoutPresentation.canUseRenderedLayout else { return nil }
                        return help(at: location, in: baseChartFrame)
                    },
                    isPanEnabled: canAdjustViewport && viewport.transform.isZoomed
                )
                .accessibilityHidden(true)
                .allowsHitTesting(layoutPresentation.canUseRenderedLayout)

            }
            .overlay {
                Color.clear
                    .frame(width: chartFrame.width, height: chartFrame.height)
                    .workspaceTourAnchor(.diskMap)
                    .position(x: chartFrame.midX, y: chartFrame.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: String(localized: "Zoom In", comment: "Accessibility action for zooming into the disk map.")) {
                handleViewportAction(.zoomIn, in: baseChartFrame)
            }
            .accessibilityAction(named: String(localized: "Zoom Out", comment: "Accessibility action for zooming out of the disk map.")) {
                handleViewportAction(.zoomOut, in: baseChartFrame)
            }
            .accessibilityAction(named: String(localized: "Reset Zoom", comment: "Accessibility action for resetting the disk map zoom.")) {
                handleViewportAction(.reset, in: baseChartFrame)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focusedWorkspaceTarget, equals: .chart)
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
                    ChartViewportControls(transform: viewport.transform) { action in
                        handleViewportAction(action, in: baseChartFrame)
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 18)
                }
            }
            .overlay(alignment: .bottom) {
                if let layoutError = chartModel.layoutReadiness.failure,
                   layoutPresentation.showsFailure {
                    ChartLayoutFailureBanner(failure: layoutError) {
                        layoutRetryGeneration += 1
                    }
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
            .animation(centerHoverAnimation, value: isHoveringCenter)
            .onChange(of: baseChartFrame) { _, nextFrame in
                viewport.setTransform(viewport.transform.constrained(to: nextFrame))
            }
            .onChange(of: layoutID, initial: true) { _, _ in
                viewport.reset(for: layoutID)
            }
            .focusedSceneValue(\.chartViewportAction) { action in
                handleViewportAction(action, in: baseChartFrame)
            }
            .task(id: layoutTaskID) {
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    layoutID: layoutRequestID
                )
            }
        }
    }

    private func handleSpatialMove(
        _ direction: ChartSpatialSelectionDirection,
        in baseChartFrame: CGRect
    ) -> Bool {
        guard layoutPresentationState.canUseRenderedLayout,
              let segment = chartModel.keyboardSelection(
            from: selectedNodeID,
            moving: direction,
            excludingMovingToTrashNodeIDs: discardPileOverlay.movingToTrashNodeIDs
        ), let nodeID = segment.nodeID else {
            return false
        }

        let transformedFrame = viewport.transform.frame(for: baseChartFrame)
        let point = chartModel.keyboardSelectionPoint(for: segment, in: transformedFrame)
        viewport.setTransform(viewport.transform.revealing(
            point: point,
            within: baseChartFrame,
            padding: 12
        ))
        isHoveringCenter = false
        chartModel.setHoveredSegmentID(nil)
        onSelect(nodeID)
        return true
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

    private func updateHover(
        at location: CGPoint?,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) {
        guard let location else {
            isHoveringCenter = false
            chartModel.setHoveredSegmentID(nil)
            return
        }

        let transform = transform ?? viewport.transform
        if parentNode != nil,
           isCenterHit(at: location, in: frame, using: transform) {
            isHoveringCenter = true
            chartModel.setHoveredSegmentID(nil)
            return
        }

        isHoveringCenter = false
        let nextSegment = hitTest(at: location, in: frame, using: transform)
        chartModel.setHoveredSegmentID(nextSegment?.id)
    }

    private func handleClick(
        at location: CGPoint,
        in frame: CGRect,
        clickCount: Int,
        discardPileOverlay: DiscardPileVisualizationOverlay
    ) {
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

        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
            if clickCount == 1 {
                onSelect(nil)
            }
            return
        }

        if discardPileOverlay.isMovingToTrash(nodeID) {
            return
        }

        if discardPileOverlay.isQueued(nodeID) {
            onSegmentClick()
            onSelect(nodeID)
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
        if let hoverSummary {
            return hoverSummary.accessibilityDescription
        }

        let node = displayedNode ?? rootNode
        let status = discardPileOverlay.role(for: node.id)?.statusText
            ?? summaryStatus(for: node)
        return String(localized: "\(node.displayName), \(RadixFormatters.size(node.allocatedSize)), \(status)", comment: "Accessibility value describing the selected sunburst segment.")
    }

    private var accessibilityHint: String {
        if parentNode != nil {
            return String(localized: "Click a segment or use the arrow keys to select it. Double-click a folder or press Command-Down Arrow to zoom in. Click the center or press Command-Up Arrow to go up.", comment: "Accessibility hint for the sunburst chart when navigating upward is available.")
        }

        return String(localized: "Click a segment or use the arrow keys to select it. Double-click a folder or press Command-Down Arrow to zoom in.", comment: "Accessibility hint for the sunburst chart.")
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

    private func hitTest(
        at location: CGPoint,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) -> SunburstSegment? {
        let transform = transform ?? viewport.transform
        guard let chartPoint = transform.localChartPoint(for: location, in: frame) else {
            return nil
        }

        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func canStartPan(at location: CGPoint, in frame: CGRect) -> Bool {
        !isCenterHit(at: location, in: frame) && hitTest(at: location, in: frame) == nil
    }

    private func discardPileDragItem(
        at location: CGPoint,
        in frame: CGRect,
        discardPileOverlay: DiscardPileVisualizationOverlay
    ) -> SunburstDiscardPileDragItem? {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID,
              discardPileOverlay.allowsChartNodeAction(for: nodeID),
              !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
              let node = treeStore.node(id: nodeID),
              canDragToDiscardPile(node) else {
            return nil
        }

        return SunburstDiscardPileDragItem(
            payload: DiscardPileDragPayload(
                snapshotID: snapshotID,
                nodeIDs: [nodeID]
            ),
            segment: segment
        )
    }

    private func canDragToDiscardPile(_ node: FileNodeRecord) -> Bool {
        FileNodeActionAvailability(
            node: node,
            activeTarget: activeTarget,
            trashSafetyPolicy: trashSafetyPolicy,
            snapshotSource: snapshotSource
        ).canMoveToTrash
    }

    private func isCenterHit(
        at location: CGPoint,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) -> Bool {
        let transform = transform ?? viewport.transform
        guard let chartPoint = transform.localChartPoint(for: location, in: frame) else {
            return false
        }

        return SunburstCenterHitTester.contains(
            point: chartPoint.point,
            in: chartPoint.size
        )
    }

    private func help(at location: CGPoint, in frame: CGRect) -> String? {
        guard let parentNode, isCenterHit(at: location, in: frame) else { return nil }
        return String(localized: "Go up to \(parentNode.name)", comment: "Tooltip for the sunburst chart center navigation affordance.")
    }

    private func summary(for node: FileNodeRecord, status: String? = nil) -> ChartSummary {
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return ChartSummary(
                status: summaryStatus(for: node),
                title: node.displayName,
                value: RadixFormatters.size(node.allocatedSize),
                detail: String(localized: "APFS available capacity", comment: "Chart detail describing free space on an APFS volume.")
            )
        }

        let detail: String
        if node.id != rootNode.id,
           let percentText = RadixFormatters.percentage(part: node.allocatedSize, total: rootNode.allocatedSize) {
            detail = String(localized: "\(percentText) of current focus", comment: "Chart detail showing an item's percentage of the current focus.")
        } else {
            detail = node.itemKind(activeTarget: activeTarget)
        }

        return ChartSummary(
            status: status ?? node.itemKind(activeTarget: activeTarget),
            title: node.displayName,
            value: RadixFormatters.size(node.allocatedSize),
            detail: detail
        )
    }

    private func summaryStatus(for node: FileNodeRecord) -> String {
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id) {
            return String(localized: "Available Space", comment: "Chart status for free capacity on a volume.")
        }
        return node.itemKind(activeTarget: activeTarget)
    }

    @discardableResult
    private func zoomViewport(
        by factor: CGFloat,
        anchor: CGPoint,
        in baseFrame: CGRect
    ) -> ChartViewportTransform {
        guard canAdjustViewport else { return viewport.transform }

        let nextTransform = viewport.transform.zoomed(
            by: factor,
            anchor: anchor,
            in: baseFrame
        )
        viewport.setTransform(nextTransform)
        return nextTransform
    }

    @discardableResult
    private func panViewport(
        by delta: CGSize,
        in baseFrame: CGRect
    ) -> ChartViewportTransform {
        guard canAdjustViewport else { return viewport.transform }

        let nextTransform = viewport.transform.panned(by: delta, in: baseFrame)
        viewport.setTransform(nextTransform, animated: false)
        return nextTransform
    }

    private func handleViewportAction(
        _ action: ChartViewportAction,
        in baseFrame: CGRect
    ) {
        viewport.perform(
            action,
            in: baseFrame,
            canZoom: canAdjustViewport
        )
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

private struct SunburstLayoutTaskID: Hashable {
    let layoutID: String
    let retryGeneration: Int
}

private struct SunburstRenderedChartLayer: View {
    let segments: [SunburstSegment]
    let renderVersion: Int
    let selectionSegments: [SunburstSelectionOverlaySegment]
    let discardPileOverlay: DiscardPileVisualizationOverlay
    let chartFrame: CGRect

    var body: some View {
        ZStack {
            SunburstBaseCanvas(
                segments: segments,
                renderVersion: renderVersion
            )
            .equatable()

            SunburstDiscardPileOverlay(
                segments: segments,
                renderVersion: renderVersion,
                overlay: discardPileOverlay
            )
            .equatable()
            .allowsHitTesting(false)

            SunburstSelectionOverlay(segments: selectionSegments)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
