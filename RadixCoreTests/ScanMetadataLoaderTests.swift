import Darwin
import XCTest
@testable import RadixCore

final class ScanMetadataLoaderTests: XCTestCase {
    func testMetadataReusesStatusIdentityAndAllocationFallback() {
        let counters = MetadataProbeCounters()
        let identity = FileIdentity(device: 7, inode: 42)
        let loader = ScanMetadataLoader(
            linkCountCapabilityCache: LinkCountCapabilityCache { _ in
                .init(volumeRootPath: "/virtual", supportsHardLinks: true)
            },
            cloneMappingCapabilityCache: CloneMappingCapabilityCache(probeProvider: { _ in
                .init(identity: nil, supportsCloneMapping: false)
            }, volumeRootProvider: { _ in "/virtual" }),
            fileStatusProvider: { _ in
                counters.recordLstat()
                return .init(fileFlags: UInt32(SF_DATALESS), isDirectory: false,
                             fileIdentity: identity, linkCount: 3, allocatedSize: 8_192)
            }
        )

        let metadata = loader.metadata(
            for: URL(filePath: "/virtual/file", directoryHint: .notDirectory),
            prefetchedResourceValues: URLResourceValues()
        )

        XCTAssertTrue(metadata.isDataless)
        XCTAssertEqual(metadata.fileIdentity, identity)
        XCTAssertEqual(metadata.linkCount, 3)
        XCTAssertEqual(metadata.allocatedSize, 8_192)
        XCTAssertEqual(metadata.dataAllocatedSize, 8_192)
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testExplicitProviderFailuresDoNotFallThroughToStatusFields() {
        let loader = ScanMetadataLoader(
            linkCountCapabilityCache: LinkCountCapabilityCache { _ in
                .init(volumeRootPath: "/virtual", supportsHardLinks: true)
            },
            fileSystemInfoProvider: { _, _ in (nil, 3) },
            fileAllocatedSizeProvider: { _ in nil },
            fileStatusProvider: { _ in
                .init(fileFlags: 0, isDirectory: false,
                      fileIdentity: FileIdentity(device: 7, inode: 42), linkCount: 7, allocatedSize: 8_192)
            }
        )
        let metadata = loader.metadata(
            for: URL(filePath: "/virtual/file", directoryHint: .notDirectory),
            prefetchedResourceValues: URLResourceValues()
        )
        XCTAssertNil(metadata.fileIdentity)
        XCTAssertEqual(metadata.linkCount, 3)
        XCTAssertEqual(metadata.allocatedSize, 0)
    }

    func testReusedStatusDoesNotMaskDirectoryReplacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let loader = ScanMetadataLoader()
        let original = try XCTUnwrap(loader.metadata(for: directory).fileIdentity)
        try FileManager.default.moveItem(at: directory, to: root.appending(path: "old"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        XCTAssertThrowsError(try loader.validateFileSystemIdentity(original, at: directory))
        XCTAssertNotEqual(try loader.metadata(for: directory).fileIdentity, original)
    }

    func testFileSystemIdentityValidationUsesTheDedicatedProvider() throws {
        let url = URL(filePath: "/virtual/directory", directoryHint: .isDirectory)
        let expectedIdentity = FileIdentity(device: 7, inode: 42)
        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(fileSystemInfoProvider: { requestedURL, _ in
            XCTAssertEqual(requestedURL, url)
            counters.recordLstat()
            return (expectedIdentity, 1)
        })

        XCTAssertEqual(try loader.fileSystemIdentity(at: url), expectedIdentity)
        XCTAssertNoThrow(try loader.validateFileSystemIdentity(expectedIdentity, at: url))
        XCTAssertEqual(counters.lstatCount, 2)
    }

    func testFileSystemIdentityValidationFailsClosedForMissingOrChangedIdentity() {
        let url = URL(filePath: "/virtual/directory", directoryHint: .isDirectory)
        let expectedIdentity = FileIdentity(device: 7, inode: 42)
        for currentIdentity in [nil, FileIdentity(device: 7, inode: 43)] {
            let loader = ScanMetadataLoader(fileSystemInfoProvider: { _, _ in
                (currentIdentity, 1)
            })

            XCTAssertThrowsError(
                try loader.validateFileSystemIdentity(expectedIdentity, at: url)
            ) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(nsError.code, Int(ESTALE))
                XCTAssertEqual(nsError.userInfo[NSURLErrorKey] as? URL, url)
            }
        }
    }

    func testCloneProbeRequestsPhysicalDeviceIdentity() {
        XCTAssertNotEqual(
            ScanMetadataLoader.cloneProbeOptions & UInt32(FSOPT_RETURN_REALDEV),
            0
        )
    }

    func testDatalessFlagClassification() {
        XCTAssertTrue(ScanMetadataLoader.isDataless(fileFlags: UInt32(SF_DATALESS)))
        XCTAssertFalse(ScanMetadataLoader.isDataless(fileFlags: nil))
        XCTAssertFalse(ScanMetadataLoader.isDataless(fileFlags: 0))
        XCTAssertFalse(ScanMetadataLoader.isDataless(fileFlags: UInt32(UF_HIDDEN)))
    }

    func testMetadataCarriesDatalessFlag() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "placeholder.bin")
        try Data([0xA5]).write(to: fileURL)
        let loader = ScanMetadataLoader(
            fileStatusProvider: { requestedURL in
                XCTAssertEqual(requestedURL, fileURL)
                return ScanMetadataLoader.FileStatus(
                    fileFlags: UInt32(SF_DATALESS),
                    isDirectory: false
                )
            }
        )

