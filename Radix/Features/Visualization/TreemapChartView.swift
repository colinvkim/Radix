import SwiftUI

struct TreemapChartView: View {
    private static let chartPadding: CGFloat = 18
    private static let viewportControlsAvoidanceSize = CGSize(width: 160, height: 56)
    /// The tooltip sizes itself vertically. This maximum keeps edge placement safe
    /// when a long name wraps onto its second line.
    private static let tooltipMaximumSize = CGSize(width: 272, height: 122)

    let rootNode: FileNodeRecord
    let treeStore: DiskMapTreeStore
    let snapshotID: UUID
    let activeTarget: ScanTarget?
    let trashSafetyPolicy: TrashSafetyPolicy
    let snapshotSource: ScanSnapshotSource
    @FocusState.Binding var focusedWorkspaceTarget: WorkspaceFocusTarget?
    let selectedNodeID: String?
    let depthLimit: Int
    let layoutID: String
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>
    let onSelect: (String?) -> Void
    let onZoom: (String) -> Void
    let onDiscardPileDragActiveChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chartModel: TreemapChartModel
    @State private var tooltipAnchor: CGPoint?
    private var viewport = ChartViewportState()
    @State private var layoutRetryGeneration = 0

    init(
        rootNode: FileNodeRecord,
        treeStore: DiskMapTreeStore,
        snapshotID: UUID,
        activeTarget: ScanTarget?,
        trashSafetyPolicy: TrashSafetyPolicy,
        snapshotSource: ScanSnapshotSource,
        focusedWorkspaceTarget: FocusState<WorkspaceFocusTarget?>.Binding,
        selectedNodeID: String?,
        depthLimit: Int,
        layoutID: String,
        discardPileRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>,
        onSelect: @escaping (String?) -> Void,
        onZoom: @escaping (String) -> Void,
        onDiscardPileDragActiveChange: @escaping (Bool) -> Void,
        chartModel: @autoclosure @escaping () -> TreemapChartModel = TreemapChartModel()
    ) {
        self.rootNode = rootNode
        self.treeStore = treeStore
        self.snapshotID = snapshotID
        self.activeTarget = activeTarget
        self.trashSafetyPolicy = trashSafetyPolicy
        self.snapshotSource = snapshotSource
        self._focusedWorkspaceTarget = focusedWorkspaceTarget
        self.selectedNodeID = selectedNodeID
        self.depthLimit = depthLimit
        self.layoutID = layoutID
        self.discardPileRootNodeIDs = discardPileRootNodeIDs
        self.movingToTrashRootNodeIDs = movingToTrashRootNodeIDs
        self.onSelect = onSelect
        self.onZoom = onZoom
        self.onDiscardPileDragActiveChange = onDiscardPileDragActiveChange
        _chartModel = StateObject(wrappedValue: chartModel())
    }

