import Foundation
import Testing

@testable import RadixCore

struct TrashSafetyPolicyTests {
    @Test
    func testFirmlinkParserHandlesCommentsWhitespaceAndDefaultDataPaths() {
        let entries = TrashSafetyPolicy.parseFirmlinkEntries("""
            # startup-volume boundaries

              /Visible\tCustom/Data
            /Default
            \t# ignored comment
            /WithSpaces    Other/Data\r
            /
            """)

        #expect(entries == [
            .init(visiblePath: "/Visible", dataRelativePath: "Custom/Data"),
            .init(visiblePath: "/Default", dataRelativePath: "Default"),
            .init(visiblePath: "/WithSpaces", dataRelativePath: "Other/Data"),
        ])
    }

    @Test
    func testFirmlinkFileProtectsBothNamespacesWithoutProtectingDescendants() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fileURL = fixture.appending(path: "firmlinks")
        try Data("/Visible Custom/Data\n/Default\n".utf8).write(to: fileURL)

        let policy = TrashSafetyPolicy(
            homeDirectory: URL(filePath: "/Users/example"),
            mountedVolumeURLs: [],
            firmlinkFileURL: fileURL
        )

        for path in ["/Visible", "/System/Volumes/Data/Custom/Data", "/Default", "/System/Volumes/Data/Default"] {
            #expect(policy.blockReason(for: URL(filePath: path)) == .protectedRoot(path: path))
        }
        #expect(policy.blockReason(for: URL(filePath: "/Visible/child")) == nil)
        #expect(policy.blockReason(for: URL(filePath: "/opt")) == nil)
    }

    @Test(arguments: FirmlinkFileFailure.allCases)
    func testUnreadableOrEmptyFirmlinkFilesRetainFallbackProtection(failure: FirmlinkFileFailure) throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fileURL = fixture.appending(path: "firmlinks")
        switch failure {
        case .missing:
            break
        case .empty:
            try Data().write(to: fileURL)
        case .comments:
            try Data("# no mappings\n \t\n/\n".utf8).write(to: fileURL)
        case .invalidUTF8:
            try Data([0xff, 0xfe]).write(to: fileURL)
        case .directory:
            try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        }

        let policy = TrashSafetyPolicy(
            homeDirectory: URL(filePath: "/Users/example"),
            mountedVolumeURLs: [],
            firmlinkFileURL: fileURL
        )

        #expect(policy.blockReason(for: URL(filePath: "/opt")) == .protectedRoot(path: "/opt"))
        #expect(
            policy.blockReason(for: URL(filePath: "/System/Volumes/Data/opt"))
                == .protectedRoot(path: "/System/Volumes/Data/opt"))
    }
}

enum FirmlinkFileFailure: CaseIterable, Sendable {
    case missing, empty, comments, invalidUTF8, directory
}
