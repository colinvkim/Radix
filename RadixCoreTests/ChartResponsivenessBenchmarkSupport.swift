import CoreGraphics
import Foundation
import XCTest
@testable import RadixCore

enum ChartResponsivenessBenchmarkSupport {
    static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    static func node(
        id: String,
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(
                filePath: id,
                directoryHint: isDirectory ? .isDirectory : .notDirectory
            ),
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    @inline(__always)
    static func hash(_ string: String, into hash: inout UInt64) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        Self.hash(0xff, into: &hash)
    }

    @inline(__always)
    static func hash(_ value: UInt64, into hash: inout UInt64) {
        var value = value
        for _ in 0..<MemoryLayout<UInt64>.size {
            hash ^= value & 0xff
            hash &*= fnvPrime
            value >>= 8
        }
    }

    @MainActor
    static func measureAsync<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> BenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try await operation()
        return BenchmarkMeasurement(
            value: value,
            seconds: BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        )
    }

    @MainActor
    static func measureRequestSequence<Request>(
        _ requests: [Request],
        probe: LayoutProbe,
        chartName: String,
        loadLayout: @escaping @MainActor (Request) async -> Bool,
        renderedLayout: () -> (id: String?, segmentCount: Int, fingerprint: String),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RequestSequenceMeasurement {
        var tasks: [Task<Bool, Never>] = []
        tasks.reserveCapacity(requests.count)
        defer { for task in tasks { task.cancel() } }
        let sequenceStartedAt = ContinuousClock.now
        var latestRequestStartedAt = sequenceStartedAt

        for (index, request) in requests.enumerated() {
            if index == requests.count - 1 {
                latestRequestStartedAt = ContinuousClock.now
            }
            tasks.append(Task { @MainActor in await loadLayout(request) })
            try await waitForStartedRequestCount(index + 1, probe: probe, chartName: chartName)
        }

        let latestTask = try XCTUnwrap(tasks.last, file: file, line: line)
        let latestDidApply = await latestTask.value
        let latestCompletedAt = ContinuousClock.now
        var appliedCount = 0
        for task in tasks {
            if await task.value { appliedCount += 1 }
        }
        let probeSnapshot = await probe.snapshot()

        XCTAssertTrue(latestDidApply, file: file, line: line)
        XCTAssertEqual(probeSnapshot.startedCount, requests.count, file: file, line: line)
        let layout = renderedLayout()
        return RequestSequenceMeasurement(
            requestCount: requests.count,
            appliedCount: appliedCount,
            completedCount: probeSnapshot.completedCount,
            cancelledCount: probeSnapshot.cancelledCount,
            latestRequestSeconds: BenchmarkSupport.durationSeconds(
                latestRequestStartedAt.duration(to: latestCompletedAt)
            ),
            totalSeconds: BenchmarkSupport.durationSeconds(sequenceStartedAt.duration(to: latestCompletedAt)),
            renderedLayoutID: layout.id,
            segmentCount: layout.segmentCount,
            fingerprint: layout.fingerprint
        )
    }

    @MainActor
    private static func waitForStartedRequestCount(
        _ expectedCount: Int,
        probe: LayoutProbe,
        chartName: String
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while await probe.startedCount < expectedCount,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .microseconds(100))
        }
        guard await probe.startedCount >= expectedCount else {
            throw TimeoutError(
                message: "Timed out waiting for \(chartName) layout request \(expectedCount) to start."
            )
        }
    }

    @MainActor
    static func measureLayoutCancellation(
        baselineLayoutSeconds: Double,
        operation: @escaping @Sendable () throws -> Void
    ) async throws -> CancellationMeasurement {
        let task = Task.detached {
            try operation()
            return ContinuousClock.now
        }
        defer { task.cancel() }
        let delaySeconds = min(max(baselineLayoutSeconds * 0.25, 0.002), 0.05)
        try await Task.sleep(for: .seconds(delaySeconds))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    @MainActor
    static func runHitTests(
        size: CGSize,
        iterationCount: Int,
        hitTest: (CGPoint) -> String?
    ) -> InteractionMeasurement {
        var state = UInt64(0x9e3779b97f4a7c15)
        var fingerprint = fnvOffsetBasis
        var hitCount = 0

        for _ in 0..<iterationCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let xUnit = Double(UInt32(truncatingIfNeeded: state)) / Double(UInt32.max)
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let yUnit = Double(UInt32(truncatingIfNeeded: state)) / Double(UInt32.max)
            let point = CGPoint(
                x: CGFloat(xUnit) * size.width,
                y: CGFloat(yUnit) * size.height
            )
            if let segmentID = hitTest(point) {
                hitCount += 1
                hash(segmentID, into: &fingerprint)
            } else {
                hash(UInt64.max, into: &fingerprint)
            }
        }
        return InteractionMeasurement(
            selectionCount: hitCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    actor LayoutProbe {
        private(set) var startedCount = 0
        private var completedCount = 0
        private var cancelledCount = 0

        @discardableResult
        func recordStarted() -> Int {
            startedCount += 1
            return startedCount
        }

        func recordCompleted() {
            completedCount += 1
        }

        func recordCancelled() {
            cancelledCount += 1
        }

        func snapshot() -> LayoutProbeSnapshot {
            LayoutProbeSnapshot(
                startedCount: startedCount,
                completedCount: completedCount,
                cancelledCount: cancelledCount
            )
        }
    }

    struct LayoutProbeSnapshot: Sendable {
        let startedCount: Int
        let completedCount: Int
        let cancelledCount: Int
    }

    struct LayoutSample {
        let seconds: Double
        let segmentCount: Int
        let fingerprint: String
    }

    struct InteractionMeasurement {
        let selectionCount: Int
        let fingerprint: String
    }

    struct CancellationMeasurement {
        let seconds: Double
        let wasCancelled: Bool
        let completedBeforeCancellation: Bool
    }

    struct RequestSequenceMeasurement {
        let requestCount: Int
        let appliedCount: Int
        let completedCount: Int
        let cancelledCount: Int
        let latestRequestSeconds: Double
        let totalSeconds: Double
        let renderedLayoutID: String?
        let segmentCount: Int
        let fingerprint: String
    }

    struct TimeoutError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }
}
