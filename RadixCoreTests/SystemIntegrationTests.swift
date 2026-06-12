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

    func testFullDiskAccessStatusUsesInjectedProbes() {
        XCTAssertEqual(SystemIntegration.fullDiskAccessStatus(probes: []), .unknown)

        XCTAssertEqual(
            SystemIntegration.fullDiskAccessStatus(probes: [
                { throw NSError(domain: "RadixTests", code: 1) }
            ]),
            .notGranted
        )

        var attempts = 0
        let grantedStatus = SystemIntegration.fullDiskAccessStatus(probes: [
            {
                attempts += 1
                throw NSError(domain: "RadixTests", code: 1)
            },
            {
                attempts += 1
            }
        ])

        XCTAssertEqual(grantedStatus, .granted)
        XCTAssertEqual(attempts, 2)
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
