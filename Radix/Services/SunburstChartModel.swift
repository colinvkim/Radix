//
//  SunburstChartModel.swift
//  Radix
//

import Combine
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
    private(set) var isLayoutPending = false

    private let layoutService: any SunburstLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[SunburstSegment], Error>?

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

    func setHoveredSegmentID(_ segmentID: SunburstSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
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
        renderState = SunburstChartRenderState(segments: segments)
    }

    private func setIsLayoutPending(_ isPending: Bool) {
        guard isLayoutPending != isPending else { return }
        isLayoutPending = isPending
    }
}

private struct SunburstChartRenderState {
    var segments: [SunburstSegment]
    var hoveredSegmentID: SunburstSegment.ID?

    private var segmentLookup: [SunburstSegment.ID: SunburstSegment]

    init(segments: [SunburstSegment] = [], hoveredSegmentID: SunburstSegment.ID? = nil) {
        self.segments = segments
        self.hoveredSegmentID = hoveredSegmentID
        segmentLookup = segments.reduce(into: [:]) { lookup, segment in
            lookup[segment.id] = segment
        }
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }
}
