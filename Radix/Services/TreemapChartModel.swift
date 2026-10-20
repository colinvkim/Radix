import Combine
import CoreGraphics
import Foundation
import SwiftUI

nonisolated protocol TreemapLayouting: Sendable {
    func layout(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> TreemapChartLayout
}

actor TreemapLayoutService: TreemapLayouting {
    func layout(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize
    ) async throws -> TreemapChartLayout {
        let segments = try TreemapLayout.segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            size: size,
            cancellationCheck: Task.checkCancellation
        )
        return try TreemapChartLayout(segments: segments)
    }
}

@MainActor
final class TreemapChartModel: ObservableObject {
    @Published private var renderState = TreemapChartRenderState()
    @Published private(set) var layoutReadiness = ChartLayoutReadiness()

    private let layoutService: any TreemapLayouting
    private let layoutRequests = ChartLayoutRequestCoordinator<TreemapChartLayout>()
    private var spatialSelectionCache = TreemapSpatialSelectionCache()
    private var discardPileOverlayCache = DiscardPileVisualizationOverlayCache()

    init(layoutService: any TreemapLayouting = TreemapLayoutService()) {
        self.layoutService = layoutService
    }

    var renderedLayout: TreemapChartLayout { renderState.layout }

    var renderedSegments: [TreemapSegment] {
        renderState.segments
    }

    var hoveredSegmentID: TreemapSegment.ID? {
        renderState.hoveredSegmentID
    }

    var hoveredSegment: TreemapSegment? {
        renderState.hoveredSegment
    }

    var renderedLayoutVersion: Int {
        renderState.version
    }

    func setHoveredSegmentID(_ segmentID: TreemapSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        renderState.segment(at: point, in: size)
    }

    func selectedSegment(nodeID: String?) -> TreemapSegment? {
        renderState.segment(nodeID: nodeID)
    }

    func discardPileOverlay(
        queuedRootNodeIDs: Set<FileNodeRecord.ID>,
        movingToTrashRootNodeIDs: Set<FileNodeRecord.ID>,
        treeStore: DiskMapTreeStore
    ) -> DiscardPileVisualizationOverlay {
        let renderedSegments = renderState.segments
        return discardPileOverlayCache.overlay(
            renderedLayoutVersion: renderState.version,
            queuedRootNodeIDs: queuedRootNodeIDs,
            movingToTrashRootNodeIDs: movingToTrashRootNodeIDs,
            treeStore: treeStore,
            renderedNodeIDs: { Set(renderedSegments.compactMap(\.nodeID)) },
            renderedAggregateContainerNodeIDs: {
                Set(renderedSegments.lazy.filter(\.isAggregate).map(\.containerNodeID))
            }
        )
    }

    func spatialSelectionNodeID(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        in size: CGSize,
        excludingMovingToTrashNodeIDs: Set<FileNodeRecord.ID> = []
    ) -> String? {
        prepareSpatialSelectionCache(for: size)
        let hasRenderedSelection = selectedNodeID.map {
            !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID($0)
                && !excludingMovingToTrashNodeIDs.contains($0)
                && renderState.segment(nodeID: $0) != nil
        } ?? false
        let baseCandidates = hasRenderedSelection
            ? spatialSelectionCache.candidates
            : spatialSelectionCache.entryCandidates
        let candidates = excludingMovingToTrashNodeIDs.isEmpty
            ? baseCandidates
            : baseCandidates.filter { !excludingMovingToTrashNodeIDs.contains($0.nodeID) }
        return ChartRectangleSpatialSelection.nextNodeID(
            from: selectedNodeID,
            moving: direction,
            among: candidates
        )
    }

    @discardableResult
    func loadLayout(
        treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        size: CGSize,
        layoutID: String
    ) async -> Bool {
        let request = layoutRequests.start(layoutID: layoutID) { [layoutService] in
            try await layoutService.layout(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                size: size
            )
        }
        clearHover()
        layoutReadiness.start()

        switch await layoutRequests.outcome(for: request) {
        case let .success(layout):
            apply(layout)
            layoutReadiness.succeed(layoutID: layoutID)
            return true
        case let .failure(error):
            layoutReadiness.fail(error, layoutID: layoutID)
            return false
        case .cancelled:
            layoutReadiness.cancel()
            return false
        case .superseded:
            return false
        }
    }

    private func apply(_ layout: TreemapChartLayout) {
        BackgroundReleaseQueue.shared.discard(renderState.layout)
        renderState = TreemapChartRenderState(
            layout: layout,
            version: renderState.version + 1
        )
        spatialSelectionCache = TreemapSpatialSelectionCache()
    }

