import Combine
import CoreGraphics
import Foundation
import SwiftUI

nonisolated protocol SunburstLayouting: Sendable {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment]
}

actor SunburstLayoutService: SunburstLayouting {
    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        try SunburstLayout.segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            cancellationCheck: Task.checkCancellation
        )
    }
}

@MainActor
final class SunburstChartModel: ObservableObject {
    @Published private var renderState = SunburstChartRenderState()
    @Published private(set) var layoutReadiness = ChartLayoutReadiness()

    private let layoutService: any SunburstLayouting
    private let layoutRequests = ChartLayoutRequestCoordinator<[SunburstSegment]>()
    private var selectionIndex = SunburstSelectionIndex(
        segmentIndex: SunburstSegmentIndex(segments: [])
    )
    private var selectionOverlayCache: SunburstSelectionOverlayCacheEntry?
    private var discardPileOverlayCache = DiscardPileVisualizationOverlayCache()

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
    }

    var renderedColors: [Color] { renderState.colors }

    var renderedSegments: [SunburstSegment] {
        renderState.segments
    }

    var hoveredSegmentID: SunburstSegment.ID? {
        renderState.hoveredSegmentID
    }

    var hoveredSegment: SunburstSegment? {
        renderState.hoveredSegment
    }

    var renderedLayoutVersion: Int {
        renderState.version
    }

    func setHoveredSegmentID(_ segmentID: SunburstSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        renderState.segment(at: point, in: size)
    }

    func keyboardSelection(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        excludingMovingToTrashNodeIDs: Set<FileNodeRecord.ID> = []
    ) -> SunburstSegment? {
        selectionIndex.keyboardSelection(
            from: selectedNodeID,
            moving: direction,
            excluding: excludingMovingToTrashNodeIDs
        )
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

    func keyboardSelectionPoint(
        for segment: SunburstSegment,
        in frame: CGRect
    ) -> CGPoint {
        let angle = ((segment.startAngle.radians + segment.endAngle.radians) / 2)
            - (.pi / 2)
        let normalizedRadius = (segment.innerRadius + segment.outerRadius) / 2
        let radius = min(frame.width, frame.height) / 2
        return CGPoint(
            x: frame.midX + (cos(angle) * normalizedRadius * radius),
            y: frame.midY + (sin(angle) * normalizedRadius * radius)
        )
    }

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        let key = SunburstSelectionOverlayCacheKey(
            selectedNodeID: selectedNodeID,
            selectedAncestorIDs: selectedAncestorIDs
        )
        if let selectionOverlayCache,
           selectionOverlayCache.key == key {
            return selectionOverlayCache.segments
        }

        let segments = selectionIndex.selectionOverlaySegments(
            selectedNodeID: selectedNodeID,
            selectedAncestorIDs: selectedAncestorIDs
        )
        selectionOverlayCache = SunburstSelectionOverlayCacheEntry(
            key: key,
            segments: segments
        )
        return segments
    }

    @discardableResult
    func loadLayout(
        treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int,
        layoutID: String
    ) async -> Bool {
        let request = layoutRequests.start(layoutID: layoutID) { [layoutService] in
            try await layoutService.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit
            )
        }
        clearHover()
        layoutReadiness.start()

        switch await layoutRequests.outcome(for: request) {
        case let .success(segments):
            apply(segments)
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

    private func apply(_ segments: [SunburstSegment]) {
        let segmentIndex = SunburstSegmentIndex(segments: segments)
        let nextSelectionIndex = SunburstSelectionIndex(
            segmentIndex: segmentIndex
        )
        let nextRenderState = SunburstChartRenderState(
            segments: segments,
            version: renderState.version + 1,
            segmentIndex: segmentIndex
        )
        renderState = nextRenderState
        selectionIndex = nextSelectionIndex
        selectionOverlayCache = nil
    }

    private func clearHover() {
        guard hoveredSegmentID != nil else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = nil
        renderState = nextState
    }
}

private struct SunburstSelectionOverlayCacheKey: Equatable {
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
}

private struct SunburstSelectionOverlayCacheEntry {
    let key: SunburstSelectionOverlayCacheKey
    let segments: [SunburstSelectionOverlaySegment]
}

enum SunburstSelectionRole: Equatable, Sendable {
    case ancestor
    case selected
}

struct SunburstSelectionOverlaySegment: Identifiable, Equatable, Sendable {
    let segment: SunburstSegment
    let role: SunburstSelectionRole

    var id: SunburstSegment.ID {
        segment.id
    }
}

private struct SunburstChartRenderState {
    let segments: [SunburstSegment]
    let colors: [Color]
    var hoveredSegmentID: SunburstSegment.ID?
    let version: Int

    private let segmentIndex: SunburstSegmentIndex
    private let hitTestIndex: SunburstHitTestIndex

    init(
        segments: [SunburstSegment] = [],
        hoveredSegmentID: SunburstSegment.ID? = nil,
        version: Int = 0,
        segmentIndex: SunburstSegmentIndex? = nil
    ) {
        self.segments = segments
        colors = segments.map { SunburstColorResolver.color(for: $0.colorToken) }
        self.hoveredSegmentID = hoveredSegmentID
        self.version = version
        let segmentIndex = segmentIndex ?? SunburstSegmentIndex(segments: segments)
        self.segmentIndex = segmentIndex
        hitTestIndex = SunburstHitTestIndex(segmentIndex: segmentIndex)
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentIndex.segment(id: hoveredSegmentID)
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        hitTestIndex.segment(at: point, in: size)
    }
}

private struct SunburstSelectionIndex {
    private struct Location {
        let depth: Int
        let index: Int
    }

