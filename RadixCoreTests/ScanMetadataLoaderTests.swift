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

        let metadata = ScanMetadataLoader.nodeMetadata(
            for: originalURL,
            resourceValues: try resourceValuesWithoutIdentity(for: originalURL)
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

        let metadata = ScanMetadataLoader.nodeMetadata(
            for: missingURL,
            resourceValues: try resourceValuesWithoutIdentity(for: sourceURL)
        )

        XCTAssertEqual(metadata.linkCount, 1)
        XCTAssertNil(metadata.fileIdentity)
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
}
