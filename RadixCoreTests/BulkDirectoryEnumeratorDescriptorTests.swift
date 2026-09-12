import Darwin
import XCTest
@testable import RadixCore

final class BulkDirectoryEnumeratorDescriptorTests: XCTestCase {
    func testNativeNameRejectsUnsafeOrLossyComponents() {
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: []))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array(".".utf8)))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("..".utf8)))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: Array("a/b".utf8)))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x61, 0, 0x62]))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0xC0, 0xAF]))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x80]))
        XCTAssertNil(BulkDirectoryEnumerator.NativeName(fileSystemBytes: [0x81]))
    }

    func testUnicodeNativeNamesOpenExactChildrenRelativeToDescriptor() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let names = ["caf\u{00E9}.txt", "emoji-\u{1F680}.txt", "\u{65E5}\u{672C}\u{8A9E}.txt"]
        for (offset, name) in names.enumerated() {
            try Data([UInt8(offset + 1)]).write(to: rootURL.appending(path: name))
        }

        let result = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            cancellationCheck: {}
        ))
        XCTAssertEqual(result.entries.count, names.count)

        let parentDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { Darwin.close(parentDescriptor) }
        for entry in result.entries {
            let nativeName = try XCTUnwrap(entry.nativeName, entry.url.lastPathComponent)
            let childDescriptor = nativeName.withUnsafeFileSystemRepresentation { namePointer in
                openat(parentDescriptor, namePointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            XCTAssertGreaterThanOrEqual(childDescriptor, 0, entry.url.lastPathComponent)
            if childDescriptor >= 0 {
                Darwin.close(childDescriptor)
            }
        }
    }

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
            throw XCTSkip("The test filesystem rejects invalid UTF-8 child names.")
        }
        Darwin.close(childDescriptor)

        let result = try BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            entryInclusion: { _, _ in false },
            cancellationCheck: {}
        )
        XCTAssertNil(result)
    }

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
                throw XCTSkip("The test filesystem folds canonically equivalent names.")
            }
            Darwin.close(childDescriptor)
        }

        let excludedResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            entryInclusion: { _, _ in false },
            cancellationCheck: {}
        ))
        XCTAssertTrue(excludedResult.entries.isEmpty)

        XCTAssertNil(try BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: ScanMetadataLoader(),
            entryInclusion: { _, _ in true },
            cancellationCheck: {}
        ))
    }

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
        let pathResult = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))
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

        XCTAssertFalse(handle.isOpen)
        XCTAssertEqual(descriptorItemCount, pathResult.enumeratedItemCount)
        let pathEntries = Dictionary(uniqueKeysWithValues: pathResult.entries.map {
            ($0.url.lastPathComponent, $0)
        })
        let nativeEntries = Dictionary(uniqueKeysWithValues: descriptorEntries.map {
            ($0.url.lastPathComponent, $0)
        })
        XCTAssertEqual(Set(nativeEntries.keys), Set(pathEntries.keys))
        for name in pathEntries.keys {
            let pathMetadata = try XCTUnwrap(pathEntries[name]?.metadata)
            let nativeMetadata = try XCTUnwrap(nativeEntries[name]?.metadata)
            if nativeMetadata.isDirectory || nativeMetadata.isSymbolicLink {
                XCTAssertNotNil(nativeEntries[name]?.nativeName, name)
            } else {
                // ASCII regular files, including hard links, need only the URL.
                XCTAssertNil(nativeEntries[name]?.nativeName, name)
            }
            XCTAssertEqual(nativeMetadata.isDirectory, pathMetadata.isDirectory, name)
            XCTAssertEqual(nativeMetadata.isPackage, pathMetadata.isPackage, name)
            XCTAssertEqual(nativeMetadata.isSymbolicLink, pathMetadata.isSymbolicLink, name)
            XCTAssertEqual(nativeMetadata.logicalSize, pathMetadata.logicalSize, name)
            XCTAssertEqual(nativeMetadata.allocatedSize, pathMetadata.allocatedSize, name)
            XCTAssertEqual(nativeMetadata.dataAllocatedSize, pathMetadata.dataAllocatedSize, name)
            XCTAssertEqual(nativeMetadata.fileIdentity, pathMetadata.fileIdentity, name)
            XCTAssertEqual(nativeMetadata.linkCount, pathMetadata.linkCount, name)
            XCTAssertEqual(nativeMetadata.cloneIdentity, pathMetadata.cloneIdentity, name)
            XCTAssertEqual(nativeMetadata.mayShareDataBlocks, pathMetadata.mayShareDataBlocks, name)
        }
    }

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

        XCTAssertFalse(handle.isOpen)
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

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

        XCTAssertThrowsError(try cursor.nextBatch(cancellationCheck: {})) { error in
            guard case BulkDirectoryEnumerator.StreamError.unavailable = error else {
                return XCTFail("Expected descriptor cursor fallback, got \(error)")
            }
        }
        XCTAssertFalse(handle.isOpen)
        XCTAssertNil(try cursor.nextBatch(cancellationCheck: {}))
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
