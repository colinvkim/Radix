import Combine
import Foundation
import Testing

@testable import RadixCore

@MainActor
struct SunburstChartModelTests {
    @Test
    func testKeyboardSelectionMovesAroundCurrentRingAndWraps() async {
        let first = makeSegment(id: "first", startAngle: 0, endAngle: 1)
        let aggregate = makeSegment(
            id: "aggregate",
            startAngle: 1,
            endAngle: 2,
            isSelectable: false
        )
        let second = makeSegment(id: "second", startAngle: 2, endAngle: 3)
        let third = makeSegment(id: "third", startAngle: 3, endAngle: 4)
        let model = await loadedModel(
            with: [third, aggregate, first, second]
        )

        #expect(model.keyboardSelection(from: first.id, moving: .left)?.nodeID == third.id)
        #expect(model.keyboardSelection(from: first.id, moving: .right)?.nodeID == second.id)
        #expect(model.keyboardSelection(from: third.id, moving: .right)?.nodeID == first.id)
    }

    @Test
    func testKeyboardSelectionSkipsItemsMovingToTrash() async {
        let first = makeSegment(id: "first", startAngle: 0, endAngle: 1)
        let moving = makeSegment(id: "moving", startAngle: 1, endAngle: 2)
        let last = makeSegment(id: "last", startAngle: 2, endAngle: 3)
        let model = await loadedModel(with: [first, moving, last])

        #expect(
            model.keyboardSelection(
                from: first.id,
                moving: .right,
                excludingMovingToTrashNodeIDs: [moving.id]
            )?.nodeID == last.id)
        #expect(
            model.keyboardSelection(
                from: nil,
                moving: .right,
                excludingMovingToTrashNodeIDs: [first.id, moving.id]
            )?.nodeID == last.id)
    }

    @Test
    func testKeyboardSelectionMovesOneRingInAndOut() async {
        let parent = makeSegment(
            id: "parent",
            startAngle: 0,
            endAngle: 2
        )
        let otherParent = makeSegment(
            id: "other-parent",
            startAngle: 2,
            endAngle: 4
        )
        let firstChild = makeSegment(
            id: "first-child",
            depth: 1,
            startAngle: 0,
            endAngle: 0.8
        )
        let secondChild = makeSegment(
            id: "second-child",
            depth: 1,
            startAngle: 0.8,
            endAngle: 2
        )
        let unrelatedChild = makeSegment(
            id: "unrelated-child",
            depth: 1,
            startAngle: 2,
            endAngle: 4
        )
        let model = await loadedModel(
            with: [
                unrelatedChild,
                secondChild,
                otherParent,
                firstChild,
                parent,
            ]
        )

        #expect(model.keyboardSelection(from: secondChild.id, moving: .up)?.nodeID == parent.id)
        #expect(model.keyboardSelection(from: parent.id, moving: .down)?.nodeID == secondChild.id)
        #expect(model.keyboardSelection(from: parent.id, moving: .up) == nil)
        #expect(model.keyboardSelection(from: secondChild.id, moving: .down) == nil)
    }

    @Test
    func testKeyboardSelectionStartsAtFirstSegmentInTopLevelRing() async {
        let first = makeSegment(
            id: "first",
            startAngle: 0,
            endAngle: 1
        )
        let later = makeSegment(
            id: "later",
            startAngle: 1,
            endAngle: 2
        )
        let deeper = makeSegment(
            id: "deeper",
            depth: 1,
            startAngle: 0,
            endAngle: 1
        )
        let model = await loadedModel(with: [deeper, later, first])

        #expect(model.keyboardSelection(from: nil, moving: .right)?.nodeID == first.id)
        #expect(model.keyboardSelection(from: "missing", moving: .down)?.nodeID == first.id)
    }

    @Test
    func testKeyboardSelectionUsesIDToOrderEqualAngles() async {
        let laterID = makeSegment(
            id: "b",
            startAngle: 0,
            endAngle: 1
        )
        let earlierID = makeSegment(
            id: "a",
            startAngle: 0,
            endAngle: 1
        )
        let model = await loadedModel(with: [laterID, earlierID])

        #expect(model.keyboardSelection(from: nil, moving: .right)?.nodeID == earlierID.id)
        #expect(model.keyboardSelection(from: earlierID.id, moving: .right)?.nodeID == laterID.id)
    }

    @Test
    func testStartingLayoutPublishesPendingState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()
        var publishCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            publishCount += 1
        }

        let layoutTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "layout"
            )
        }
        await service.waitForIssuedRequestCount(1)

        #expect(model.layoutReadiness.isPending)
        #expect(model.layoutReadiness.isRenderingPending(layoutID: "layout"))
        #expect(model.layoutReadiness.renderedLayoutID == nil)
        #expect(publishCount >= 1)

        let segment = makeSegment(id: "segment")
        let didCompleteRequest = await service.completeRequest(id: 0, with: [segment])
        #expect(didCompleteRequest)
        let didApplyLayout = await layoutTask.value

        #expect(didApplyLayout)
        #expect(!(model.layoutReadiness.isPending))
        #expect(model.renderedSegments.map(\.id) == [segment.id])
        #expect(model.layoutReadiness.renderedLayoutID == "layout")
        #expect(!(model.layoutReadiness.isRenderingPending(layoutID: "layout")))
        #expect(publishCount >= 2)
        withExtendedLifetime(cancellable) {}
    }

    @Test
    func testStartingNewLayoutCancelsPreviousLayoutWork() async {
        let service = ControllableSunburstLayoutService(resumesOnCancellation: true)
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForCancelledRequest(id: 0)
        await service.waitForIssuedRequestCount(2)

        let didApplyOldLayout = await oldTask.value
        #expect(!(didApplyOldLayout))

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        #expect(didApplyNewLayout)
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])
    }

    @Test
    func testStartingNewLayoutClearsHoverState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let firstTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteFirstRequest = await service.completeRequest(id: 0, with: [oldSegment])
        #expect(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        #expect(didApplyFirstLayout)
        model.setHoveredSegmentID(oldSegment.id)
        #expect(model.hoveredSegmentID == oldSegment.id)

        let secondTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        #expect(model.hoveredSegmentID == nil)
        #expect(model.layoutReadiness.isPending)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteSecondRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        #expect(didApplySecondLayout)
    }

    @Test
    func testStaleLayoutResultDoesNotReplaceNewerSegments() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let oldTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "old"
            )
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        #expect(didApplyNewLayout)
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteOldRequest = await service.completeRequest(id: 0, with: [oldSegment])
        #expect(didCompleteOldRequest)
        let didApplyOldLayout = await oldTask.value
        #expect(!(didApplyOldLayout))
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])
    }

    @Test
    func testLayoutFailurePreservesLastRenderAndPublishesError() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeSegment(id: "initial")
        let didCompleteInitialRequest = await service.completeRequest(id: 0, with: [initialSegment])
        #expect(didCompleteInitialRequest)
        let didApplyInitialLayout = await initialTask.value
        #expect(didApplyInitialLayout)
        let initialVersion = model.renderedLayoutVersion

        let failingTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                layoutID: "failing"
            )
        }
        await service.waitForIssuedRequestCount(2)
        let didFailRequest = await service.failRequest(id: 1, with: TestChartLayoutError.failed)
        #expect(didFailRequest)

        let didApplyFailingLayout = await failingTask.value
        #expect(!(didApplyFailingLayout))
        #expect(model.renderedSegments.map(\.id) == [initialSegment.id])
        #expect(model.renderedLayoutVersion == initialVersion)
        #expect(model.layoutReadiness.failure?.message == TestChartLayoutError.failed.localizedDescription)
        #expect(!(model.layoutReadiness.isPending))
        #expect(model.layoutReadiness.renderedLayoutID == "initial")
        #expect(model.layoutReadiness.failedLayoutID == "failing")
        #expect(!(model.layoutReadiness.isRenderingPending(layoutID: "failing")))
    }

    @Test
    func testStaleLayoutFailureDoesNotReplaceNewerSuccessOrPublishError() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let staleTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "stale"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let currentTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "current"
            )
        }
        await service.waitForIssuedRequestCount(2)

        let currentSegment = makeSegment(id: "current")
        let didCompleteCurrentRequest = await service.completeRequest(id: 1, with: [currentSegment])
        #expect(didCompleteCurrentRequest)
        let didApplyCurrentLayout = await currentTask.value
        #expect(didApplyCurrentLayout)
        let didFailStaleRequest = await service.failRequest(id: 0, with: TestChartLayoutError.failed)
        #expect(didFailStaleRequest)

        let didApplyStaleLayout = await staleTask.value
        #expect(!(didApplyStaleLayout))
        #expect(model.renderedSegments.map(\.id) == [currentSegment.id])
        #expect(model.layoutReadiness.failure == nil)
        #expect(!(model.layoutReadiness.isPending))
    }

    @Test
    func testRetryClearsFailureAndAppliesSuccessfulLayout() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let failingTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let didFailRequest = await service.failRequest(id: 0, with: TestChartLayoutError.failed)
        #expect(didFailRequest)
        let didApplyFailingLayout = await failingTask.value
        #expect(!(didApplyFailingLayout))
        #expect(model.layoutReadiness.failure != nil)

        let retryTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "unchanged-layout"
            )
        }
        await service.waitForIssuedRequestCount(2)
        #expect(model.layoutReadiness.failure == nil)
        #expect(model.layoutReadiness.isPending)

        let retrySegment = makeSegment(id: "retry")
        let didCompleteRetryRequest = await service.completeRequest(id: 1, with: [retrySegment])
        #expect(didCompleteRetryRequest)
        let didApplyRetryLayout = await retryTask.value
        #expect(didApplyRetryLayout)
        #expect(model.renderedSegments.map(\.id) == [retrySegment.id])
        #expect(model.layoutReadiness.failure == nil)
    }

    @Test
    func testCancellationPreservesLastRenderWithoutPublishingError() async {
        let service = ControllableSunburstLayoutService(resumesOnCancellation: true)
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let initialTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "initial"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let initialSegment = makeSegment(id: "initial")
        let didCompleteInitialRequest = await service.completeRequest(id: 0, with: [initialSegment])
        #expect(didCompleteInitialRequest)
        let didApplyInitialLayout = await initialTask.value
        #expect(didApplyInitialLayout)

        let cancelledTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                layoutID: "cancelled"
            )
        }
        await service.waitForIssuedRequestCount(2)
        cancelledTask.cancel()
        await service.waitForCancelledRequest(id: 1)

        let didApplyCancelledLayout = await cancelledTask.value
        #expect(!(didApplyCancelledLayout))
        #expect(model.renderedSegments.map(\.id) == [initialSegment.id])
        #expect(model.layoutReadiness.failure == nil)
        #expect(!(model.layoutReadiness.isPending))
    }

    @Test
    func testSelectionOverlaySegmentsIncludeAncestorsAndSelectedLast() async {
        let firstAncestor = makeSegment(id: "first-ancestor", depth: 0)
        let secondAncestor = makeSegment(id: "second-ancestor", depth: 1)
        let selected = makeSegment(id: "selected", depth: 1)
        let sibling = makeSegment(id: "sibling", depth: 1)
        let service = ImmediateSunburstLayoutService(
            segments: [secondAncestor, sibling, firstAncestor, selected]
        )
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let didApplyLayout = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            layoutID: "layout"
        )

        #expect(didApplyLayout)
        let overlaySegments = model.selectionOverlaySegments(
            selectedNodeID: selected.nodeID,
            selectedAncestorIDs: Set([
                firstAncestor.nodeID!,
                selected.nodeID!,
                secondAncestor.nodeID!,
                "missing",
            ])
        )

        #expect(overlaySegments.map(\.segment.id) == [secondAncestor.id, firstAncestor.id, selected.id])
        #expect(overlaySegments.map(\.role) == [.ancestor, .ancestor, .selected])
    }

    @Test
    func testSelectionOverlayCacheIsInvalidatedByNewLayout() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()
        let firstSelected = makeSegment(id: "selected", depth: 0)

        let firstTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "first"
            )
        }
        await service.waitForIssuedRequestCount(1)
        let didCompleteFirstRequest = await service.completeRequest(
            id: 0,
            with: [firstSelected]
        )
        #expect(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        #expect(didApplyFirstLayout)
        #expect(
            model.selectionOverlaySegments(
                selectedNodeID: firstSelected.nodeID,
                selectedAncestorIDs: []
            ).last?.segment.depth == 0)

        let secondSelected = makeSegment(id: "selected", depth: 1)
        let secondTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 2,
                layoutID: "second"
            )
        }
        await service.waitForIssuedRequestCount(2)
        let didCompleteSecondRequest = await service.completeRequest(
            id: 1,
            with: [secondSelected]
        )
        #expect(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        #expect(didApplySecondLayout)

        #expect(
            model.selectionOverlaySegments(
                selectedNodeID: secondSelected.nodeID,
                selectedAncestorIDs: []
            ).last?.segment.depth == 1)
    }

    private func loadedModel(
        with segments: [SunburstSegment]
    ) async -> SunburstChartModel {
        let model = SunburstChartModel(
            layoutService: ImmediateSunburstLayoutService(segments: segments)
        )
        let store = makeStore()
        _ = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 3,
            layoutID: "layout"
        )
        return model
    }
}

