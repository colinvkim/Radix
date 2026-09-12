import Darwin
import Foundation
import Testing

@testable import RadixCore

struct ScanMetadataLoaderTests {
    @Test
    func testStatIdentityPreservesSignedDeviceIDs() {
        let cases: [(dev_t, UInt64)] = [
            (0, 0),
            (42, 42),
            (.max, 0x7FFF_FFFF),
            (.min, 0xFFFF_FFFF_8000_0000),
            (-1, UInt64.max),
        ]
        for (device, expectedDevice) in cases {
            var status = stat()
            status.st_dev = device
            status.st_ino = 42
            #expect(FileIdentity(fileSystemStatus: status) == FileIdentity(device: expectedDevice, inode: 42))
        }
    }

    @Test
    func testStatusPreservesSignedDeviceIdentityAndClampsAllocation() {
        var fileStat = stat()
        fileStat.st_dev = -1
        fileStat.st_ino = 42
        fileStat.st_mode = mode_t(S_IFDIR)
        fileStat.st_flags = UInt32(SF_DATALESS)
        fileStat.st_blocks = .max
        let status = ScanMetadataLoader.FileStatus(fileStat)
        #expect(status.fileIdentity == FileIdentity(device: UInt64.max, inode: 42))
        #expect(status.isDirectory)
        #expect(status.fileFlags == UInt32(SF_DATALESS))
        #expect(status.allocatedSize == Int64.max)
        #expect(status.linkCount == 1)
        fileStat.st_blocks = -1
        #expect(ScanMetadataLoader.FileStatus(fileStat).allocatedSize == 0)
    }

    @Test
    func testMetadataReusesStatusIdentityAndAllocationFallback() {
        let counters = MetadataProbeCounters()
        let identity = FileIdentity(device: 7, inode: 42)
        let loader = ScanMetadataLoader(
            linkCountCapabilityCache: LinkCountCapabilityCache { _ in
                .init(volumeRootPath: "/virtual", supportsHardLinks: true)
            },
            cloneMappingCapabilityCache: CloneMappingCapabilityCache(
                probeProvider: { _ in
                    .init(identity: nil, supportsCloneMapping: false)
                }, volumeRootProvider: { _ in "/virtual" }),
            fileStatusProvider: { _ in
                counters.recordLstat()
                return .init(
                    fileFlags: UInt32(SF_DATALESS), isDirectory: false,
                    fileIdentity: identity, linkCount: 3, allocatedSize: 8_192)
            }
        )

        let metadata = loader.metadata(
            for: URL(filePath: "/virtual/file", directoryHint: .notDirectory),
            prefetchedResourceValues: URLResourceValues()
        )

        #expect(metadata.isDataless)
        #expect(metadata.fileIdentity == identity)
        #expect(metadata.linkCount == 3)
        #expect(metadata.allocatedSize == 8_192)
        #expect(metadata.dataAllocatedSize == 8_192)
        #expect(counters.lstatCount == 1)
    }

    @Test
    func testExplicitProviderFailuresDoNotFallThroughToStatusFields() {
        let loader = ScanMetadataLoader(
            linkCountCapabilityCache: LinkCountCapabilityCache { _ in
                .init(volumeRootPath: "/virtual", supportsHardLinks: true)
            },
            fileSystemInfoProvider: { _, _ in (nil, 3) },
            fileAllocatedSizeProvider: { _ in nil },
            fileStatusProvider: { _ in
                .init(
                    fileFlags: 0, isDirectory: false,
                    fileIdentity: FileIdentity(device: 7, inode: 42), linkCount: 7, allocatedSize: 8_192)
            }
        )
        let metadata = loader.metadata(
            for: URL(filePath: "/virtual/file", directoryHint: .notDirectory),
            prefetchedResourceValues: URLResourceValues()
        )
        #expect(metadata.fileIdentity == nil)
        #expect(metadata.linkCount == 3)
        #expect(metadata.allocatedSize == 0)
    }

    @Test
    func testReusedStatusDoesNotMaskDirectoryReplacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let loader = ScanMetadataLoader()
        let original = try #require(loader.metadata(for: directory).fileIdentity)
        try FileManager.default.moveItem(at: directory, to: root.appending(path: "old"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) { try loader.validateFileSystemIdentity(original, at: directory) }
        #expect(try loader.metadata(for: directory).fileIdentity != original)
    }

    @Test
    func testFileSystemIdentityValidationUsesTheDedicatedProvider() throws {
        let url = URL(filePath: "/virtual/directory", directoryHint: .isDirectory)
        let expectedIdentity = FileIdentity(device: 7, inode: 42)
        let counters = MetadataProbeCounters()
        let loader = ScanMetadataLoader(fileSystemInfoProvider: { requestedURL, _ in
            #expect(requestedURL == url)
            counters.recordLstat()
            return (expectedIdentity, 1)
        })

        #expect(try loader.fileSystemIdentity(at: url) == expectedIdentity)
        #expect(throws: Never.self) { try loader.validateFileSystemIdentity(expectedIdentity, at: url) }
        #expect(counters.lstatCount == 2)
    }

