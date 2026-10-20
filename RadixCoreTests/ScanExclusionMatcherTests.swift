import Foundation
import Testing

@testable import RadixCore

struct ScanExclusionMatcherTests {
    @Test(arguments: [true, false])
    func testWildcardOnlyPatternsMatchOriginalNames(isCaseSensitive: Bool) {
        for pattern in ["*", "**", "*/", "**/"] {
            let matcher = ScanExclusionMatcher(
                patterns: [pattern], rootPath: "/RadixProject",
                volumeSupportsCaseSensitiveNames: isCaseSensitive
            )
            for parentPath in ["/RadixProject", "/RadixProject/Nested"] {
                for isDirectory in [false, true] {
                    let expected = isDirectory || !pattern.hasSuffix("/")
                    #expect(matcher.excludesKnownNormalizedPath(
                        parentPath + "/Äß.txt", isDirectory: isDirectory
                    ) == expected, Comment(rawValue: "\(pattern), directory=\(isDirectory)"))
                    #expect(matcher.excludesKnownNormalizedChild(
                        named: "Äß.txt", under: parentPath, isDirectory: isDirectory
                    ) == expected, Comment(rawValue: "\(pattern), child directory=\(isDirectory)"))
                }
            }
        }
    }

    @Test(arguments: [true, false])
    func testEveryMatcherStrategyUsesVolumeCasePolicy(isCaseSensitive: Bool) {
        let rootPath = "/RadixProject"
        let cases: [(String, String, Bool, Bool)] = [
            ("node_modules/", "Node_Modules", true, true),
            ("node_modules/", "Node_Modules", false, false),
            (".DS_Store", ".ds_store", false, true),
            ("debug-*", "DEBUG-output", false, true),
            ("*-cache", "image-CACHE", false, true),
            ("*temporary*", "my-TEMPORARY-file", false, true),
            ("file?.txt", "FILEß.TXT", false, true),
            ("file?.txt", "FILESS.TXT", false, false),
            ("foo*bar*baz", "FOO-middle-BAR-end-BAZ", false, true),
            ("Sources/generated.swift", "SOURCES/Generated.Swift", false, true),
            ("Library/*", "LIBRARY/Caches", true, true),
            ("Library/*", "LIBRARY/Caches/file.bin", false, false),
            ("Library/?", "LIBRARY/ß", false, true),
            ("Library/?", "LIBRARY/a/b", false, false),
            ("**/cache/**/file?.txt", "SOURCES/CACHE/nested/FILEß.TXT", false, true),
            ("Sources/**", "SOURCES", true, true),
            ("Sources/**", "SOURCES", false, false),
            ("foo/**/bar", "FOO/BAR", false, true),
        ]
        for (pattern, relativePath, isDirectory, matchesInsensitive) in cases {
            let matcher = ScanExclusionMatcher(
                patterns: [pattern],
                rootPath: rootPath,
                volumeSupportsCaseSensitiveNames: isCaseSensitive
            )
            let path = "\(rootPath)/\(relativePath)"
            let url = URL(filePath: path)
            let expected = !isCaseSensitive && matchesInsensitive
            #expect(
                matcher.excludesKnownNormalizedPath(path, isDirectory: isDirectory) == expected,
                Comment(rawValue: "\(pattern) matching \(relativePath)"))
            #expect(
                matcher.excludesKnownNormalizedChild(
                    named: url.lastPathComponent,
                    under: url.deletingLastPathComponent().path,
                    isDirectory: isDirectory
                ) == expected,
                Comment(rawValue: "\(pattern) matching child \(relativePath)"))
        }
    }

    @Test(arguments: [true, false])
    func testUnicodeMatchingPreservesOriginalWildcardCharacters(isCaseSensitive: Bool) {
        let cases: [(String, String, Bool, Bool)] = [
            ("Ä.txt", "ä.txt", false, true),
            ("É.txt", "e\u{301}.txt", false, true),
            ("?.txt", "e\u{301}.txt", true, true),
            ("SS.txt", "ß.txt", false, true),
            ("SS*", "ßeta", false, true),
            ("*SS", "prefixß", false, true),
            ("*SS*", "prefixßsuffix", false, true),
            ("?.txt", "ß.txt", true, true),
            ("?.txt", "SS.txt", false, false),
            ("SS?.txt", "ßx.txt", false, true),
            ("ß?.txt", "SSx.txt", false, true),
            ("SS?.txt", "ß.txt", false, false),
            ("S?.txt", "ßx.txt", false, false),
            ("Σ.txt", "ς.txt", false, true),
            ("É.txt", "E.txt", false, false),
            ("İ.txt", "i.txt", false, false),
            ("É?.txt", "Ex.txt", false, false),
            ("İ?.txt", "ix.txt", false, false),
        ]
        for (pattern, basename, matchesSensitive, matchesInsensitive) in cases {
            let matcher = ScanExclusionMatcher(
                patterns: [pattern],
                rootPath: "/RadixProject",
                volumeSupportsCaseSensitiveNames: isCaseSensitive
            )
            let expected = isCaseSensitive ? matchesSensitive : matchesInsensitive
            #expect(
                matcher.excludesKnownNormalizedPath("/RadixProject/\(basename)", isDirectory: false) == expected,
                Comment(rawValue: "\(pattern) matching \(basename)"))
            #expect(
                matcher.excludesKnownNormalizedChild(
                    named: basename,
                    under: "/RadixProject",
                    isDirectory: false
                ) == expected,
                Comment(rawValue: "\(pattern) matching child \(basename)"))
        }
    }

    @Test(arguments: [true, false])
    func testRootPrefixUsesVolumePolicyAndOriginalMatchedRange(isCaseSensitive: Bool) {
        let matcher = ScanExclusionMatcher(
            patterns: ["Sources/generated.swift"],
            rootPath: "/RadixSS",
            volumeSupportsCaseSensitiveNames: isCaseSensitive
        )
        #expect(
            matcher.excludesKnownNormalizedPath("/radixß/Sources/generated.swift", isDirectory: false)
                == !isCaseSensitive)
        #expect(
            matcher.excludesKnownNormalizedChild(
                named: "generated.swift", under: "/radixß/Sources", isDirectory: false
            ) == !isCaseSensitive)
        #expect(!matcher.excludesKnownNormalizedPath("/RadixSS-other/Sources/generated.swift", isDirectory: false))
        #expect(!matcher.excludesKnownNormalizedPath("/RadixSS", isDirectory: true))
    }

    @Test
    func testRootURLAndRootPathInitializersShareExplicitCasePolicy() {
        let rootURL = URL(filePath: "/RadixProject", directoryHint: .isDirectory)
        for isCaseSensitive in [true, false] {
            let matchers = [
                ScanExclusionMatcher(
                    patterns: ["*.log"], rootURL: rootURL,
                    volumeSupportsCaseSensitiveNames: isCaseSensitive
                ),
                ScanExclusionMatcher(
                    patterns: ["*.log"], rootPath: rootURL.path,
                    volumeSupportsCaseSensitiveNames: isCaseSensitive
                ),
            ]
            for matcher in matchers {
                #expect(matcher.excludesKnownNormalizedPath("/RadixProject/DEBUG.LOG", isDirectory: false)
                    == !isCaseSensitive)
                #expect(matcher.excludesKnownNormalizedPath("/RadixProject/debug.log", isDirectory: false))
            }
        }
    }

    @Test
    func testUnavailableVolumeCapabilityKeepsCaseSensitiveMatching() {
        let rootURL = URL(filePath: "/RadixMissingVolume-\(UUID().uuidString)", directoryHint: .isDirectory)
        let values = try? rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        #expect(values?.volumeSupportsCaseSensitiveNames == nil)
        let matcher = ScanExclusionMatcher(patterns: ["node_modules/"], rootURL: rootURL)
        #expect(!matcher.excludesKnownNormalizedChild(
            named: "Node_Modules", under: rootURL.path, isDirectory: true
        ))
        #expect(matcher.excludesKnownNormalizedChild(
            named: "node_modules", under: rootURL.path, isDirectory: true
        ))
    }

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
