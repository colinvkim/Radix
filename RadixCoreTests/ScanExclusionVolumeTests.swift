import Foundation
import Testing

@testable import RadixCore

struct ScanExclusionVolumeTests {
    @Test(arguments: [false, true])
    func testScansMatchVolumeCasePolicyAndPreserveOriginalPaths(forceFoundation: Bool) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "RadixCaseExclusions-\(UUID().uuidString)", directoryHint: .isDirectory)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let isCaseSensitive = try #require(rootURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames as Bool?)
        let urlMatcher = ScanExclusionMatcher(patterns: ["node_modules/"], rootURL: rootURL)
        #expect(urlMatcher.excludesKnownNormalizedChild(
            named: "Node_Modules", under: rootURL.path, isDirectory: true
        ) == !isCaseSensitive)
        let excludedDirectory = rootURL.appending(path: "Node_Modules", directoryHint: .isDirectory)
        let sourcesDirectory = rootURL.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: excludedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        let payload = excludedDirectory.appending(path: "payload.bin")
        let log = rootURL.appending(path: "DEBUG.LOG")
        let generated = sourcesDirectory.appending(path: "Generated.Swift")
        let retained = rootURL.appending(path: "ReadMe.TXT")
        for file in [payload, log, generated, retained] {
            try Data([0x42]).write(to: file)
        }

        var options = ScanOptions()
        options.includeHiddenFiles = true
        options.autoSummarizeDirectories = false
        options.exclusionPatterns = ["node_modules/", "*.log", "sources/generated.swift"]
        let engine = forceFoundation
            ? ScanEngine(directoryContents: { url, keys, enumerationOptions, cancellationCheck in
                try cancellationCheck()
                return try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions
                )
            })
            : ScanEngine()
        var snapshot: ScanSnapshot?
        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let finished) = event {
                snapshot = finished
            }
        }
        let finished = try #require(snapshot)
        var expectedPaths = Set([rootURL.path, sourcesDirectory.path, retained.path])
        if isCaseSensitive {
            expectedPaths.formUnion([excludedDirectory.path, payload.path, log.path, generated.path])
        }
        #expect(Set(finished.treeStore.indexedNodeIDs()) == expectedPaths)
        #expect(finished.treeStore.node(id: retained.path)?.name == "ReadMe.TXT")
        #expect(finished.scanWarnings.isEmpty)
    }
}
