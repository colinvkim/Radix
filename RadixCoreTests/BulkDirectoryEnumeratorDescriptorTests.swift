import Darwin
import Foundation
import Testing

@testable import RadixCore

struct BulkDirectoryEnumeratorDescriptorTests {
    @Test
    func testNativeNameRejectsUnsafeOrLossyComponents() {
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: []) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array(".".utf8)) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("..".utf8)) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("a/b".utf8)) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x61, 0, 0x62]) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0xC0, 0xAF]) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x80]) == nil)
        #expect(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x81]) == nil)
    }

    @Test
    func testUnicodeNativeNamesOpenExactChildrenRelativeToDescriptor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let names = ["caf\u{00E9}.txt", "emoji-\u{1F680}.txt", "\u{65E5}\u{672C}\u{8A9E}.txt"]
        for (offset, name) in names.enumerated() {
            try Data([UInt8(offset + 1)]).write(to: rootURL.appending(path: name))
        }

        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)
        #expect(result.entries.count == names.count)

        let parentDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { Darwin.close(parentDescriptor) }
        for entry in result.entries {
            let nativeName = try #require(entry.nativeName, Comment(rawValue: entry.url.lastPathComponent))
            let childDescriptor = nativeName.withUnsafeFileSystemRepresentation { namePointer in
                openat(parentDescriptor, namePointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            #expect(childDescriptor >= 0, Comment(rawValue: entry.url.lastPathComponent))
            if childDescriptor >= 0 {
                Darwin.close(childDescriptor)
            }
        }
    }

    @Test(
        .enabled(
            if: try TestFileSystem.supportsNativeNames([[0x69, 0x6E, 0x76, 0x80]]),
            "Requires a filesystem supporting non-UTF-8 names"))
    func testInvalidUTF8FilesystemNameDisablesBulkDirectoryWhenFilesystemPermitsIt() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let parentDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { Darwin.close(parentDescriptor) }
        let invalidName: [UInt8] = [0x69, 0x6E, 0x76, 0x80, 0]
        let childDescriptor = invalidName.withUnsafeBytes { rawBuffer in
            openat(
                parentDescriptor,
                rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard childDescriptor >= 0 else {
            throw TestFixtureError("The test filesystem rejects invalid UTF-8 child names.")
        }
        Darwin.close(childDescriptor)

        let result = try BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            entryInclusion: { _, _ in false },
            cancellationCheck: {}
        )
        #expect(result == nil)
    }

    @Test(
        .enabled(
            if: try TestFileSystem.supportsNativeNames([Array("\u{00E9}.txt".utf8), Array("e\u{0301}.txt".utf8)]),
            "Requires a filesystem distinguishing canonically equivalent names"))
    func testCanonicallyCollidingNativeNamesOnlyDisableBulkWhenIncluded() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let parentDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { Darwin.close(parentDescriptor) }
        let names = ["\u{00E9}.txt", "e\u{0301}.txt"]

        for name in names {
            var bytes = Array(name.utf8) + [0]
            let childDescriptor = bytes.withUnsafeMutableBytes { rawBuffer in
                openat(
                    parentDescriptor,
                    rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard childDescriptor >= 0 else {
                throw TestFixtureError("The test filesystem folds canonically equivalent names.")
            }
            Darwin.close(childDescriptor)
        }

        let excludedResultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                entryInclusion: { _, _ in false },
                cancellationCheck: {}
            ))
        let excludedResult = try #require(excludedResultValue)
        #expect(excludedResult.entries.isEmpty)

        #expect(
            try BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                entryInclusion: { _, _ in true },
                cancellationCheck: {}
            ) == nil)
    }

    @Test
    func testDescriptorCursorMatchesPathCursor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let directoryURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.bin")
        let linkURL = rootURL.appending(path: "payload-link.bin")
        let symlinkURL = rootURL.appending(path: "payload-alias")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4A, count: 8_193).write(to: fileURL)
        try FileManager.default.linkItem(at: fileURL, to: linkURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)

        let metadataLoader = ScanMetadataLoader()
        let pathResultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            ))
        let pathResult = try #require(pathResultValue)
        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )
        var descriptorEntries: [DirectoryEntry] = []
        var descriptorItemCount = 0
        while let batch = try cursor.nextBatch(cancellationCheck: {}) {
            descriptorEntries.append(contentsOf: batch.entries)
            descriptorItemCount += batch.enumeratedItemCount
        }

        #expect(!(handle.isOpen))
        #expect(descriptorItemCount == pathResult.enumeratedItemCount)
        let pathEntries = Dictionary(
            uniqueKeysWithValues: pathResult.entries.map {
                ($0.url.lastPathComponent, $0)
            })
        let nativeEntries = Dictionary(
            uniqueKeysWithValues: descriptorEntries.map {
                ($0.url.lastPathComponent, $0)
            })
        #expect(Set(nativeEntries.keys) == Set(pathEntries.keys))
        for name in pathEntries.keys {
            let pathMetadata = try #require(pathEntries[name]?.metadata)
            let nativeMetadata = try #require(nativeEntries[name]?.metadata)
            if nativeMetadata.isDirectory || nativeMetadata.isSymbolicLink {
                #expect(nativeEntries[name]?.nativeName != nil, Comment(rawValue: name))
            } else {
                // ASCII regular files, including hard links, need only the URL.
                #expect(nativeEntries[name]?.nativeName == nil, Comment(rawValue: name))
            }
            #expect(nativeMetadata.isDirectory == pathMetadata.isDirectory, Comment(rawValue: name))
            #expect(nativeMetadata.isPackage == pathMetadata.isPackage, Comment(rawValue: name))
            #expect(nativeMetadata.isSymbolicLink == pathMetadata.isSymbolicLink, Comment(rawValue: name))
            #expect(nativeMetadata.logicalSize == pathMetadata.logicalSize, Comment(rawValue: name))
            #expect(nativeMetadata.allocatedSize == pathMetadata.allocatedSize, Comment(rawValue: name))
            #expect(nativeMetadata.dataAllocatedSize == pathMetadata.dataAllocatedSize, Comment(rawValue: name))
            #expect(nativeMetadata.fileIdentity == pathMetadata.fileIdentity, Comment(rawValue: name))
            #expect(nativeMetadata.linkCount == pathMetadata.linkCount, Comment(rawValue: name))
            #expect(nativeMetadata.cloneIdentity == pathMetadata.cloneIdentity, Comment(rawValue: name))
            #expect(nativeMetadata.mayShareDataBlocks == pathMetadata.mayShareDataBlocks, Comment(rawValue: name))
        }
    }

    @Test
    func testDescriptorCursorOwnsAndClosesHandleWhenDropped() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "payload.bin"))

        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        var cursor: BulkDirectoryEnumerator.Cursor? = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {}
        )
        _ = try cursor?.nextBatch(cancellationCheck: {})

        cursor = nil

        #expect(!(handle.isOpen))
        errno = 0
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test
    func testDescriptorCursorClosesHandleOnUnsupportedFallback() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data([0x1]).write(to: rootURL.appending(path: "payload.bin"))

        let descriptor = try openDirectoryDescriptor(at: rootURL)
        let handle = BulkDirectoryEnumerator.NativeDirectoryHandle(owning: descriptor)
        let cursor = try BulkDirectoryEnumerator.makeCursor(
            at: rootURL,
            owning: handle,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {},
            forcedUnavailableAfterBatchCount: 0
        )

        #expect { try cursor.nextBatch(cancellationCheck: {}) } throws: { error in
            guard case BulkDirectoryEnumerator.StreamError.unavailable = error else {
                Issue.record("Expected descriptor cursor fallback, got \(error)")
                return false
            }
            return true
        }
        #expect(!(handle.isOpen))
        #expect(try cursor.nextBatch(cancellationCheck: {}) == nil)
    }

    private func openDirectoryDescriptor(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }
}
