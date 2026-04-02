import XCTest
@testable import RadixCore

final class ScanEngineTests: XCTestCase {
    func testPackagesAreLeafNodesByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.isDirectory)
        XCTAssertFalse(packageNode.containsChildren)
    }

    func testPackagesCanBeExpandedWhenEnabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(treatPackagesAsDirectories: true)
        )
        let packageNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Sample.app" }))

        XCTAssertTrue(packageNode.containsChildren)
        XCTAssertEqual(packageNode.descendantFileCount, 1)
    }

    func testSymbolicLinksAreNotTraversed() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let nestedFile = realDirectory.appending(path: "payload.txt")
        let symlinkURL = rootURL.appending(path: "Alias")

        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let aliasNode = try XCTUnwrap(snapshot.root.children.first(where: { $0.name == "Alias" }))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertFalse(aliasNode.containsChildren)
        XCTAssertEqual(aliasNode.itemKind, "Alias")
    }

    func testDirectoryChildrenAreOrderedDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alpha = rootURL.appending(path: "alpha.txt")
        let zeta = rootURL.appending(path: "zeta.txt")

        try Data(repeating: 0x41, count: 16).write(to: zeta)
        try Data(repeating: 0x42, count: 16).write(to: alpha)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        XCTAssertEqual(snapshot.root.children.map(\.name), ["alpha.txt", "zeta.txt"])
    }

    func testProgressFractionIsMonotonicAndCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<3 {
            let directoryURL = rootURL.appending(path: "Folder-\(directoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<4 {
                let fileURL = directoryURL.appending(path: "File-\(fileIndex).txt")
                try Data(repeating: UInt8(fileIndex), count: 1_024).write(to: fileURL)
            }
        }

        let engine = ScanEngine()
        var progressFractions: [Double] = []

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            }
        }

        XCTAssertFalse(progressFractions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressFractions.last), 1, accuracy: 0.0001)

        for pair in zip(progressFractions, progressFractions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
        }
    }

    func testByteEstimatePreventsPrematureFinalizingProgress() {
        var metrics = ScanMetrics()
        metrics.estimatedTotalBytes = 10_000
        metrics.discoveredItems = 6
        metrics.completedItems = 5
        metrics.filesVisited = 500
        metrics.bytesDiscovered = 1_200

        metrics.recalculateProgress()

        XCTAssertLessThan(metrics.progressFraction, 0.5)
        XCTAssertFalse(metrics.isFinalizing)
    }
}

private func finishedSnapshot(target: ScanTarget, options: ScanOptions) async throws -> ScanSnapshot {
    let engine = ScanEngine()

    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    XCTFail("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
