import AppKit
import XCTest
@testable import RadixCore

final class SystemIntegrationTests: XCTestCase {
    func testOpenThrowsWhenWorkspaceDeclinesURL() {
        let url = URL(filePath: "/tmp/missing.txt")
        let workspace = WorkspaceSpy(openResult: false)

        XCTAssertThrowsError(
            try SystemIntegration.open(url, workspace: workspace)
        ) { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                XCTFail("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .openFailed(let path) = integrationError else {
                XCTFail("Expected openFailed, got \(integrationError).")
                return
            }

            XCTAssertEqual(path, url.path)
            XCTAssertEqual(error.localizedDescription, "macOS could not open the item at \(url.path).")
        }
        XCTAssertEqual(workspace.openedURLs, [url])
    }

    func testRevealSelectsRequestedURL() {
        let url = URL(filePath: "/tmp/example.txt")
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(url, workspace: workspace)

        XCTAssertEqual(workspace.revealedSelections, [[url]])
    }

    func testRevealSelectsRequestedURLs() {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt")
        ]
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(urls, workspace: workspace)

        XCTAssertEqual(workspace.revealedSelections, [urls])
    }

    func testCopyPathWritesPathAndFileURLToPasteboard() throws {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPath(url, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertEqual(pasteboard.writtenStrings[.string], url.path)
        XCTAssertEqual(pasteboard.writtenStrings[.fileURL], url.absoluteString)
    }

    func testCopyPathThrowsWhenPasteboardRejectsARepresentation() {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy(rejectedTypes: [.fileURL])

        XCTAssertThrowsError(
            try SystemIntegration.copyPath(url, pasteboard: pasteboard)
        ) { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                XCTFail("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .copyPathFailed(let path) = integrationError else {
                XCTFail("Expected copyPathFailed, got \(integrationError).")
                return
            }

            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertEqual(pasteboard.writtenStrings[.string], url.path)
        XCTAssertEqual(pasteboard.writtenStrings[.fileURL], url.absoluteString)
    }

    func testCopyPathsWritesNewlineSeparatedPaths() throws {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt")
        ]
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPaths(urls, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertEqual(pasteboard.writtenStrings[.string], "/tmp/first.txt\n/tmp/second.txt")
        XCTAssertNil(pasteboard.writtenStrings[.fileURL])
    }

    func testTargetCapacityDescriptionsSkipsUnavailableVolumes() {
        let describedURL = URL(filePath: "/Volumes/Example", directoryHint: .isDirectory)
        let missingURL = URL(filePath: "/Volumes/Missing", directoryHint: .isDirectory)

        let descriptions = SystemIntegration.targetCapacityDescriptions(
            mountedVolumes: [describedURL, missingURL],
            capacityDescriptionForURL: { url in
                url == describedURL ? "1 GB free of 2 GB" : nil
            }
        )

        XCTAssertEqual(descriptions, [
            describedURL.standardizedFileURL.path: "1 GB free of 2 GB"
        ])
    }

    func testCapacityDescriptionPrefersGeneralAvailableCapacityWhenImportantUsageIsZero() {
        let description = SystemIntegration.capacityDescription(
            totalCapacity: 2_000_000_000_000,
            availableCapacity: 512_000_000_000,
            availableCapacityForImportantUsage: 0
        )

        XCTAssertEqual(description, "512 GB free of 2 TB")
    }

    func testFullDiskAccessStatusUsesInjectedProbes() {
        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: []
            ),
            .unknown
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ),
            .notGranted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: failedProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ),
            .notGranted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, failedProbe]
            ),
            .notGranted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ),
            .granted
        )
    }

    func testFullDiskAccessStatusKeepsLegacyLogicBeforeMacOS27() {
        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: successfulProbe,
                systemTCCDatabaseProbe: successfulProbe
            ),
            .notGranted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: failedProbe,
                stocksContainerProbe: failedProbe,
                systemTCCDatabaseProbe: failedProbe
            ),
            .granted
        )
    }

    func testFullDiskAccessStatusUsesMacOS27PrimarySentinels() {
        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: successfulProbe,
                systemTCCDatabaseProbe: nil
            ),
            .granted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: failedProbe,
                systemTCCDatabaseProbe: successfulProbe
            ),
            .notGranted
        )
    }

    func testFullDiskAccessStatusUsesMacOS27SystemTCCOnlyAsFallbackEvidence() {
        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: nil,
                systemTCCDatabaseProbe: successfulProbe
            ),
            .granted
        )

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: nil,
                systemTCCDatabaseProbe: failedProbe
            ),
            .unknown
        )
    }

    func testMoveToTrashPreflightRejectsProtectedLocations() {
        XCTAssertThrowsError(
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/System", directoryHint: .isDirectory)
            )
        ) { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                XCTFail("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .protectedTrashLocation(let path) = integrationError else {
                XCTFail("Expected protectedTrashLocation, got \(integrationError).")
                return
            }

            XCTAssertEqual(path, "/System")
            XCTAssertEqual(
                error.localizedDescription,
                "Radix will not move the protected location at /System to the Trash."
            )
        }
    }

    func testMoveToTrashPreflightAllowsDescendantsOfProtectedLocations() {
        XCTAssertNoThrow(
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/Applications/Example.app", directoryHint: .isDirectory)
            )
        )
    }

    private var successfulProbe: SystemIntegration.FullDiskAccessProbe {
        {}
    }

    private var failedProbe: SystemIntegration.FullDiskAccessProbe {
        {
            throw NSError(domain: "RadixTests", code: 1)
        }
    }
}

private final class WorkspaceSpy: SystemWorkspace {
    private let openResult: Bool
    private(set) var openedURLs: [URL] = []
    private(set) var revealedSelections: [[URL]] = []

    init(openResult: Bool) {
        self.openResult = openResult
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealedSelections.append(fileURLs)
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResult
    }
}

private final class PasteboardSpy: PathPasteboard {
    private let rejectedTypes: Set<NSPasteboard.PasteboardType>
    private(set) var clearCount = 0
    private(set) var writtenStrings: [NSPasteboard.PasteboardType: String] = [:]

    init(rejectedTypes: Set<NSPasteboard.PasteboardType> = []) {
        self.rejectedTypes = rejectedTypes
    }

    @discardableResult
    func clearContents() -> Int {
        clearCount += 1
        return clearCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenStrings[dataType] = string
        return !rejectedTypes.contains(dataType)
    }
}