private actor ImmediateSunburstLayoutService: SunburstLayouting {
    private let renderedSegments: [SunburstSegment]

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        renderedSegments
    }
}

private actor ControllableSunburstLayoutService: SunburstLayouting {
    private struct RequestWaiter {
        let requestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let requestID: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let resumesOnCancellation: Bool
    private var issuedRequestCount = 0
    private var continuations: [Int: CheckedContinuation<[SunburstSegment], Error>] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var waiters: [RequestWaiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    init(resumesOnCancellation: Bool = false) {
        self.resumesOnCancellation = resumesOnCancellation
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        let requestID = issuedRequestCount
        issuedRequestCount += 1
        resumeSatisfiedWaiters()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[requestID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.handleCancellation(id: requestID)
            }
        }
    }

    func waitForIssuedRequestCount(_ requestCount: Int) async {
        guard issuedRequestCount < requestCount else { return }

        await withCheckedContinuation { continuation in
            waiters.append(RequestWaiter(requestCount: requestCount, continuation: continuation))
        }
    }

    func waitForCancelledRequest(id requestID: Int) async {
        guard !cancelledRequestIDs.contains(requestID) else { return }

        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CancellationWaiter(requestID: requestID, continuation: continuation))
        }
    }

    func completeRequest(id: Int, with segments: [SunburstSegment]) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: segments)
        return true
    }

    func failRequest(id: Int, with error: any Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func resumeSatisfiedWaiters() {
        var waiting: [RequestWaiter] = []
        for waiter in waiters {
            if issuedRequestCount >= waiter.requestCount {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }

    private func handleCancellation(id requestID: Int) {
        cancelledRequestIDs.insert(requestID)
        if resumesOnCancellation,
            let continuation = continuations.removeValue(forKey: requestID)
        {
            continuation.resume(throwing: CancellationError())
        }
        resumeCancellationWaiters()
    }

    private func resumeCancellationWaiters() {
        var waiting: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if cancelledRequestIDs.contains(waiter.requestID) {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        cancellationWaiters = waiting
    }
}

private enum TestChartLayoutError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test layout failure"
    }
}

private func makeStore() -> FileTreeStore {
    let root = FileNodeRecord(
        id: "/root",
        url: URL(filePath: "/root", directoryHint: .isDirectory),
        name: "root",
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: 1,
        logicalSize: 1,
        descendantFileCount: 0,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
    return FileTreeStore(root: root)
}

private func makeSegment(
    id: String,
    depth: Int = 0,
    startAngle: Double = 0,
    endAngle: Double = 1,
    innerRadius: CGFloat = 0,
    outerRadius: CGFloat = 1,
    isSelectable: Bool = true
) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: isSelectable ? id : nil,
        containerNodeID: "/root",
        label: id,
        startAngle: .radians(startAngle),
        endAngle: .radians(endAngle),
        innerRadius: innerRadius,
        outerRadius: outerRadius,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false
    )
}
