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
    @Published private(set) var renderedSegments: [SunburstSegment] = []
    @Published private(set) var isLayoutPending = false
    @Published private(set) var hoveredSegmentID: SunburstSegment.ID?

    private let layoutService: any SunburstLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[SunburstSegment], Error>?
    private var segmentLookup: [SunburstSegment.ID: SunburstSegment] = [:]

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }

    func setHoveredSegmentID(_ segmentID: SunburstSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        hoveredSegmentID = segmentID
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
        isLayoutPending = true

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
            isLayoutPending = false
            return true
        } catch is CancellationError {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            isLayoutPending = false
            return false
        } catch {
            guard isCurrentLayout(generation: generation, layoutID: layoutID) else {
                return false
            }
            layoutTask = nil
            apply([])
            isLayoutPending = false
            return true
        }
    }

    private func isCurrentLayout(generation: Int, layoutID: String) -> Bool {
        layoutGeneration == generation && activeLayoutID == layoutID
    }

    private func apply(_ segments: [SunburstSegment]) {
        renderedSegments = segments
        segmentLookup = segments.reduce(into: [:]) { lookup, segment in
            lookup[segment.id] = segment
        }
        setHoveredSegmentID(nil)
    }
}
