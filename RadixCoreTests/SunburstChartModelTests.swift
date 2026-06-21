import Combine
import XCTest
@testable import RadixCore

@MainActor
final class SunburstChartModelTests: XCTestCase {
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

        XCTAssertTrue(model.isLayoutPending)
        XCTAssertGreaterThanOrEqual(publishCount, 1)

        let segment = makeSegment(id: "segment")
        let didCompleteRequest = await service.completeRequest(id: 0, with: [segment])
        XCTAssertTrue(didCompleteRequest)
        let didApplyLayout = await layoutTask.value

        XCTAssertTrue(didApplyLayout)
        XCTAssertFalse(model.isLayoutPending)
        XCTAssertEqual(model.renderedSegments.map(\.id), [segment.id])
        XCTAssertGreaterThanOrEqual(publishCount, 2)
        withExtendedLifetime(cancellable) {}
    }

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
        XCTAssertFalse(didApplyOldLayout)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
    }

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
        XCTAssertTrue(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        XCTAssertTrue(didApplyFirstLayout)
        model.setHoveredSegmentID(oldSegment.id)
        XCTAssertEqual(model.hoveredSegmentID, oldSegment.id)

        let secondTask = Task {
            await model.loadLayout(
                treeStore: store,
                rootID: store.rootID,
                depthLimit: 1,
                layoutID: "new"
            )
        }
        await service.waitForIssuedRequestCount(2)

        XCTAssertNil(model.hoveredSegmentID)
        XCTAssertTrue(model.isLayoutPending)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteSecondRequest = await service.completeRequest(id: 1, with: [newSegment])
        XCTAssertTrue(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        XCTAssertTrue(didApplySecondLayout)
    }

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
        XCTAssertTrue(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        XCTAssertTrue(didApplyNewLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteOldRequest = await service.completeRequest(id: 0, with: [oldSegment])
        XCTAssertTrue(didCompleteOldRequest)
        let didApplyOldLayout = await oldTask.value
        XCTAssertFalse(didApplyOldLayout)
        XCTAssertEqual(model.renderedSegments.map(\.id), [newSegment.id])
    }

    func testSelectionOverlaySegmentsIncludeAncestorsAndSelectedLast() async {
        let ancestor = makeSegment(id: "ancestor", depth: 0)
        let selected = makeSegment(id: "selected", depth: 1)
        let sibling = makeSegment(id: "sibling", depth: 1)
        let service = ImmediateSunburstLayoutService(segments: [ancestor, selected, sibling])
        let model = SunburstChartModel(layoutService: service)
        let store = makeStore()

        let didApplyLayout = await model.loadLayout(
            treeStore: store,
            rootID: store.rootID,
            depthLimit: 2,
            layoutID: "layout"
        )

        XCTAssertTrue(didApplyLayout)
        let overlaySegments = model.selectionOverlaySegments(
            selectedNodeID: selected.nodeID,
            selectedAncestorIDs: Set([ancestor.nodeID!, selected.nodeID!, "missing"])
        )

        XCTAssertEqual(overlaySegments.map(\.segment.id), [ancestor.id, selected.id])
        XCTAssertEqual(overlaySegments.map(\.role), [.ancestor, .selected])
    }
}

private actor ImmediateSunburstLayoutService: SunburstLayouting {
    private let renderedSegments: [SunburstSegment]

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(
        in treeStore: FileTreeStore,
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
        in treeStore: FileTreeStore,
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
           let continuation = continuations.removeValue(forKey: requestID) {
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

private func makeSegment(id: String, depth: Int = 0) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: .radians(0),
        endAngle: .radians(1),
        innerRadius: 0,
        outerRadius: 1,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false
    )
}