    private var displayedNode: FileNodeRecord {
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

    private var tooltipContent: TreemapTooltipContent? {
        guard let hoveredSegment = chartModel.hoveredSegment else { return nil }
        return TreemapTooltipContent.content(
            for: hoveredSegment,
            rootNode: rootNode,
            treeStore: treeStore,
            discardPileRole: discardPileOverlay.role(
                for: hoveredSegment.nodeID,
                aggregateContainerNodeID: hoveredSegment.isAggregate
                    ? hoveredSegment.containerNodeID
                    : nil
            )
        )
    }

    private var discardPileOverlay: DiscardPileVisualizationOverlay {
        chartModel.discardPileOverlay(
            queuedRootNodeIDs: discardPileRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
            treeStore: treeStore
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)
            let viewportContentFrame = viewportContentFrame(in: baseChartFrame)
            let layoutTaskID = TreemapLayoutTaskID(
                layoutID: layoutID,
                size: baseChartFrame.size,
                retryGeneration: layoutRetryGeneration
            )
            let layoutPresentation = layoutPresentationState
            let canAdjustViewport = layoutPresentation.canUseRenderedLayout
                && !chartModel.renderedSegments.isEmpty
            ZStack {
                TreemapRenderedChartLayer(
                    segments: chartModel.renderedSegments,
                    renderVersion: chartModel.renderedLayoutVersion,
                    selectedSegment: chartModel.selectedSegment(nodeID: selectedNodeID),
                    hoveredSegment: layoutPresentation.canUseRenderedLayout
                        ? chartModel.hoveredSegment
                        : nil,
                    discardPileOverlay: discardPileOverlay,
                    chartFrame: baseChartFrame,
                    contentFrame: viewportContentFrame
                )
                .id(chartModel.renderedLayoutVersion)
                .transition(chartTransition)
                .allowsHitTesting(false)

                ChartLoadingOverlay(
                    presentation: layoutPresentation,
                    showsEmptyProgress: chartModel.layoutReadiness.failure == nil
                        && chartModel.renderedSegments.isEmpty,
                    requestID: layoutTaskID
                )
            }
            .contentShape(Rectangle())
            .overlay {
                TreemapInteractionOverlay(
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
                            in: baseChartFrame.size
                        )
                    },
                    onKeyboardFocus: {
                        focusedWorkspaceTarget = .chart
                    },
                    isKeyboardFocused: focusedWorkspaceTarget == .chart,
                    onPan: { delta, location in
                        panViewport(
                            by: delta,
                            pointer: location,
                            in: baseChartFrame
                        )
                    },
                    onMagnify: { location, factor in
                        zoomViewport(
                            by: factor,
                            anchor: location,
                            in: baseChartFrame
                        )
                    },
                    canStartPan: { location in
                        discardPileDragItem(
                            at: location,
                            in: baseChartFrame,
                            discardPileOverlay: discardPileOverlay
                        ) == nil
                    },
                    discardPileDragItem: { location in
                        discardPileDragItem(
                            at: location,
                            in: baseChartFrame,
                            discardPileOverlay: discardPileOverlay
                        )
                    },
                    onDiscardPileDragActiveChange: onDiscardPileDragActiveChange,
                    isPanEnabled: canAdjustViewport && viewport.transform.isZoomed
                )
                .accessibilityHidden(true)
                .allowsHitTesting(layoutPresentation.canUseRenderedLayout)

            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap disk usage chart")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Click a tile or use the arrow keys to select it. Double-click a folder or press Command-Down Arrow to zoom in. Use the breadcrumb or press Command-Up Arrow to go up.")
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
                if layoutPresentation.canUseRenderedLayout,
                   let tooltipContent,
                   let tooltipAnchor {
                    TreemapHoverTooltip(content: tooltipContent)
                        .frame(width: Self.tooltipMaximumSize.width)
                        .offset(
                            tooltipOrigin(
                                at: tooltipAnchor,
                                in: geometry.size,
                                avoidingViewportControls: canAdjustViewport
                            )
                        )
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
            .onChange(of: baseChartFrame) { _, nextFrame in
                viewport.setTransform(
                    viewport.transform.constrained(
                        to: localViewportFrame(in: nextFrame.size)
                    ),
                    animated: false
                )
                clearHover()
            }
            .onChange(of: layoutID, initial: true) { _, _ in
                if viewport.reset(for: layoutID) {
                    clearHover()
                }
            }
            .focusedSceneValue(\.chartViewportAction) { action in
                handleViewportAction(action, in: baseChartFrame)
            }
            .task(id: layoutTaskID) {
                await chartModel.loadLayout(
                    treeStore: treeStore,
                    rootID: rootNode.id,
                    depthLimit: depthLimit,
                    size: baseChartFrame.size,
                    layoutID: layoutRequestID
                )
            }
        }
    }

    private func handleSpatialMove(
        _ direction: ChartSpatialSelectionDirection,
        in size: CGSize
    ) -> Bool {
        guard layoutPresentationState.canUseRenderedLayout,
              let nodeID = chartModel.spatialSelectionNodeID(
            from: selectedNodeID,
            moving: direction,
            in: size,
            excludingMovingToTrashNodeIDs: discardPileOverlay.movingToTrashNodeIDs
        ) else {
            return false
        }

        if let selectedSegment = chartModel.selectedSegment(nodeID: nodeID) {
            let transformedContentFrame = viewport.transform.frame(
                for: localViewportFrame(in: size)
            )
            let navigationRect = TreemapRenderer.navigationRect(
                for: selectedSegment,
                in: transformedContentFrame
            )
            let selectionPoint = CGPoint(
                x: navigationRect.midX,
                y: navigationRect.midY
            )
            viewport.setTransform(
                viewport.transform.revealing(
                    point: selectionPoint,
                    within: localViewportFrame(in: size),
                    padding: 12
                ),
                animated: false
            )
        }
        clearHover()
        onSelect(nodeID)
        return true
    }

    private var chartTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.992, anchor: .center))
    }

    private var chartTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.22)
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

    private var accessibilityValue: String {
        if let tooltipContent {
            return tooltipContent.accessibilityDescription
        }

        let status = discardPileOverlay.role(for: displayedNode.id)?.statusText
            ?? summaryStatus(for: displayedNode)
        return String(localized: "\(displayedNode.name), \(RadixFormatters.size(displayedNode.allocatedSize)), \(status)", comment: "Accessibility value describing the selected treemap tile.")
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        return CGRect(
            x: inset,
            y: inset,
            width: max(size.width - (inset * 2), 1),
            height: max(size.height - (inset * 2), 1)
        )
    }

    private func viewportContentFrame(in baseChartFrame: CGRect) -> CGRect {
        viewport.transform.frame(
            for: localViewportFrame(in: baseChartFrame.size)
        )
    }

    private func localViewportFrame(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    private func localViewportPoint(
        for location: CGPoint,
        in frame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: location.x - frame.minX,
            y: location.y - frame.minY
        )
    }

    private func updateHover(
        at location: CGPoint?,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) {
        guard let location,
              let segment = hitTest(
                at: location,
                in: frame,
                using: transform
              ) else {
            clearHover()
            return
        }

        tooltipAnchor = location
        chartModel.setHoveredSegmentID(segment.id)
    }

    private func tooltipOrigin(
        at location: CGPoint,
        in size: CGSize,
        avoidingViewportControls: Bool
    ) -> CGSize {
        let controlsFrame: CGRect?
        if avoidingViewportControls {
            controlsFrame = CGRect(
                x: max(size.width - Self.viewportControlsAvoidanceSize.width, 0),
                y: 0,
                width: min(Self.viewportControlsAvoidanceSize.width, size.width),
                height: min(Self.viewportControlsAvoidanceSize.height, size.height)
            )
        } else {
            controlsFrame = nil
        }
        let origin = TreemapTooltipPlacement.origin(
            for: location,
            tooltipSize: Self.tooltipMaximumSize,
            in: CGRect(origin: .zero, size: size),
            avoiding: controlsFrame
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private func handleClick(
        at location: CGPoint,
        in frame: CGRect,
        clickCount: Int,
        discardPileOverlay: DiscardPileVisualizationOverlay
    ) {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID else {
            if clickCount == 1 { onSelect(nil) }
            return
        }
        if DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) {
            if clickCount == 1 { onSelect(nil) }
            return
        }

        if discardPileOverlay.isMovingToTrash(nodeID) {
            return
        }

        if discardPileOverlay.isQueued(nodeID) {
            onSelect(nodeID)
            return
        }

        if clickCount >= 2,
           treeStore.node(id: nodeID)?.isDirectory == true {
            onZoom(nodeID)
        } else {
            onSelect(nodeID)
        }
    }

    private func hitTest(
        at location: CGPoint,
        in frame: CGRect,
        using transform: ChartViewportTransform? = nil
    ) -> TreemapSegment? {
        guard frame.contains(location) else { return nil }
        let transform = transform ?? viewport.transform
        guard let chartPoint = transform.localChartPoint(
            for: localViewportPoint(for: location, in: frame),
            in: localViewportFrame(in: frame.size)
        ) else {
            return nil
        }
        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func discardPileDragItem(
        at location: CGPoint,
        in frame: CGRect,
        discardPileOverlay: DiscardPileVisualizationOverlay
    ) -> TreemapDiscardPileDragItem? {
        guard let segment = hitTest(at: location, in: frame),
              let nodeID = segment.nodeID,
              discardPileOverlay.allowsChartNodeAction(for: nodeID),
              !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID),
              let node = treeStore.node(id: nodeID),
              canDragToDiscardPile(node) else {
            return nil
        }

        return TreemapDiscardPileDragItem(
            payload: DiscardPileDragPayload(snapshotID: snapshotID, nodeIDs: [nodeID]),
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

    private func summaryStatus(for node: FileNodeRecord) -> String {
        DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(node.id)
            ? String(localized: "Available Space", comment: "Chart status for free capacity on a volume.")
            : node.itemKind(activeTarget: activeTarget)
    }

    private func zoomViewport(
        by factor: CGFloat,
        anchor: CGPoint,
        in baseFrame: CGRect
    ) {
        guard layoutPresentationState.canUseRenderedLayout,
              !chartModel.renderedSegments.isEmpty else {
            return
        }

        let localFrame = localViewportFrame(in: baseFrame.size)
        let localAnchor = localViewportPoint(for: anchor, in: baseFrame)
        let nextTransform = viewport.transform.zoomed(
            by: factor,
            anchor: localAnchor,
            in: localFrame
        )
        viewport.setTransform(nextTransform)

        updateHover(
            at: anchor,
            in: baseFrame,
            using: nextTransform
        )
    }

    private func panViewport(
        by delta: CGSize,
        pointer: CGPoint,
        in baseFrame: CGRect
    ) {
        guard layoutPresentationState.canUseRenderedLayout,
              !chartModel.renderedSegments.isEmpty else {
            return
        }

        let nextTransform = viewport.transform.panned(
            by: delta,
            in: localViewportFrame(in: baseFrame.size)
        )
        viewport.setTransform(nextTransform, animated: false)
        updateHover(
            at: pointer,
            in: baseFrame,
            using: nextTransform
        )
    }

    private func handleViewportAction(
        _ action: ChartViewportAction,
        in baseFrame: CGRect
    ) {
        if viewport.perform(
            action,
            in: localViewportFrame(in: baseFrame.size),
            canZoom: layoutPresentationState.canUseRenderedLayout && !chartModel.renderedSegments.isEmpty
        ) {
            clearHover()
        }
    }

    private func clearHover() {
        tooltipAnchor = nil
        chartModel.setHoveredSegmentID(nil)
    }
}

private struct TreemapHoverTooltip: View {
    private static let iconColumnWidth: CGFloat = 18

    let content: TreemapTooltipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let status = content.status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: content.systemImageName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth)

                Text(content.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            tooltipTextRow {
                Text(content.sizeAndSignificance)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                        .frame(width: Self.iconColumnWidth)

                    Text(content.location)
                        .truncationMode(.middle)
                }

                tooltipTextRow {
                    Text(content.metadata)
                }
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.76))
            .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
    }

    private func tooltipTextRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Color.clear
                .frame(width: Self.iconColumnWidth, height: 0)
                .accessibilityHidden(true)
            content()
        }
    }
}

