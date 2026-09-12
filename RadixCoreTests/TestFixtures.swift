import Darwin
import Foundation
import Testing

@testable import RadixCore

// A failure watchdog, not a performance assertion: allow for the full suite sharing
// the main actor and filesystem, including Xcode coverage instrumentation.
@MainActor
func waitUntil(
    _ description: String = "asynchronous test condition",
    timeout: TimeInterval = 15,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while true {
        try Task.checkCancellation()
        if await condition() { return }
        guard clock.now < deadline else {
            throw TestWaitTimeout(condition: description, sourceLocation: sourceLocation)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

struct TestWaitTimeout: Error, CustomStringConvertible {
    let condition: String
    let sourceLocation: SourceLocation

    var description: String { "\(sourceLocation): Timed out waiting for \(condition)." }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func setExtendedAttribute(named name: String, data: Data, at url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let throwOnCheck: Int
    private var checks = 0

    init(throwOnCheck: Int) {
        self.throwOnCheck = throwOnCheck
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func check() throws {
        lock.lock()
        checks += 1
        let shouldThrow = checks >= throwOnCheck
        lock.unlock()

        if shouldThrow {
            throw CancellationError()
        }
    }
}

final class TestAppPreferencesStore: AppPreferencesPersisting {
    var preferences: AppPreferences

    init(preferences: AppPreferences = .defaults) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppPreferences {
        preferences
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        self.preferences.scan = preferences
    }

    func markOnboardingComplete() {
        preferences.didCompleteOnboarding = true
    }

    func markOnboardingIncomplete() {
        preferences.didCompleteOnboarding = false
    }

    func saveOnboardingPage(_ page: OnboardingPage) {
        preferences.onboardingPage = page
    }
}

final class TestRecentTargetPersistence: RecentTargetPersisting {
    var targets: [ScanTarget]

    init(targets: [ScanTarget] = []) {
        self.targets = targets
    }

    func loadRecentTargets() -> [ScanTarget] {
        targets
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        self.targets = targets
    }

    func clearRecentTargets() {
        targets = []
    }
}

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    dataAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1,
    cloneIdentity: CloneIdentity? = nil,
    mayShareDataBlocks: Bool = false,
    isSymbolicLink: Bool = false,
    isAccessible: Bool = true,
    isSynthetic: Bool = false
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: isSymbolicLink,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        dataAllocatedSize: dataAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        cloneIdentity: cloneIdentity,
        mayShareDataBlocks: mayShareDataBlocks,
        isPackage: false,
        isAccessible: isAccessible,
        isSelfAccessible: isAccessible,
        isSynthetic: isSynthetic,
        isAutoSummarized: false
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

/// A directory the scan engine collapsed into a single leaf node (an auto-summarized
/// subtree). Its children are never indexed, so it must be placed in a store without a
/// `childrenByID` entry for its own id.
func makeTestSummarizedDirectoryNode(
    id: String,
    name: String,
    size: Int64,
    descendantFileCount: Int = 100
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: nil,
        logicalSize: size,
        descendantFileCount: descendantFileCount,
        lastModified: nil,
        fileIdentity: nil,
        linkCount: 1,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: true
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    scanOptions: ScanOptions? = nil,
    incrementalCheckpoint: ScanIncrementalCheckpoint? = nil
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: Date(),
        finishedAt: Date(),
        scanWarnings: warnings,
        isComplete: true,
        scanOptions: scanOptions,
        incrementalCheckpoint: incrementalCheckpoint
    )
}

func makeComparisonSnapshot(
    rootPath: String,
    fileSize: Int64,
    startedAt: Date = Date(timeIntervalSince1970: 1),
    finishedAt: Date? = Date(timeIntervalSince1970: 2),
    sourceURL: URL? = nil,
    scanOptions: ScanOptions? = nil,
    targetKind: ScanTargetKind = .folder
) -> ScanSnapshot {
    let file = makeTestFileNode(id: "\(rootPath)/shared.bin", name: "shared.bin", size: fileSize)
    let root = makeTestDirectoryNode(
        id: rootPath,
        name: URL(filePath: rootPath).lastPathComponent,
        children: [file]
    )
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    let source: ScanSnapshotSource
    if let sourceURL {
        source = .imported(
            ImportedSnapshotContext(
                sourceURL: sourceURL,
                pathMode: .absolute,
                liveActionCapability: .pathValidation
            ))
    } else {
        source = .live
    }

    return ScanSnapshot(
        target: ScanTarget(id: root.id, url: root.url, displayName: root.name, kind: targetKind),
        treeStore: store,
        startedAt: startedAt,
        finishedAt: finishedAt,
        scanWarnings: [],
        isComplete: true,
        scanOptions: scanOptions,
        source: source
    )
}

// Invalid opt-in benchmark configurations must fail, not silently skip work.
struct TestFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Tag {
    @Tag static var benchmark: Self
}

/// Each Swift Testing suite instance owns its fixtures, including on thrown requirements.
final class TemporaryTestFiles {
    private var urls: [URL] = []
    func track(_ url: URL) { urls.append(url) }
    deinit {
        for url in urls.reversed() { try? FileManager.default.removeItem(at: url) }
    }
}

/// Blocking filesystem hooks must not block the cooperative executor running the test.
func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

/// Allows a synchronous worker hook to cancel a task even if it starts before
/// the creating test has received the task handle. No executor thread blocks.
final class TestTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock {
            if isCancelled { return true }
            self.action = action
            return false
        }
        if shouldCancel { action() }
    }

    func cancel() {
        let action = lock.withLock {
            isCancelled = true
            defer { self.action = nil }
            return self.action
        }
        action?()
    }
}

/// One owner per suite instance keeps persistence tests isolated and cleans up
/// even when a thrown requirement stops a test early.
final class TemporaryTestDefaults {
    private var suiteNames: [String] = []

    func make(sourceLocation: SourceLocation = #_sourceLocation) throws -> UserDefaults {
        let suiteName = "RadixTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName), sourceLocation: sourceLocation)
        suiteNames.append(suiteName)
        return defaults
    }

    deinit {
        for suiteName in suiteNames { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    }
}
