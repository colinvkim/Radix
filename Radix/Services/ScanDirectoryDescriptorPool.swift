import Darwin
import Foundation

nonisolated final class ScanDirectoryDescriptorPool: @unchecked Sendable {
    struct DebugCounters: Sendable {
        let currentOpenDescriptorCount: Int
        let peakOpenDescriptorCount: Int
        let openCallCount: Int
        let openatCallCount: Int
        let fallbackCount: Int
        let retryCount: Int
    }

    struct SystemCalls: @unchecked Sendable {
        let openRoot: @Sendable (URL) -> (descriptor: Int32, errorCode: Int32)
        let openChild: @Sendable (
            Int32,
            BulkDirectoryEnumerator.NativeName
        ) -> (descriptor: Int32, errorCode: Int32)
        let fileIdentity: @Sendable (Int32) -> (identity: FileIdentity?, errorCode: Int32)
        let close: @Sendable (Int32) -> Void

        static let live = SystemCalls(
            openRoot: { url in
                let descriptor = url.withUnsafeFileSystemRepresentation { path in
                    path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
                }
                return (descriptor, descriptor >= 0 ? 0 : errno)
            },
            openChild: { parentDescriptor, name in
                name.withUnsafeFileSystemRepresentation { pointer in
                    let descriptor = Darwin.openat(
                        parentDescriptor,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
                    )
                    return (descriptor, descriptor >= 0 ? 0 : errno)
                }
            },
            fileIdentity: { descriptor in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else {
                    return (nil, errno)
                }
                return (
                    FileIdentity(fileSystemStatus: status),
                    0
                )
            },
            close: { descriptor in
                _ = Darwin.close(descriptor)
            }
        )
    }

    enum OpenOutcome: Sendable {
        case lease(Lease)
        case fallback
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var pool: ScanDirectoryDescriptorPool?
        private var descriptor: Int32

        fileprivate init(pool: ScanDirectoryDescriptorPool, descriptor: Int32) {
            self.pool = pool
            self.descriptor = descriptor
        }

        deinit {
            close()
        }

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return descriptor >= 0
        }

        func withDescriptor<Result>(_ body: (Int32) throws -> Result) rethrows -> Result? {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return nil }
            return try body(descriptor)
        }

        func close() {
            lock.lock()
            guard descriptor >= 0 else {
                lock.unlock()
                return
            }
            let descriptorToClose = descriptor
            descriptor = -1
            let pool = pool
            self.pool = nil
            lock.unlock()
            pool?.release(descriptorToClose, lease: self)
        }
    }

    private final class WeakLease {
        weak var value: Lease?

        init(_ value: Lease) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private let maxOpenDescriptorCount: Int
    private let systemCalls: SystemCalls
    private var currentOpenDescriptorCount = 0
    private var peakOpenDescriptorCount = 0
    private var openCallCount = 0
    private var openatCallCount = 0
    private var fallbackCount = 0
    private var retryCount = 0
    private var isInvalidated = false
    private var activeLeases: [ObjectIdentifier: WeakLease] = [:]

    init(maxOpenDescriptorCount: Int = 128, systemCalls: SystemCalls = .live) {
        self.maxOpenDescriptorCount = max(1, maxOpenDescriptorCount)
        self.systemCalls = systemCalls
    }

    deinit {
        invalidate()
    }

    var debugCounters: DebugCounters {
        lock.lock()
        defer { lock.unlock() }
        return DebugCounters(
            currentOpenDescriptorCount: currentOpenDescriptorCount,
            peakOpenDescriptorCount: peakOpenDescriptorCount,
            openCallCount: openCallCount,
            openatCallCount: openatCallCount,
            fallbackCount: fallbackCount,
            retryCount: retryCount
        )
    }

    func openRoot(
        at url: URL,
        expectedIdentity: FileIdentity? = nil,
        cancellationCheck: CancellationCheck = {}
    ) throws -> OpenOutcome {
        try cancellationCheck()
        guard reserveDescriptor(isOpenat: false) else { return .fallback }
        var result = systemCalls.openRoot(url)
        if result.descriptor < 0,
           Self.isFallbackError(result.errorCode),
           evictOneLease(excluding: nil) {
            recordRetry()
            result = systemCalls.openRoot(url)
        }
        guard result.descriptor >= 0 else {
            releaseReservation()
            if Self.isFallbackError(result.errorCode) {
                recordFallback()
                return .fallback
            }
            throw Self.posixError(result.errorCode, url: url)
        }
        try verifyIdentity(expectedIdentity, descriptor: result.descriptor, url: url)
        do {
            try cancellationCheck()
        } catch {
            systemCalls.close(result.descriptor)
            releaseReservation()
            throw error
        }
        guard let lease = register(descriptor: result.descriptor) else {
            systemCalls.close(result.descriptor)
            releaseReservation()
            throw CancellationError()
        }
        return .lease(lease)
    }

    func openChild(
        named name: BulkDirectoryEnumerator.NativeName,
        at childURL: URL,
        relativeTo parent: Lease,
        expectedIdentity: FileIdentity? = nil,
        cancellationCheck: CancellationCheck = {}
    ) throws -> OpenOutcome {
        try cancellationCheck()
        guard reserveDescriptor(isOpenat: true) else { return .fallback }
        guard var result = parent.withDescriptor({ descriptor in
            systemCalls.openChild(descriptor, name)
        }) else {
            releaseReservation()
            recordFallback()
            return .fallback
        }
        if result.descriptor < 0,
           Self.isFallbackError(result.errorCode),
           evictOneLease(excluding: parent),
           let retriedResult = parent.withDescriptor({ descriptor in
               systemCalls.openChild(descriptor, name)
           }) {
            recordRetry()
            result = retriedResult
        }
        guard result.descriptor >= 0 else {
            releaseReservation()
            if Self.isFallbackError(result.errorCode) {
                recordFallback()
                return .fallback
            }
            throw Self.posixError(result.errorCode, url: childURL)
        }
        try verifyIdentity(expectedIdentity, descriptor: result.descriptor, url: childURL)
        do {
            try cancellationCheck()
        } catch {
            systemCalls.close(result.descriptor)
            releaseReservation()
            throw error
        }
        guard let lease = register(descriptor: result.descriptor) else {
            systemCalls.close(result.descriptor)
            releaseReservation()
            throw CancellationError()
        }
        return .lease(lease)
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        let leases = activeLeases.values.compactMap(\.value)
        lock.unlock()
        leases.forEach { $0.close() }
    }

    func cancel() {
        invalidate()
    }

    private func reserveDescriptor(isOpenat: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated, currentOpenDescriptorCount < maxOpenDescriptorCount else {
            fallbackCount += 1
            return false
        }
        currentOpenDescriptorCount += 1
        peakOpenDescriptorCount = max(peakOpenDescriptorCount, currentOpenDescriptorCount)
        if isOpenat {
            openatCallCount += 1
        } else {
            openCallCount += 1
        }
        return true
    }

    private func register(descriptor: Int32) -> Lease? {
        let lease = Lease(pool: self, descriptor: descriptor)
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return nil
        }
        activeLeases[ObjectIdentifier(lease)] = WeakLease(lease)
        lock.unlock()
        return lease
    }

    private func release(_ descriptor: Int32, lease: Lease) {
        systemCalls.close(descriptor)
        lock.lock()
        activeLeases.removeValue(forKey: ObjectIdentifier(lease))
        currentOpenDescriptorCount = max(currentOpenDescriptorCount - 1, 0)
        lock.unlock()
    }

    private func releaseReservation() {
        lock.lock()
        currentOpenDescriptorCount = max(currentOpenDescriptorCount - 1, 0)
        lock.unlock()
    }

    private func recordFallback() {
        lock.lock()
        fallbackCount += 1
        lock.unlock()
    }

    private func recordRetry() {
        lock.lock()
        retryCount += 1
        lock.unlock()
    }

    private func evictOneLease(excluding excludedLease: Lease?) -> Bool {
        lock.lock()
        let candidate = activeLeases.values.compactMap(\.value).first { lease in
            guard let excludedLease else { return true }
            return lease !== excludedLease
        }
        lock.unlock()
        guard let candidate else { return false }
        candidate.close()
        return true
    }

    private func verifyIdentity(
        _ expectedIdentity: FileIdentity?,
        descriptor: Int32,
        url: URL
    ) throws {
        guard let expectedIdentity, expectedIdentity.isFileSystemIdentity else { return }
        let actual = systemCalls.fileIdentity(descriptor)
        guard actual.errorCode == 0, actual.identity == expectedIdentity else {
            systemCalls.close(descriptor)
            releaseReservation()
            let errorCode = actual.errorCode == 0 ? ESTALE : actual.errorCode
            throw Self.posixError(errorCode, url: url)
        }
    }

    private static func isFallbackError(_ errorCode: Int32) -> Bool {
        errorCode == EMFILE || errorCode == ENFILE
    }

    private static func posixError(_ code: Int32, url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSURLErrorKey: url]
        )
    }
}