    private func prepareSpatialSelectionCache(for size: CGSize) {
        guard spatialSelectionCache.size != size else { return }

        var candidates: [ChartRectangleSelectionCandidate] = []
        candidates.reserveCapacity(renderState.segments.count)
        var entryCandidates: [ChartRectangleSelectionCandidate] = []
        var minimumDepth: Int?

        for segment in renderState.segments {
            guard let nodeID = segment.nodeID,
                  !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID) else {
                continue
            }
            let candidate = ChartRectangleSelectionCandidate(
                nodeID: nodeID,
                frame: TreemapRenderer.navigationRect(for: segment, in: size)
            )
            candidates.append(candidate)
            if let currentMinimumDepth = minimumDepth {
                if segment.depth < currentMinimumDepth {
                    minimumDepth = segment.depth
                    entryCandidates.removeAll(keepingCapacity: true)
                    entryCandidates.append(candidate)
                } else if segment.depth == currentMinimumDepth {
                    entryCandidates.append(candidate)
                }
            } else {
                minimumDepth = segment.depth
                entryCandidates.append(candidate)
            }
        }
        spatialSelectionCache = TreemapSpatialSelectionCache(
            size: size,
            candidates: candidates,
            entryCandidates: entryCandidates
        )
    }

    private func clearHover() {
        guard hoveredSegmentID != nil else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = nil
        renderState = nextState
    }
}

private struct TreemapSpatialSelectionCache {
    var size: CGSize?
    var candidates: [ChartRectangleSelectionCandidate] = []
    var entryCandidates: [ChartRectangleSelectionCandidate] = []
}

private struct TreemapChartRenderState {
    var layout = TreemapChartLayout.empty
    var hoveredSegmentID: TreemapSegment.ID?
    var version = 0

    var segments: [TreemapSegment] { layout.segments }

    var hoveredSegment: TreemapSegment? {
        guard let hoveredSegmentID else { return nil }
        return layout.segment(id: hoveredSegmentID)
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        layout.segment(at: point, in: size)
    }

    func segment(nodeID: String?) -> TreemapSegment? {
        layout.segment(nodeID: nodeID)
    }
}

/// Immutable geometry, paint data, and lookup tables prepared by the layout actor.
/// Publishing a layout only replaces this payload; it never builds render indexes.
nonisolated struct TreemapChartLayout: Sendable {
    static let empty = TreemapChartLayout()

    let segments: [TreemapSegment]
    let paint: [TreemapSegmentPaint]
    private let indexByID: [TreemapSegment.ID: Int]
    private let indexByNodeID: [String: Int]
    private let hitTestIndex: TreemapHitTestIndex

    private init() {
        segments = []
        paint = []
        indexByID = [:]
        indexByNodeID = [:]
        hitTestIndex = TreemapHitTestIndex(segments: [])
    }

    init(
        segments: [TreemapSegment],
        cancellationCheck: () throws -> Void = Task.checkCancellation
    ) throws {
        var indexByID: [TreemapSegment.ID: Int] = [:]
        var indexByNodeID: [String: Int] = [:]
        var paint: [TreemapSegmentPaint] = []
        indexByID.reserveCapacity(segments.count)
        indexByNodeID.reserveCapacity(segments.count)
        paint.reserveCapacity(segments.count)
        var sizeLabels: [Int64: String] = [:]
        try cancellationCheck()
        for (index, segment) in segments.enumerated() {
            try cancellationCheck()
            indexByID[segment.id] = index
            if let nodeID = segment.nodeID { indexByNodeID[nodeID] = index }
            let sizeLabel: String
            if let cached = sizeLabels[segment.totalSize] {
                sizeLabel = cached
            } else {
                sizeLabel = RadixFormatters.size(segment.totalSize)
                sizeLabels[segment.totalSize] = sizeLabel
            }
            paint.append(TreemapSegmentPaint(
                lightFill: TreemapColorResolver.color(for: segment.colorToken, appearance: .light),
                darkFill: TreemapColorResolver.color(for: segment.colorToken, appearance: .dark),
                sizeLabel: sizeLabel,
                labelCharacterCount: segment.label.count
            ))
        }
        self.segments = segments
        self.paint = paint
        self.indexByID = indexByID
        self.indexByNodeID = indexByNodeID
        hitTestIndex = try TreemapHitTestIndex(segments: segments, cancellationCheck: cancellationCheck)
    }

    func segment(id: TreemapSegment.ID) -> TreemapSegment? {
        indexByID[id].map { segments[$0] }
    }

    func segment(nodeID: String?) -> TreemapSegment? {
        guard let nodeID else { return nil }
        return indexByNodeID[nodeID].map { segments[$0] }
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        hitTestIndex.segment(at: point, in: size)
    }
}

nonisolated struct TreemapSegmentPaint: Sendable {
    let lightFill: Color
    let darkFill: Color
    let sizeLabel: String
    let labelCharacterCount: Int
}
