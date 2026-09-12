import Foundation
import Testing

@testable import RadixCore

struct ScanExclusionMatcherTests {
    @Test
    func testCommonBasenamePatternsPreserveExactAndSimpleGlobSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ScanExclusionMatcher.commonPresetPatterns,
            rootPath: rootPath
        )

        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/Packages/node_modules", isDirectory: true))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/Packages/node_modules", isDirectory: false)))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/Logs/debug.log", isDirectory: false))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/Logs/debug.log.1", isDirectory: false)))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/.DS_Store", isDirectory: false))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/build", isDirectory: true))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/build", isDirectory: false)))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/Project/DerivedData", isDirectory: true))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/Sources/App.swift", isDirectory: false)))
    }

    @Test
    func testKnownChildMatchingPreservesBasenameAndPathRules() {
        let rootPath = "/Users/alex"
        let matcher = ScanExclusionMatcher(
            patterns: ["*.log", "Sources/**/generated.swift"],
            rootPath: rootPath
        )
        let cases = [
            ("debug.log", "/Users/alex/Logs", false, true),
            ("generated.swift", "/Users/alex/Sources/Module", false, true),
            ("App.swift", "/Users/alex/Sources", false, false),
        ]

        for (name, parentPath, isDirectory, expected) in cases {
            #expect(
                matcher.excludesKnownNormalizedChild(
                    named: name,
                    under: parentPath,
                    isDirectory: isDirectory
                ) == expected, Comment(rawValue: parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"))
        }

        let filesystemRootMatcher = ScanExclusionMatcher(
            patterns: ["System/**"],
            rootPath: "/"
        )
        #expect(
            filesystemRootMatcher.excludesKnownNormalizedChild(
                named: "System",
                under: "/",
                isDirectory: true
            ))
    }

    @Test
    func testSimpleBasenameGlobStrategiesPreserveWildcardSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["debug-*", "*-cache", "*temporary*", "file?.txt"],
            rootPath: rootPath
        )

        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/debug-output", isDirectory: false))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/image-cache", isDirectory: false))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/my-temporary-file", isDirectory: false))
        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/file1.txt", isDirectory: false))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/file10.txt", isDirectory: false)))
    }

    @Test
    func testPathGlobSingleStarStillDoesNotCrossDirectorySeparators() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["Library/*"],
            rootPath: rootPath
        )

        #expect(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches", isDirectory: true))
        #expect(!(matcher.excludesKnownNormalizedPath("\(rootPath)/Library/Caches/file.bin", isDirectory: false)))
    }

    @Test
    func testComplexGlobUsesBoundedMatchingAndPreservesGlobstarSemantics() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["**/cache/**/file?.txt", "*a*a*a*a*a*a*a*a*b"],
            rootPath: rootPath
        )

        #expect(
            matcher.excludesKnownNormalizedPath(
                "\(rootPath)/Sources/cache/nested/file1.txt",
                isDirectory: false
            ))
        #expect(
            !(matcher.excludesKnownNormalizedPath(
                "\(rootPath)/Sources/cache/nested/file10.txt",
                isDirectory: false
            )))
        #expect(
            !(matcher.excludesKnownNormalizedPath(
                "\(rootPath)/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                isDirectory: false
            )))
    }

    @Test(arguments: [
        ("Packages/pkg/node_modules", true, true),
        ("Logs/./debug.log", false, true),
        ("Library/Caches/build/artifact.o", false, true),
        ("Sources/App.swift", false, false),
    ])
    func testURLMatchingNormalizesPaths(relativePath: String, isDirectory: Bool, excluded: Bool) {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: ["node_modules/", "*.log", "Library/Caches/**"], rootPath: rootPath)
        #expect(matcher.excludes(URL(filePath: "\(rootPath)/\(relativePath)"), isDirectory: isDirectory) == excluded)
    }

    @Test
    func testCloudStorageLocationRecognizesManagedRootsWithoutNearPrefixMatches() {
        #expect(CloudStorageLocation.contains(path: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"))
        #expect(
            CloudStorageLocation.contains(path: "/Users/blair/Library/Mobile Documents/com~apple~CloudDocs/file.bin"))
        #expect(!(CloudStorageLocation.contains(path: "/Users/alex/Library/CloudStorageBackup/file.bin")))
        #expect(!(CloudStorageLocation.contains(path: "/Users/alex/Library/Mobile Documents Backup/file.bin")))
        #expect(!(CloudStorageLocation.contains(path: "/Library/CloudStorage/file.bin")))
    }

    @Test
    func testCloudStorageLocationClassifiesDirectItemsWithoutRootLookup() {
        let impact = CloudStorageLocation.impact(
            of: URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"),
            cloudRootExists: { _ in
                Issue.record("Direct cloud items should not require a root existence check.")
                return false
            }
        )

        #expect(impact == .storedInCloud)
    }

    @Test
    func testCloudStorageLocationOnlyClassifiesAncestorsWhenManagedRootExists() {
        let libraryURL = URL(filePath: "/Users/alex/Library", directoryHint: .isDirectory)

        #expect(CloudStorageLocation.impact(of: libraryURL, cloudRootExists: { _ in false }) == nil)
        #expect(
            CloudStorageLocation.impact(
                of: libraryURL,
                cloudRootExists: { $0.path == "/Users/alex/Library/CloudStorage" }
            ) == .containsCloudStorage)
        #expect(
            CloudStorageLocation.impact(
                of: URL(filePath: "/Users/alex/Documents"),
                cloudRootExists: { _ in true }
            ) == nil)
    }
}