        XCTAssertTrue(try loader.metadata(for: fileURL).isDataless)
    }

    func testDatalessStatusUsesFileTypeFromLstatProvider() {
        let urlWithoutDirectoryHint = URL(filePath: "/virtual/cloud-folder", directoryHint: .notDirectory)
        let loader = ScanMetadataLoader(
            fileStatusProvider: { requestedURL in
                XCTAssertEqual(requestedURL, urlWithoutDirectoryHint)
                return ScanMetadataLoader.FileStatus(
                    fileFlags: UInt32(SF_DATALESS),
                    isDirectory: true
                )
            }
        )

        XCTAssertFalse(urlWithoutDirectoryHint.hasDirectoryPath)
        XCTAssertTrue(loader.datalessStatus(at: urlWithoutDirectoryHint)?.isDirectory == true)
    }

    func testLogicalSizeIncludesResourceForkData() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "resource-fork.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: fileURL)
        try setExtendedAttribute(
            named: "com.apple.ResourceFork",
            data: Data(repeating: 0x5A, count: 10),
            at: fileURL
        )
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        let totalFileSize = try XCTUnwrap(values.totalFileSize)

        let metadata = try ScanMetadataLoader().metadata(for: fileURL)

        XCTAssertGreaterThan(totalFileSize, values.fileSize ?? 0)
        XCTAssertEqual(metadata.logicalSize, Int64(totalFileSize))
    }

    func testMissingAllocatedSizeUsesFileSystemBlockFallback() {
        let url = URL(filePath: "/virtual/sparse.bin")
        let loader = ScanMetadataLoader(
            fileAllocatedSizeProvider: { requestedURL in
                XCTAssertEqual(requestedURL, url)
                return 8_192
            }
        )

        let metadata = loader.metadata(for: url, prefetchedResourceValues: URLResourceValues())

        XCTAssertEqual(metadata.allocatedSize, 8_192)
        XCTAssertEqual(metadata.dataAllocatedSize, 8_192)
    }

    func testUnsupportedCloneMappingVolumeIsProbedOnlyOnce() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstURL = rootURL.appending(path: "first.bin")
        let secondURL = rootURL.appending(path: "second.bin")
        try Data(repeating: 0xA5, count: 128).write(to: firstURL)
        try Data(repeating: 0x5A, count: 128).write(to: secondURL)

        let counters = MetadataProbeCounters()
        let cache = CloneMappingCapabilityCache(
            probeProvider: { _ in
                counters.recordProbe()
                return CloneMappingCapabilityCache.ProbeResult(
                    identity: nil,
                    supportsCloneMapping: false
                )
            },
            volumeRootProvider: { _ in rootURL.path }
        )
        let loader = ScanMetadataLoader(cloneMappingCapabilityCache: cache)

        let firstMetadata = try loader.metadata(for: firstURL)
        let secondMetadata = try loader.metadata(for: secondURL)

        XCTAssertNil(firstMetadata.cloneIdentity)
        XCTAssertNil(secondMetadata.cloneIdentity)
        XCTAssertEqual(counters.probeCount, 1)
    }

    func testRootVolumeCloneCacheDoesNotMaskMountedVolume() {
        let counters = MetadataProbeCounters()
        let cache = CloneMappingCapabilityCache(
            probeProvider: { _ in
                counters.recordProbe()
                return CloneMappingCapabilityCache.ProbeResult(
                    identity: nil,
                    supportsCloneMapping: false
                )
            },
            volumeRootProvider: { url in
                url.path.hasPrefix("/Volumes/External/") ? "/Volumes/External" : "/"
            }
        )

        XCTAssertNil(cache.cloneMetadata(for: URL(filePath: "/Users/example/first.bin")).identity)
        XCTAssertNil(cache.cloneMetadata(for: URL(filePath: "/Volumes/External/second.bin")).identity)

        XCTAssertEqual(counters.probeCount, 2)
    }

    func testCloneCapabilityCacheNormalizesPathsAndPreservesVolumeBoundaries() {
        let counters = MetadataProbeCounters()
        let rootPath = "/Volumes/Audit Disk #1"
        let siblingRootPath = rootPath + "-other"
        let cache = CloneMappingCapabilityCache(
            probeProvider: { _ in
                counters.recordProbe()
                return CloneMappingCapabilityCache.ProbeResult(
                    identity: nil,
                    supportsCloneMapping: false
                )
            },
            volumeRootProvider: { url in
                url.path.hasPrefix(siblingRootPath + "/") ? siblingRootPath : rootPath + "/./"
            }
        )

        for path in [rootPath + "/first.bin", rootPath + "/nested/../second.bin"] {
            XCTAssertNil(cache.cloneMetadata(for: URL(filePath: path, directoryHint: .notDirectory)).identity)
        }
        XCTAssertEqual(counters.probeCount, 1)

        XCTAssertNil(cache.cloneMetadata(for: URL(
            filePath: siblingRootPath + "/third.bin",
            directoryHint: .notDirectory
        )).identity)
        XCTAssertEqual(counters.probeCount, 2)
    }

    func testMissingLinkCountMetadataUsesLstatFallback() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let loader = ScanMetadataLoader(diagnostics: nil)
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

        let loader = ScanMetadataLoader(diagnostics: nil)
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

        let counters = MetadataProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: false
            )
        }
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { _, _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 2), 2)
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
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

        let counters = MetadataProbeCounters()
        let cache = LinkCountCapabilityCache { _ in
            counters.recordProbe()
            return LinkCountCapabilityCache.ProbeResult(
                volumeRootPath: rootURL.path,
                supportsHardLinks: true
            )
        }
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { url, _ in
            counters.recordLstat()
            return (
                FileIdentity(device: 1, inode: url.lastPathComponent == "first.bin" ? 10 : 11),
                2
            )
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
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

        let counters = MetadataProbeCounters()
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
        let fileSystemInfoProvider: ScanMetadataLoader.FileSystemInfoProvider = { _, _ in
            counters.recordLstat()
            return (FileIdentity(device: 1, inode: 12), 2)
        }
        let loader = ScanMetadataLoader(
            diagnostics: nil,
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

    func testVisibleSymlinkMetadataUsesLstatIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let targetURL = rootURL.appending(path: "target.bin")
        let symlinkURL = rootURL.appending(path: "target-link")
        try Data(repeating: 0xA5, count: 128).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 1, inode: 42), 1)
            }
        )

        let metadata = loader.metadata(
            for: symlinkURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: symlinkURL)
        )

        XCTAssertTrue(metadata.isSymbolicLink)
        XCTAssertEqual(metadata.fileIdentity, FileIdentity(device: 1, inode: 42))
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testDirectoryMetadataUsesFileSystemIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 7, inode: 42), 9)
            }
        )

        let metadata = try loader.metadata(for: rootURL)

        XCTAssertTrue(metadata.isDirectory)
        XCTAssertEqual(metadata.fileIdentity, FileIdentity(device: 7, inode: 42))
        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertEqual(counters.lstatCount, 1)
    }

    func testAtomicSummarySymlinkMetadataSkipsLstatIdentity() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let targetURL = rootURL.appending(path: "target.bin")
        let symlinkURL = rootURL.appending(path: "target-link")
        try Data(repeating: 0xA5, count: 128).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(
            diagnostics: nil,
            fileSystemInfoProvider: { _, _ in
                counters.recordLstat()
                return (FileIdentity(device: 1, inode: 42), 1)
            }
        )

        let metadata = loader.atomicSummaryMetadata(
            for: symlinkURL,
            prefetchedResourceValues: try resourceValuesWithoutIdentity(for: symlinkURL)
        )

        XCTAssertTrue(metadata.isSymbolicLink)
        XCTAssertNil(metadata.fileIdentity)
        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertEqual(counters.lstatCount, 0)
    }

    private func resourceValuesWithoutIdentity(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .isReadableKey
        ])
    }

}

private final class MetadataProbeCounters: @unchecked Sendable {
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
