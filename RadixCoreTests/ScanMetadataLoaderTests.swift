import XCTest
@testable import RadixCore

final class ScanMetadataLoaderTests: XCTestCase {
    func testMissingLinkCountMetadataUsesLstatFallback() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let loader = makeScanMetadataLoader()
        let metadata = loader.metadata(
            for: originalURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: originalURL)
        )

        XCTAssertEqual(metadata.linkCount, 2)
        XCTAssertNotNil(metadata.fileIdentity)
    }

    func testFailedLinkCountFallbackUsesConservativeCount() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appending(path: "source.bin")
        try Data(repeating: 0xA5, count: 128).write(to: sourceURL)

        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)

        let loader = makeScanMetadataLoader()
        let metadata = loader.metadata(
            for: missingURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: sourceURL)
        )

        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertNil(metadata.fileIdentity)
    }

    func testMissingLinkCountOnVolumeWithoutHardLinksSkipsLstatAfterProbe() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = LinkCountProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: false
            )
        }
        let fileSystemInfoProvider = makeFileSystemInfoProvider { _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 2), 2)
        }
        let loader = makeScanMetadataLoader(
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let firstMetadata = loader.metadata(
            for: firstURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: firstURL)
        )
        let secondMetadata = loader.metadata(
            for: secondURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: secondURL)
        )

        XCTAssertEqual(firstMetadata.linkCount, 1)
        XCTAssertNil(firstMetadata.fileIdentity)
        XCTAssertEqual(secondMetadata.linkCount, 1)
        XCTAssertNil(secondMetadata.fileIdentity)
        XCTAssertEqual(counters.probeCount, 1)
        XCTAssertEqual(counters.lstatCount, 0)
    }

    func testMissingLinkCountOnHardLinkCapableVolumeStillUsesLstatWithCachedProbe() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = LinkCountProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: true
            )
        }
        let fileSystemInfoProvider = makeFileSystemInfoProvider { url in
            counters.recordLstat()
            return (
                FileIdentity(device: 1, inode: url.lastPathComponent == "first.bin" ? 10 : 11),
                2
            )
        }
        let loader = makeScanMetadataLoader(
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let firstMetadata = loader.metadata(
            for: firstURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: firstURL)
        )
        let secondMetadata = loader.metadata(
            for: secondURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: secondURL)
        )

        XCTAssertEqual(firstMetadata.linkCount, 2)
        XCTAssertNotNil(firstMetadata.fileIdentity)
        XCTAssertEqual(secondMetadata.linkCount, 2)
        XCTAssertNotNil(secondMetadata.fileIdentity)
        XCTAssertEqual(counters.probeCount, 1)
        XCTAssertEqual(counters.lstatCount, 2)
    }

    func testNoHardLinkProbeWithoutVolumeRootDoesNotCacheWholeRoot() throws {
        let rootWithoutVolumeURL = try makeTemporaryDirectory()
        let rootWithVolumeURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootWithoutVolumeURL)
            try? FileManager.default.removeItem(at: rootWithVolumeURL)
        }

        let fileWithoutVolumeURL = rootWithoutVolumeURL.appending(path: "without-volume.bin")
        let fileWithVolumeURL = rootWithVolumeURL.appending(path: "with-volume.bin")
        try Data(repeating: 0xA5, count: 128).write(to: fileWithoutVolumeURL)
        try Data(repeating: 0x5A, count: 128).write(to: fileWithVolumeURL)

        let counters = LinkCountProbeCounters()
        let cache = LinkCountCapabilityCache { url in
            counters.recordProbe()
            if url.path.hasPrefix(rootWithoutVolumeURL.path) {
                return LinkCountCapabilityCache.ProbeResult(
                    volumeRootPath: nil,
                    supportsHardLinks: false
                )
            }
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootWithVolumeURL.path,
                supportsHardLinks: true
            )
        }
        let fileSystemInfoProvider = makeFileSystemInfoProvider { _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 12), 2)
        }
        let loader = makeScanMetadataLoader(
            linkCountCapabilityCache: cache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )

        let metadataWithoutVolume = loader.metadata(
            for: fileWithoutVolumeURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: fileWithoutVolumeURL)
        )
        let metadataWithVolume = loader.metadata(
            for: fileWithVolumeURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: fileWithVolumeURL)
        )

        XCTAssertEqual(metadataWithoutVolume.linkCount, 1)
        XCTAssertNil(metadataWithoutVolume.fileIdentity)
        XCTAssertEqual(metadataWithVolume.linkCount, 2)
        XCTAssertNotNil(metadataWithVolume.fileIdentity)
        XCTAssertEqual(counters.probeCount, 2)
        XCTAssertEqual(counters.lstatCount, 1)
    }

    private func resourceValuesWithoutIdentity(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isReadableKey
        ])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScanMetadataLoader() -> ScanMetadataLoader {
        #if DEBUG
        ScanMetadataLoader(diagnostics: nil)
        #else
        ScanMetadataLoader()
        #endif
    }

    private func makeScanMetadataLoader(
        linkCountCapabilityCache: LinkCountCapabilityCache,
        fileSystemInfoProvider: @escaping ScanMetadataLoader.FileSystemInfoProvider
    ) -> ScanMetadataLoader {
        #if DEBUG
        ScanMetadataLoader(
            diagnostics: nil,
            linkCountCapabilityCache: linkCountCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )
        #else
        ScanMetadataLoader(
            linkCountCapabilityCache: linkCountCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )
        #endif
    }

    private func makeFileSystemInfoProvider(
        _ provider: @escaping @Sendable (URL) -> (identity: FileIdentity?, linkCount: UInt64)
    ) -> ScanMetadataLoader.FileSystemInfoProvider {
        #if DEBUG
        return { url, _ in provider(url) }
        #else
        return provider
        #endif
    }
}

private final class LinkCountProbeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private var lstats = 0

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    var lstatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lstats
    }

    func recordProbe() {
        lock.lock()
        probes += 1
        lock.unlock()
    }

    func recordLstat() {
        lock.lock()
        lstats += 1
        lock.unlock()
    }
}
