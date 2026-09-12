import Darwin
import Foundation
import Testing

@testable import RadixCore

struct ScanDirectoryDescriptorPoolTests {
    @Test
    func testOpenChildRefusesDirectoryReplacedBySymlink() throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let pool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 4)
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        try FileManager.default.removeItem(at: childURL)
        try FileManager.default.createSymbolicLink(at: childURL, withDestinationURL: outsideURL)
        let name = try #require(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))

        #expect { try pool.openChild(named: name, at: childURL, relativeTo: rootLease) } throws: { error in
            let code = (error as NSError).code
            #expect(code == Int(ELOOP) || code == Int(ENOTDIR), "Unexpected error: \(error)")
            return true
        }
        #expect(pool.debugCounters.currentOpenDescriptorCount == 1)
        rootLease.close()
        #expect(pool.debugCounters.currentOpenDescriptorCount == 0)
    }

    @Test
    func testOpenChildRejectsIdentityChangedAfterEnumeration() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let pool = ScanDirectoryDescriptorPool(maxOpenDescriptorCount: 4)
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let name = try #require(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))

        #expect {
            try pool.openChild(
                named: name,
                at: childURL,
                relativeTo: rootLease,
                expectedIdentity: FileIdentity(device: 0, inode: 0)
            )
        } throws: { error in
            #expect((error as NSError).code == Int(ESTALE))
            return true
        }
        #expect(pool.debugCounters.currentOpenDescriptorCount == 1)
        rootLease.close()
        #expect(pool.debugCounters.currentOpenDescriptorCount == 0)
    }

    @Test
    func testEMFILEEvictsAnotherLeaseAndRetriesOnce() throws {
        let tracker = RetryingDescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 4,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childName = try #require(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let disposableLease = try lease(
            from: pool.openChild(
                named: childName,
                at: rootURL.appending(path: "Disposable", directoryHint: .isDirectory),
                relativeTo: rootLease
            ))
        tracker.failNextChildOpenWithEMFILE()

        let retriedLease = try lease(
            from: pool.openChild(
                named: childName,
                at: rootURL.appending(path: "Retried", directoryHint: .isDirectory),
                relativeTo: rootLease
            ))

        #expect(!(disposableLease.isOpen))
        #expect(retriedLease.isOpen)
        #expect(pool.debugCounters.retryCount == 1)
        #expect(pool.debugCounters.fallbackCount == 0)
        #expect(pool.debugCounters.currentOpenDescriptorCount == 2)
        retriedLease.close()
        rootLease.close()
        #expect(tracker.openDescriptorCount == 0)
    }

    @Test
    func testLowBudgetFallsBackWithoutExceedingPeakAndRecoversAfterClose() throws {
        let tracker = DescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 2,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childURL = rootURL.appending(path: "Child", directoryHint: .isDirectory)
        let childName = try #require(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let firstChildLease = try lease(
            from: pool.openChild(
                named: childName,
                at: childURL,
                relativeTo: rootLease
            ))

        guard
            case .fallback = try pool.openChild(
                named: childName,
                at: childURL,
                relativeTo: rootLease
            )
        else {
            Issue.record("Expected descriptor-budget fallback")
            return
        }
        #expect(pool.debugCounters.peakOpenDescriptorCount == 2)
        #expect(pool.debugCounters.currentOpenDescriptorCount == 2)
        #expect(pool.debugCounters.fallbackCount == 1)

        firstChildLease.close()
        let replacementLease = try lease(
            from: pool.openChild(
                named: childName,
                at: childURL,
                relativeTo: rootLease
            ))
        #expect(pool.debugCounters.peakOpenDescriptorCount == 2)
        #expect(pool.debugCounters.currentOpenDescriptorCount == 2)

        replacementLease.close()
        rootLease.close()
        #expect(pool.debugCounters.currentOpenDescriptorCount == 0)
        #expect(tracker.openDescriptorCount == 0)
    }

    @Test
    func testCancellationClosesEveryActiveLeaseAndRejectsNewOpens() throws {
        let tracker = DescriptorTracker()
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 4,
            systemCalls: tracker.systemCalls
        )
        let rootURL = URL(filePath: "/virtual/root", directoryHint: .isDirectory)
        let childName = try #require(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("Child".utf8)))
        let rootLease = try lease(from: pool.openRoot(at: rootURL))
        let childLease = try lease(
            from: pool.openChild(
                named: childName,
                at: rootURL.appending(path: "Child", directoryHint: .isDirectory),
                relativeTo: rootLease
            ))

        pool.cancel()

        #expect(!(rootLease.isOpen))
        #expect(!(childLease.isOpen))
        #expect(pool.debugCounters.currentOpenDescriptorCount == 0)
        #expect(tracker.openDescriptorCount == 0)
        guard case .fallback = try pool.openRoot(at: rootURL) else {
            Issue.record("An invalidated pool must reject new opens")
            return
        }
    }

    @Test
    func testCancellationDuringOpenClosesInFlightDescriptor() throws {
        let tracker = DescriptorTracker()
        let cancellation = TestTaskCancellation()
        let underlying = tracker.systemCalls
        let pool = ScanDirectoryDescriptorPool(
            maxOpenDescriptorCount: 1,
            systemCalls: ScanDirectoryDescriptorPool.SystemCalls(
                openRoot: { url in
                    let result = underlying.openRoot(url)
                    #expect(tracker.openDescriptorCount == 1)
                    // Cancel after the syscall succeeds, before the pool registers its lease.
                    cancellation.cancel()
                    return result
                },
                openChild: underlying.openChild,
                fileIdentity: underlying.fileIdentity,
                close: underlying.close
            )
        )
        cancellation.install { pool.cancel() }

        #expect(throws: CancellationError.self) {
            try pool.openRoot(at: URL(filePath: "/virtual/root", directoryHint: .isDirectory))
        }
        #expect(pool.debugCounters.currentOpenDescriptorCount == 0)
        #expect(tracker.openDescriptorCount == 0)
    }

    private func lease(
        from outcome: ScanDirectoryDescriptorPool.OpenOutcome,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ScanDirectoryDescriptorPool.Lease {
        guard case .lease(let lease) = outcome else {
            Issue.record("Expected descriptor lease", sourceLocation: sourceLocation)
            throw NSError(domain: "ScanDirectoryDescriptorPoolTests", code: 1)
        }
        return lease
    }

}