    private let segmentIndex: SunburstSegmentIndex
    private let ringsByDepth: [Int: [SunburstSegment]]
    private let locationByNodeID: [String: Location]
    private let entrySegment: SunburstSegment?

    init(segmentIndex: SunburstSegmentIndex) {
        let depths = segmentIndex.depths
        var ringsByDepth: [Int: [SunburstSegment]] = [:]
        ringsByDepth.reserveCapacity(depths.count)
        var locationByNodeID: [String: Location] = [:]
        locationByNodeID.reserveCapacity(segmentIndex.segmentCount)
        var entrySegment: SunburstSegment?
        for depth in depths {
            let ring = segmentIndex.segments(atDepth: depth)
                .filter { segment in
                    guard let nodeID = segment.nodeID else { return false }
                    return !DiskMapFreeSpaceVisualization.isFreeSpaceNodeID(nodeID)
                }
                .sorted(by: Self.precedes)
            ringsByDepth[depth] = ring
            for (index, segment) in ring.enumerated() {
                guard let nodeID = segment.nodeID,
                      locationByNodeID[nodeID] == nil else {
                    continue
                }
                locationByNodeID[nodeID] = Location(
                    depth: depth,
                    index: index
                )
            }
            if entrySegment == nil {
                entrySegment = ring.first
            }
        }

        self.segmentIndex = segmentIndex
        self.ringsByDepth = ringsByDepth
        self.locationByNodeID = locationByNodeID
        self.entrySegment = entrySegment
    }

    func keyboardSelection(
        from selectedNodeID: String?,
        moving direction: ChartSpatialSelectionDirection,
        excluding excludedNodeIDs: Set<FileNodeRecord.ID>
    ) -> SunburstSegment? {
        guard let selectedNodeID,
              !excludedNodeIDs.contains(selectedNodeID),
              let location = locationByNodeID[selectedNodeID],
              let ring = ringsByDepth[location.depth],
              ring.indices.contains(location.index) else {
            return firstAvailableSegment(excluding: excludedNodeIDs)
        }
        let current = ring[location.index]

        switch direction {
        case .left:
            guard ring.count > 1 else { return nil }
            for offset in 1..<ring.count {
                let index = (location.index - offset + ring.count) % ring.count
                guard let nodeID = ring[index].nodeID else { continue }
                if !excludedNodeIDs.contains(nodeID) {
                    return ring[index]
                }
            }
            return nil
        case .right:
            guard ring.count > 1 else { return nil }
            for offset in 1..<ring.count {
                let index = (location.index + offset) % ring.count
                guard let nodeID = ring[index].nodeID else { continue }
                if !excludedNodeIDs.contains(nodeID) {
                    return ring[index]
                }
            }
            return nil
        case .up:
            return segment(
                atSameAngleAs: current,
                depthOffset: -1,
                excluding: excludedNodeIDs
            )
        case .down:
            return segment(
                atSameAngleAs: current,
                depthOffset: 1,
                excluding: excludedNodeIDs
            )
        }
    }

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        guard let selectedNodeID else { return [] }

        var ancestors: [(layoutIndex: Int, segment: SunburstSegment)] = []
        ancestors.reserveCapacity(selectedAncestorIDs.count)
        for nodeID in selectedAncestorIDs where nodeID != selectedNodeID {
            guard let indexedSegment = segmentIndex.indexedSegment(nodeID: nodeID) else {
                continue
            }
            ancestors.append(indexedSegment)
        }
        ancestors.sort { $0.layoutIndex < $1.layoutIndex }

        var overlaySegments: [SunburstSelectionOverlaySegment] = []
        overlaySegments.reserveCapacity(ancestors.count + 1)
        for ancestor in ancestors {
            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: ancestor.segment,
                role: .ancestor
            ))
        }

        if let selectedSegment = segmentIndex.segment(nodeID: selectedNodeID) {
            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: selectedSegment,
                role: .selected
            ))
        }

        return overlaySegments
    }

    private func segment(
        atSameAngleAs current: SunburstSegment,
        depthOffset: Int,
        excluding excludedNodeIDs: Set<FileNodeRecord.ID>
    ) -> SunburstSegment? {
        let targetDepth = current.depth + depthOffset
        guard targetDepth >= 0,
              let targetRing = ringsByDepth[targetDepth] else {
            return nil
        }
        let midpoint = (current.startAngle.radians + current.endAngle.radians) / 2
        return targetRing.first { segment in
            guard let nodeID = segment.nodeID,
                  !excludedNodeIDs.contains(nodeID) else {
                return false
            }
            let tolerance = 0.000_000_001
            return midpoint >= segment.startAngle.radians - tolerance
                && midpoint <= segment.endAngle.radians + tolerance
        }
    }

    private func firstAvailableSegment(
        excluding excludedNodeIDs: Set<FileNodeRecord.ID>
    ) -> SunburstSegment? {
        if excludedNodeIDs.isEmpty {
            return entrySegment
        }
        for depth in ringsByDepth.keys.sorted() {
            if let segment = ringsByDepth[depth]?.first(where: { segment in
                guard let nodeID = segment.nodeID else { return false }
                return !excludedNodeIDs.contains(nodeID)
            }) {
                return segment
            }
        }
        return nil
    }

    private static func precedes(
        _ lhs: SunburstSegment,
        _ rhs: SunburstSegment
    ) -> Bool {
        if lhs.startAngle.radians != rhs.startAngle.radians {
            return lhs.startAngle.radians < rhs.startAngle.radians
        }
        return lhs.id < rhs.id
    }
}
