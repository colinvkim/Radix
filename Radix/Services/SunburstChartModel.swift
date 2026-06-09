//
//  SunburstChartModel.swift
//  Radix
//

import Combine
import CoreGraphics
import Foundation

protocol SunburstLayouting: Sendable {
    func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment]
}

actor SunburstLayoutService: SunburstLayouting {
    func segments(
        in treeStore: FileTreeStore,
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
    @Published private(set) var isLayoutPending = false

    private let layoutService: any SunburstLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[SunburstSegment], Error>?
    private var selectionOverlayCache = SunburstSelectionOverlayCache(capacity: 8)

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
    }

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

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        let key = SunburstSelectionOverlayCacheKey(
            renderVersion: renderedLayoutVersion,
            selectedNodeID: selectedNodeID,
            selectedAncestorIDs: selectedAncestorIDs
        )
        return selectionOverlayCache.segments(for: key) {
            renderState.selectionOverlaySegments(
                selectedNodeID: selectedNodeID,
                selectedAncestorIDs: selectedAncestorIDs
            )
        }
    }

    @discardableResult
    func loadLayout(
        treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        layoutID: String
    ) async -> Bool {
        layoutGeneration += 1
        let generation = layoutGeneration
        activeLayoutID = layoutID
        layoutTask?.cancel()
        clearHover()
        setIsLayoutPending(true)

        let task = Task(priority: .userInitiated) { [layoutService] in
            try await layoutService.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit
            )
        }
        layoutTask = task

        do {
            let segments = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }

            layoutTask = nil
            apply(segments)
            setIsLayoutPending(false)
            return true
        } catch is CancellationError {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            setIsLayoutPending(false)
            return false
        } catch {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            apply([])
            setIsLayoutPending(false)
            return true
        }
    }

    private func isCurrentLayout(generation: Int, layoutID: String) -> Bool {
        layoutGeneration == generation && activeLayoutID == layoutID
    }

    private func apply(_ segments: [SunburstSegment]) {
        selectionOverlayCache.removeAll()
        renderState = SunburstChartRenderState(
            segments: segments,
            version: renderState.version + 1
        )
    }

    private func clearHover() {
        guard hoveredSegmentID != nil else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = nil
        renderState = nextState
    }

    private func setIsLayoutPending(_ isPending: Bool) {
        guard isLayoutPending != isPending else { return }
        isLayoutPending = isPending
    }
}

private struct SunburstSelectionOverlayCacheKey: Hashable {
    let renderVersion: Int
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
}

private struct SunburstSelectionOverlayCache {
    private let capacity: Int
    private var segmentsByKey: [SunburstSelectionOverlayCacheKey: [SunburstSelectionOverlaySegment]] = [:]
    private var keysByRecency: [SunburstSelectionOverlayCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    mutating func segments(
        for key: SunburstSelectionOverlayCacheKey,
        build: () -> [SunburstSelectionOverlaySegment]
    ) -> [SunburstSelectionOverlaySegment] {
        if let segments = segmentsByKey[key] {
            markRecentlyUsed(key)
            return segments
        }

        let segments = build()
        segmentsByKey[key] = segments
        markRecentlyUsed(key)
        trimToCapacity()
        return segments
    }

    mutating func removeAll() {
        segmentsByKey.removeAll()
        keysByRecency.removeAll()
    }

    private mutating func markRecentlyUsed(_ key: SunburstSelectionOverlayCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func trimToCapacity() {
        while segmentsByKey.count > capacity, let oldestKey = keysByRecency.first {
            keysByRecency.removeFirst()
            segmentsByKey[oldestKey] = nil
        }
    }
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
    var segments: [SunburstSegment]
    var hoveredSegmentID: SunburstSegment.ID?
    var version: Int

    private var segmentLookup: [SunburstSegment.ID: SunburstSegment]
    private var segmentByNodeID: [String: SunburstSegment]
    private var hitTestIndex: SunburstHitTestIndex

    init(
        segments: [SunburstSegment] = [],
        hoveredSegmentID: SunburstSegment.ID? = nil,
        version: Int = 0
    ) {
        self.segments = segments
        self.hoveredSegmentID = hoveredSegmentID
        self.version = version
        segmentLookup = segments.reduce(into: [:]) { lookup, segment in
            lookup[segment.id] = segment
        }
        segmentByNodeID = segments.reduce(into: [:]) { lookup, segment in
            guard let nodeID = segment.nodeID else { return }
            lookup[nodeID] = segment
        }
        hitTestIndex = SunburstHitTestIndex(segments: segments)
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        hitTestIndex.segment(at: point, in: size)
    }

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        guard let selectedNodeID else { return [] }

        var overlaySegments: [SunburstSelectionOverlaySegment] = []
        overlaySegments.reserveCapacity(selectedAncestorIDs.count)

        for segment in segments {
            guard let nodeID = segment.nodeID,
                  nodeID != selectedNodeID,
                  selectedAncestorIDs.contains(nodeID) else {
                continue
            }

            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: segment,
                role: .ancestor
            ))
        }

        if let selectedSegment = segmentByNodeID[selectedNodeID] {
            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: selectedSegment,
                role: .selected
            ))
        }

        return overlaySegments
    }
}