private final class DescriptorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDescriptor: Int32 = 100
    private var openDescriptors: Set<Int32> = []

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: { [weak self] _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            openChild: { [weak self] _, _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            fileIdentity: { _ in (nil, 0) },
            close: { [weak self] descriptor in
                self?.close(descriptor)
            }
        )
    }

    var openDescriptorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openDescriptors.count
    }

    private func open() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return descriptor
    }

    private func close(_ descriptor: Int32) {
        lock.lock()
        openDescriptors.remove(descriptor)
        lock.unlock()
    }
}

private final class RetryingDescriptorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDescriptor: Int32 = 200
    private var openDescriptors: Set<Int32> = []
    private var shouldFailNextChildOpen = false

    var systemCalls: ScanDirectoryDescriptorPool.SystemCalls {
        ScanDirectoryDescriptorPool.SystemCalls(
            openRoot: { [weak self] _ in
                guard let self else { return (-1, EBADF) }
                return (self.open(), 0)
            },
            openChild: { [weak self] _, _ in
                guard let self else { return (-1, EBADF) }
                return self.openChild()
            },
            fileIdentity: { _ in (nil, 0) },
            close: { [weak self] descriptor in
                self?.close(descriptor)
            }
        )
    }

    var openDescriptorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openDescriptors.count
    }

    func failNextChildOpenWithEMFILE() {
        lock.lock()
        shouldFailNextChildOpen = true
        lock.unlock()
    }

    private func openChild() -> (descriptor: Int32, errorCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailNextChildOpen {
            shouldFailNextChildOpen = false
            return (-1, EMFILE)
        }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return (descriptor, 0)
    }

    private func open() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = nextDescriptor
        nextDescriptor += 1
        openDescriptors.insert(descriptor)
        return descriptor
    }

    private func close(_ descriptor: Int32) {
        lock.lock()
        openDescriptors.remove(descriptor)
        lock.unlock()
    }
}