    @Test
    func testFileSystemIdentityValidationFailsClosedForMissingOrChangedIdentity() throws {
        let url = URL(filePath: "/virtual/directory", directoryHint: .isDirectory)
        let expectedIdentity = FileIdentity(device: 7, inode: 42)
        for currentIdentity in [nil, FileIdentity(device: 7, inode: 43)] {
            let loader = ScanMetadataLoader(fileSystemInfoProvider: { _, _ in
                (currentIdentity, 1)
            })

            #expect { try loader.validateFileSystemIdentity(expectedIdentity, at: url) } throws: { error in
                let nsError = error as NSError
                #expect(nsError.domain == NSPOSIXErrorDomain)
                #expect(nsError.code == Int(ESTALE))
                #expect(nsError.userInfo[NSURLErrorKey] as? URL == url)
                return true
            }
        }
    }

    @Test
    func testCloneProbeRequestsPhysicalDeviceIdentity() {
        #expect(ScanMetadataLoader.cloneProbeOptions & UInt32(FSOPT_RETURN_REALDEV) != 0)
    }

    @Test
    func testDatalessFlagClassification() {
        #expect(ScanMetadataLoader.isDataless(fileFlags: UInt32(SF_DATALESS)))
        #expect(!(ScanMetadataLoader.isDataless(fileFlags: nil)))
        #expect(!(ScanMetadataLoader.isDataless(fileFlags: 0)))
        #expect(!(ScanMetadataLoader.isDataless(fileFlags: UInt32(UF_HIDDEN))))
    }

    @Test
    func testMetadataCarriesDatalessFlag() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "placeholder.bin")
        try Data([0xA5]).write(to: fileURL)
        let loader = ScanMetadataLoader(
            fileStatusProvider: { requestedURL in
                #expect(requestedURL == fileURL)
                return ScanMetadataLoader.FileStatus(
                    fileFlags: UInt32(SF_DATALESS),
                    isDirectory: false
                )
            }
        )

        #expect(try loader.metadata(for: fileURL).isDataless)
    }

    @Test
    func testDatalessStatusUsesFileTypeFromLstatProvider() {
        let urlWithoutDirectoryHint = URL(filePath: "/virtual/cloud-folder", directoryHint: .notDirectory)
        let loader = ScanMetadataLoader(
            fileStatusProvider: { requestedURL in
                #expect(requestedURL == urlWithoutDirectoryHint)
                return ScanMetadataLoader.FileStatus(
                    fileFlags: UInt32(SF_DATALESS),
                    isDirectory: true
                )
            }
        )

        #expect(!(urlWithoutDirectoryHint.hasDirectoryPath))
        #expect(loader.datalessStatus(at: urlWithoutDirectoryHint)?.isDirectory == true)
    }

    @Test
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
        let totalFileSize = try #require(values.totalFileSize)

        let metadata = try ScanMetadataLoader().metadata(for: fileURL)

        #expect(totalFileSize > values.fileSize ?? 0)
        #expect(metadata.logicalSize == Int64(totalFileSize))
    }

    @Test
    func testMissingAllocatedSizeUsesFileSystemBlockFallback() {
        let url = URL(filePath: "/virtual/sparse.bin")
        let loader = ScanMetadataLoader(
            fileAllocatedSizeProvider: { requestedURL in
                #expect(requestedURL == url)
                return 8_192
            }
        )

        let metadata = loader.metadata(for: url, prefetchedResourceValues: URLResourceValues())

        #expect(metadata.allocatedSize == 8_192)
        #expect(metadata.dataAllocatedSize == 8_192)
    }

    @Test
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

        #expect(firstMetadata.cloneIdentity == nil)
        #expect(secondMetadata.cloneIdentity == nil)
        #expect(counters.probeCount == 1)
    }

    @Test
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

        #expect(cache.cloneMetadata(for: URL(filePath: "/Users/example/first.bin")).identity == nil)
        #expect(cache.cloneMetadata(for: URL(filePath: "/Volumes/External/second.bin")).identity == nil)

        #expect(counters.probeCount == 2)
    }

    @Test
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
            #expect(cache.cloneMetadata(for: URL(filePath: path, directoryHint: .notDirectory)).identity == nil)
        }
        #expect(counters.probeCount == 1)

        #expect(
            cache.cloneMetadata(
                for: URL(
                    filePath: siblingRootPath + "/third.bin",
                    directoryHint: .notDirectory
                )
            ).identity == nil)
        #expect(counters.probeCount == 2)
    }

    @Test
    func testHardLinksDeduplicateAcrossBulkAndFoundationMetadata() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let originalURL = rootURL.appending(path: "a-original.bin")
        let linkedURL = rootURL.appending(path: "z-linked.bin")
        try Data(repeating: 0xA5, count: 8_192).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let loader = ScanMetadataLoader()
        let bulkValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: loader,
                cancellationCheck: {}
            ))
        let bulk = try #require(bulkValue)
        let nativeMetadata = try #require(bulk.entries.first { $0.url == originalURL }?.metadata)
        #expect(nativeMetadata.allocatedSize > 0)
        let nativeClaim = try #require(
            SharedAllocationDeduplicator.claim(
                for: nativeMetadata, ownerNodeID: originalURL.path, path: originalURL.path
            ))

        for fallbackMetadata in [
            try loader.metadata(for: linkedURL),
            try loader.atomicSummaryMetadata(for: linkedURL),
        ] {
            #expect(fallbackMetadata.linkCount == 2)
            #expect(fallbackMetadata.fileIdentity == nativeMetadata.fileIdentity)
            let fallbackClaim = try #require(
                SharedAllocationDeduplicator.claim(
                    for: fallbackMetadata, ownerNodeID: linkedURL.path, path: linkedURL.path
                ))
            let accumulator = SharedAllocationOwnerAccumulator([nativeClaim, fallbackClaim])
            #expect(accumulator.duplicateAllocatedSizeByOwner == [linkedURL.path: nativeMetadata.allocatedSize])
        }
    }

    @Test
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

        #expect(metadata.linkCount == 2)
        #expect(metadata.fileIdentity != nil)
    }

    @Test
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

        #expect(metadata.linkCount == 1)
        #expect(metadata.fileIdentity == nil)
    }

    @Test
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

        #expect(firstMetadata.linkCount == 1)
        #expect(firstMetadata.fileIdentity == nil)
        #expect(secondMetadata.linkCount == 1)
        #expect(secondMetadata.fileIdentity == nil)
        #expect(counters.probeCount == 1)
        #expect(counters.lstatCount == 0)
    }

    @Test
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

        #expect(firstMetadata.linkCount == 2)
        #expect(firstMetadata.fileIdentity != nil)
        #expect(secondMetadata.linkCount == 2)
        #expect(secondMetadata.fileIdentity != nil)
        #expect(counters.probeCount == 1)
        #expect(counters.lstatCount == 2)
    }

    @Test
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

        #expect(metadataWithoutVolume.linkCount == 1)
        #expect(metadataWithoutVolume.fileIdentity == nil)
        #expect(metadataWithVolume.linkCount == 2)
        #expect(metadataWithVolume.fileIdentity != nil)
        #expect(counters.probeCount == 2)
        #expect(counters.lstatCount == 1)
    }

    @Test
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

        #expect(metadata.isSymbolicLink)
        #expect(metadata.fileIdentity == FileIdentity(device: 1, inode: 42))
        #expect(counters.lstatCount == 1)
    }

    @Test
    func testVolumeTokenDoesNotSplitNativeHardLinkIdentity() {
        let native = FileIdentity(device: 7, inode: 42)
        let enriched = FileIdentity(device: 7, inode: 42, volumeToken: 123)
        #expect(native == enriched)
        #expect(Set([native, enriched]).count == 1)
        #expect([native: "owner"][enriched] == "owner")
    }

    @Test
    func testVolumeTokenPreservationRequiresMatchingFileIDAndKnownEncoding() {
        let native = FileIdentity(device: 7, inode: 42)
        let data = [UInt64(42).littleEndian, UInt64(123).littleEndian].withUnsafeBytes { Data($0) }
        let resource = FileIdentity(resourceIdentifier: data)
        #expect(
            native.preservingVolumeIdentity(from: resource).darwinIdentity
                == FileIdentity.DarwinIdentity(fileID: 42, volumeToken: 123))
        #expect(FileIdentity(device: 7, inode: 43).preservingVolumeIdentity(from: resource).darwinIdentity == nil)
        #expect(native.preservingVolumeIdentity(from: nil).darwinIdentity == nil)
        for length in [0, 8, 15, 17, 32] {
            let unfamiliar = FileIdentity(resourceIdentifier: Data(repeating: 0, count: length))
            #expect(unfamiliar.darwinIdentity == nil)
            #expect(native.preservingVolumeIdentity(from: unfamiliar).darwinIdentity == nil)
        }
    }

    @Test
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

        #expect(metadata.isDirectory)
        #expect(metadata.fileIdentity == FileIdentity(device: 7, inode: 42))
        #expect(metadata.linkCount == 1)
        #expect(counters.lstatCount == 1)
    }

    @Test
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

        #expect(metadata.isSymbolicLink)
        #expect(metadata.fileIdentity == nil)
        #expect(metadata.linkCount == 1)
        #expect(counters.lstatCount == 0)
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
            .isReadableKey,
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
