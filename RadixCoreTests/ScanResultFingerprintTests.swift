import Foundation
import Testing

@testable import RadixCore

struct ScanResultFingerprintTests {
    @Test
    func testResultFingerprintCoversIdentityCloneAndModificationTime() {
        let baseline = scanResultFingerprint(Self.fixtureStore())
        let changedFileIdentity = scanResultFingerprint(
            Self.fixtureStore(
                fileIdentity: FileIdentity(device: 1, inode: 3)
            ))
        let changedCloneIdentity = scanResultFingerprint(
            Self.fixtureStore(
                cloneIdentity: CloneIdentity(device: 1, cloneID: 4)
            ))
        let changedModificationTime = scanResultFingerprint(
            Self.fixtureStore(
                lastModified: Date(timeIntervalSinceReferenceDate: 2)
            ))

        #expect(changedFileIdentity != baseline)
        #expect(changedCloneIdentity != baseline)
        #expect(changedModificationTime != baseline)
    }

    @Test
    func testWarningFingerprintCoversCategoryPathAndMessage() {
        let baseline = scanWarningFingerprint([
            ScanWarning(path: "/blocked", message: "Denied", category: .permissionDenied)
        ])

        #expect(
            scanWarningFingerprint([
                ScanWarning(path: "/blocked", message: "Denied", category: .fileSystem)
            ]) != baseline)
        #expect(
            scanWarningFingerprint([
                ScanWarning(path: "/other", message: "Denied", category: .permissionDenied)
            ]) != baseline)
        #expect(
            scanWarningFingerprint([
                ScanWarning(path: "/blocked", message: "Unavailable", category: .permissionDenied)
            ]) != baseline)
    }

    @Test
    func testWarningFingerprintSeparatesDelimiterBearingFields() {
        let pathContainsDelimiter = [
            ScanWarning(path: "/blocked|detail", message: "Denied", category: .permissionDenied)
        ]
        let messageContainsDelimiter = [
            ScanWarning(path: "/blocked", message: "detail|Denied", category: .permissionDenied)
        ]

        #expect(scanWarningFingerprint(pathContainsDelimiter) != scanWarningFingerprint(messageContainsDelimiter))
    }

    @Test
    func testWarningFingerprintsExposeOrderWithoutChangingSetIdentity() {
        let warnings = [
            ScanWarning(path: "/first", message: "Denied", category: .permissionDenied),
            ScanWarning(path: "/second", message: "Unavailable", category: .fileSystem),
        ]
        let reversed = warnings.reversed()

        #expect(scanWarningFingerprint(warnings) == scanWarningFingerprint(Array(reversed)))
        #expect(scanOrderedWarningFingerprint(warnings) != scanOrderedWarningFingerprint(Array(reversed)))
    }

    private static func fixtureStore(
        fileIdentity: FileIdentity = FileIdentity(device: 1, inode: 2),
        cloneIdentity: CloneIdentity? = CloneIdentity(device: 1, cloneID: 3),
        lastModified: Date = Date(timeIntervalSinceReferenceDate: 1)
    ) -> FileTreeStore {
        FileTreeStore(
            root: FileNodeRecord(
                id: "/fingerprint.dat",
                url: URL(filePath: "/fingerprint.dat"),
                name: "fingerprint.dat",
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: 4_096,
                dataAllocatedSize: 2_048,
                logicalSize: 1_024,
                descendantFileCount: 1,
                lastModified: lastModified,
                fileIdentity: fileIdentity,
                linkCount: 2,
                cloneIdentity: cloneIdentity,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            ))
    }
}
