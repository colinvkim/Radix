import Foundation
import Testing

@testable import RadixCore

struct ScanComparisonSetupTests {
    @Test
    func testWarnsAndAllowsDifferentScanSettings() {
        var beforeOptions = ScanOptions()
        beforeOptions.includeHiddenFiles = true
        var afterOptions = beforeOptions
        afterOptions.treatPackagesAsDirectories = true

        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example/Documents",
                    fileSize: 10,
                    scanOptions: beforeOptions
                )),
            after: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example/Documents",
                    fileSize: 20,
                    scanOptions: afterOptions
                ))
        )

        #expect(setup.canCompare)
        #expect(setup.validationMessage == nil)
        #expect(
            setup.coverageWarningMessage
                == "Coverage warning: Scan settings differ, so added or removed items may reflect coverage changes rather than disk changes."
        )
    }

    @Test
    func testWarnsAndAllowsMissingScanSettings() {
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example/Documents",
                    fileSize: 10,
                    scanOptions: nil
                )),
            after: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example/Documents",
                    fileSize: 20,
                    scanOptions: ScanOptions()
                ))
        )

        #expect(setup.canCompare)
        #expect(setup.validationMessage == nil)
        #expect(
            setup.coverageWarningMessage
                == "Coverage warning: Scan settings are unavailable for one or both scans, so some changes may be caused by different scan coverage."
        )
    }

    @Test
    func testWarnsAndAllowsLegacyCloudSemantics() throws {
        let legacyOptions = try JSONDecoder().decode(
            ScanOptions.self,
            from: Data(
                """
                {
                  "autoSummarizeDirectories": true,
                  "cloudStorageRootPath": "/Users/example/Library/CloudStorage",
                  "exclusionPatterns": [],
                  "iCloudDriveRootPath": "/Users/example/Library/Mobile Documents",
                  "includeCloudStorage": false,
                  "includeHiddenFiles": false,
                  "treatPackagesAsDirectories": false
                }
                """.utf8)
        )
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example",
                    fileSize: 10,
                    scanOptions: legacyOptions
                )),
            after: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example",
                    fileSize: 20,
                    scanOptions: ScanOptions()
                ))
        )

        #expect(setup.canCompare)
        #expect(setup.validationMessage == nil)
        #expect(
            setup.coverageWarningMessage
                == "Coverage warning: Scan settings differ, so added or removed items may reflect coverage changes rather than disk changes."
        )
    }

    @Test
    func testBlocksSelectingTheSameScanTwice() {
        let candidate = ScanComparisonCandidate(
            snapshot: makeComparisonSnapshot(
                rootPath: "/Users/example/Documents",
                fileSize: 10,
                scanOptions: ScanOptions()
            ))
        let setup = ScanComparisonSetup(before: candidate, after: candidate)

        #expect(!(setup.canCompare))
        #expect(setup.validationMessage == "Choose two different scans.")
        #expect(setup.coverageWarningMessage == nil)
    }

    @Test
    func testBlocksDifferentRootsWithMatchingScanOptions() {
        var options = ScanOptions()
        options.exclusionPatterns = ["*.tmp"]

        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example",
                    fileSize: 10,
                    scanOptions: options
                )),
            after: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example/Documents",
                    fileSize: 20,
                    scanOptions: options
                ))
        )

        #expect(!(setup.canCompare))
        #expect(setup.validationMessage == "Choose scans of the same location.")
    }

    @Test
    func testBlocksDifferentTargetKinds() {
        let options = ScanOptions()
        let setup = ScanComparisonSetup(
            before: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example",
                    fileSize: 10,
                    scanOptions: options,
                    targetKind: .folder
                )),
            after: ScanComparisonCandidate(
                snapshot: makeComparisonSnapshot(
                    rootPath: "/Users/example",
                    fileSize: 20,
                    scanOptions: options,
                    targetKind: .volume
                ))
        )

        #expect(!(setup.canCompare))
        #expect(setup.validationMessage == "Choose scans of the same location.")
    }

    @Test
    func testDoesNotOfferCurrentScanInBothSlots() {
        let currentSnapshot = makeComparisonSnapshot(
            rootPath: "/Users/example",
            fileSize: 20,
            scanOptions: ScanOptions()
        )
        let setup = ScanComparisonSetup(
            after: ScanComparisonCandidate(snapshot: currentSnapshot)
        )

        #expect(!(setup.canAssignCurrentScan(to: .before)))
        #expect(setup.canAssignCurrentScan(to: .after))
    }
}
