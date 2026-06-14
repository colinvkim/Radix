import XCTest
@testable import RadixCore

final class ScanExclusionMatcherTests: XCTestCase {
    func testMatcherHandlesManyExcludedChildren() {
        let rootPath = "/tmp/RadixProject"
        let matcher = ScanExclusionMatcher(
            patterns: [
                "node_modules/",
                "*.log",
                "Library/Caches/**"
            ],
            rootPath: rootPath,
            includeCloudStorage: false,
            cloudStorageRootPath: "\(rootPath)/Library/CloudStorage"
        )

        for index in 0..<512 {
            XCTAssertTrue(
                matcher.excludes(
                    URL(filePath: "\(rootPath)/Packages/pkg\(index)/node_modules", directoryHint: .isDirectory),
                    isDirectory: true
                )
            )
            XCTAssertTrue(
                matcher.excludes(
                    URL(filePath: "\(rootPath)/Logs/./debug-\(index).log"),
                    isDirectory: false
                )
            )
        }

        XCTAssertTrue(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Library/Caches/build/artifact.o"),
                isDirectory: false
            )
        )
        XCTAssertTrue(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Library/CloudStorage/Dropbox/remote.bin"),
                isDirectory: false
            )
        )
        XCTAssertFalse(
            matcher.excludes(
                URL(filePath: "\(rootPath)/Sources/App.swift"),
                isDirectory: false
            )
        )
    }
}