private struct TreemapLayoutTaskID: Hashable {
    private nonisolated static let sizeBucket: CGFloat = 24

    let layoutID: String
    let widthBucket: Int
    let heightBucket: Int
    let retryGeneration: Int

    init(
        layoutID: String,
        size: CGSize,
        retryGeneration: Int
    ) {
        self.layoutID = layoutID
        widthBucket = Int((size.width / Self.sizeBucket).rounded())
        heightBucket = Int((size.height / Self.sizeBucket).rounded())
        self.retryGeneration = retryGeneration
    }
}

private struct TreemapRenderedChartLayer: View {
    let segments: [TreemapSegment]
    let renderVersion: Int
    let selectedSegment: TreemapSegment?
    let hoveredSegment: TreemapSegment?
    let discardPileOverlay: DiscardPileVisualizationOverlay
    let chartFrame: CGRect
    let contentFrame: CGRect

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TreemapBaseCanvas(
                segments: segments,
                renderVersion: renderVersion,
                colorScheme: colorScheme,
                contentFrame: contentFrame
            )
                .equatable()

            TreemapHoverOverlay(
                segment: hoveredSegment,
                colorScheme: colorScheme,
                contentFrame: contentFrame
            )
                .equatable()
                .allowsHitTesting(false)

            TreemapLabelCanvas(
                segments: segments,
                renderVersion: renderVersion,
                colorScheme: colorScheme,
                contentFrame: contentFrame
            )
                .equatable()
                .allowsHitTesting(false)

            TreemapDiscardPileOverlay(
                segments: segments,
                renderVersion: renderVersion,
                overlay: discardPileOverlay,
                contentFrame: contentFrame
            )
                .equatable()
                .allowsHitTesting(false)

            TreemapSelectionOverlay(
                segment: selectedSegment,
                contentFrame: contentFrame
            )
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
