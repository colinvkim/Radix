import AppKit
import Foundation
import Testing

@testable import RadixCore

@MainActor
struct SystemIntegrationTests {
    @Test
    func testOpenThrowsWhenWorkspaceDeclinesURL() throws {
        let url = URL(filePath: "/tmp/missing.txt")
        let workspace = WorkspaceSpy(openResult: false)

        #expect { try SystemIntegration.open(url, workspace: workspace) } throws: { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return false
            }

            guard case .openFailed(let path) = integrationError else {
                Issue.record("Expected openFailed, got \(integrationError).")
                return false
            }

            #expect(path == url.path)
            #expect(error.localizedDescription == "macOS could not open the item at \(url.path).")
            return true
        }
        #expect(workspace.openedURLs == [url])
    }

    @Test
    func testOpenInTerminalOpensDirectoryWithTerminal() async throws {
        let directoryURL = URL(filePath: "/tmp/example", directoryHint: .isDirectory)
        let terminalURL = URL(filePath: "/System/Applications/Utilities/Terminal.app")
        let workspace = WorkspaceSpy(openResult: true, terminalApplicationURL: terminalURL)

        try await SystemIntegration.openInTerminal(directoryURL, workspace: workspace)

        #expect(workspace.requestedApplicationBundleIdentifiers == ["com.apple.Terminal"])
        #expect(workspace.applicationOpenedURLs == [[directoryURL]])
        #expect(workspace.openedApplicationURLs == [terminalURL])
        #expect(workspace.openConfigurationsActivate == [true])
    }

    @Test
    func testOpenInTerminalThrowsWhenTerminalIsUnavailable() async throws {
        let directoryURL = URL(filePath: "/tmp/example", directoryHint: .isDirectory)
        let workspace = WorkspaceSpy(openResult: true, terminalApplicationURL: nil)

        do {
            try await SystemIntegration.openInTerminal(directoryURL, workspace: workspace)
            Issue.record("Expected opening Terminal to fail.")
        } catch {
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return
            }

            #expect(integrationError.localizedDescription == "macOS could not open Terminal at \(directoryURL.path).")
        }
        #expect(workspace.applicationOpenedURLs.isEmpty)
    }

    @Test
    func testOpenInTerminalThrowsWhenWorkspaceReportsFailure() async throws {
        let directoryURL = URL(filePath: "/tmp/example", directoryHint: .isDirectory)
        let terminalURL = URL(filePath: "/System/Applications/Utilities/Terminal.app")
        let workspace = WorkspaceSpy(
            openResult: true,
            terminalApplicationURL: terminalURL,
            applicationOpenError: NSError(domain: "RadixTests", code: 1)
        )

        do {
            try await SystemIntegration.openInTerminal(directoryURL, workspace: workspace)
            Issue.record("Expected opening Terminal to fail.")
        } catch {
            #expect(error.localizedDescription == "macOS could not open Terminal at \(directoryURL.path).")
        }
        #expect(workspace.applicationOpenedURLs == [[directoryURL]])
    }

    @Test
    func testRevealSelectsRequestedURL() {
        let url = URL(filePath: "/tmp/example.txt")
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(url, workspace: workspace)

        #expect(workspace.revealedSelections == [[url]])
    }

    @Test
    func testRevealSelectsRequestedURLs() {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt"),
        ]
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(urls, workspace: workspace)

        #expect(workspace.revealedSelections == [urls])
    }

    @Test
    func testCopyPathWritesPathAndFileURLToPasteboard() throws {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPath(url, pasteboard: pasteboard)

        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == url.path)
        #expect(pasteboard.writtenStrings[.fileURL] == url.absoluteString)
    }

    @Test
    func testCopyPathThrowsWhenPasteboardRejectsARepresentation() throws {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy(rejectedTypes: [.fileURL])

        #expect { try SystemIntegration.copyPath(url, pasteboard: pasteboard) } throws: { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return false
            }

            guard case .copyPathFailed(let path) = integrationError else {
                Issue.record("Expected copyPathFailed, got \(integrationError).")
                return false
            }

            #expect(path == url.path)
            return true
        }
        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == url.path)
        #expect(pasteboard.writtenStrings[.fileURL] == url.absoluteString)
    }

    @Test
    func testCopyPathsWritesNewlineSeparatedPaths() throws {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt"),
        ]
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPaths(urls, pasteboard: pasteboard)

        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == "/tmp/first.txt\n/tmp/second.txt")
        #expect(pasteboard.writtenStrings[.fileURL] == nil)
    }

    @Test
    func testTargetCapacityDescriptionsSkipsUnavailableVolumes() {
        let describedURL = URL(filePath: "/Volumes/Example", directoryHint: .isDirectory)
        let missingURL = URL(filePath: "/Volumes/Missing", directoryHint: .isDirectory)

        let descriptions = SystemIntegration.targetCapacityDescriptions(
            mountedVolumes: [describedURL, missingURL],
            capacityDescriptionForURL: { url in
                url == describedURL ? "1 GB free of 2 GB" : nil
            }
        )

        #expect(
            descriptions == [
                describedURL.standardizedFileURL.path: "1 GB free of 2 GB"
            ])
    }

    @Test
    func testCapacityDescriptionPrefersGeneralAvailableCapacityWhenImportantUsageIsZero() {
        let description = SystemIntegration.capacityDescription(
            totalCapacity: 2_000_000_000_000,
            availableCapacity: 512_000_000_000,
            availableCapacityForImportantUsage: 0
        )

        #expect(description == "512 GB free of 2 TB")
    }

    @Test
    func testFullDiskAccessStatusUsesInjectedProbes() {
        #expect(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: []
            ) == .unknown)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ) == .notGranted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: failedProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ) == .notGranted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, failedProbe]
            ) == .notGranted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe]
            ) == .granted)
    }

    @Test
    func testFullDiskAccessStatusKeepsLegacyLogicBeforeMacOS27() {
        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: successfulProbe,
                systemTCCDatabaseProbe: successfulProbe
            ) == .notGranted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: failedProbe,
                stocksContainerProbe: failedProbe,
                systemTCCDatabaseProbe: failedProbe
            ) == .granted)
    }

    @Test
    func testFullDiskAccessStatusUsesMacOS27PrimarySentinels() {
        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: successfulProbe,
                systemTCCDatabaseProbe: nil
            ) == .granted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: successfulProbe,
                protectedDataVaultProbes: [successfulProbe, successfulProbe],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: failedProbe,
                systemTCCDatabaseProbe: successfulProbe
            ) == .notGranted)
    }

    @Test
    func testFullDiskAccessStatusUsesMacOS27SystemTCCOnlyAsFallbackEvidence() {
        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: nil,
                systemTCCDatabaseProbe: successfulProbe
            ) == .granted)

        #expect(
            SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                userTCCDatabaseProbe: nil,
                protectedDataVaultProbes: [],
                timeMachinePreferencesProbe: successfulProbe,
                stocksContainerProbe: nil,
                systemTCCDatabaseProbe: failedProbe
            ) == .unknown)
    }

    @Test
    func testMoveToTrashPreflightRejectsProtectedLocations() throws {
        #expect {
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/System", directoryHint: .isDirectory)
            )
        } throws: { error in
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return false
            }

            guard case .protectedTrashLocation(let path) = integrationError else {
                Issue.record("Expected protectedTrashLocation, got \(integrationError).")
                return false
            }

            #expect(path == "/System")
            #expect(error.localizedDescription == "Radix will not move the protected location at /System to the Trash.")
            return true
        }
    }

    @Test
    func testMoveToTrashPreflightAllowsDescendantsOfProtectedLocations() throws {
        #expect(throws: Never.self) {
            try SystemIntegration.validateCanMoveToTrash(
                URL(filePath: "/Applications/Example.app", directoryHint: .isDirectory)
            )
        }
    }

    @Test
    func testIdentityBoundTrashMoveDoesNotMutateReplacementAtScannedPath() throws {
        let node = trashTestNode()
        var operationOrder: [String] = []

        let result = try SystemIntegration.moveToTrash(
            node,
            identityVerifier: { verifiedNode in
                operationOrder.append("verify:\(verifiedNode.id)")
                // Models the path having been replaced after the user confirmed
                // the request but before the consolidated mutation begins.
                return .mismatch
            },
            trashItem: { _ in
                operationOrder.append("trash")
            }
        )

        #expect(result == .mismatch)
        #expect(operationOrder == ["verify:\(node.id)"])
    }

    @Test
    func testIdentityBoundTrashMoveVerifiesImmediatelyBeforeNativeMutation() throws {
        let node = trashTestNode()
        var operationOrder: [String] = []

        let result = try SystemIntegration.moveToTrash(
            node,
            identityVerifier: { _ in
                operationOrder.append("verify")
                return .matches
            },
            trashItem: { url in
                operationOrder.append("trash:\(url.path)")
            }
        )

        #expect(result == .matches)
        #expect(operationOrder == ["verify", "trash:\(node.url.path)"])
    }

    private func trashTestNode() -> FileNodeRecord {
        let url = URL(filePath: "/tmp/radix-trash-test.txt", directoryHint: .notDirectory)
        return FileNodeRecord(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: FileIdentity(device: 1, inode: 2),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
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
    private let terminalApplicationURL: URL?
    private let applicationOpenError: (any Error)?
    private(set) var openedURLs: [URL] = []
    private(set) var revealedSelections: [[URL]] = []
    private(set) var requestedApplicationBundleIdentifiers: [String] = []
    private(set) var applicationOpenedURLs: [[URL]] = []
    private(set) var openedApplicationURLs: [URL] = []
    private(set) var openConfigurationsActivate: [Bool] = []

    init(
        openResult: Bool,
        terminalApplicationURL: URL? = nil,
        applicationOpenError: (any Error)? = nil
    ) {
        self.openResult = openResult
        self.terminalApplicationURL = terminalApplicationURL
        self.applicationOpenError = applicationOpenError
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealedSelections.append(fileURLs)
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResult
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        requestedApplicationBundleIdentifiers.append(bundleIdentifier)
        return terminalApplicationURL
    }

    func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?
    ) {
        applicationOpenedURLs.append(urls)
        openedApplicationURLs.append(applicationURL)
        openConfigurationsActivate.append(configuration.activates)
        completionHandler?(nil, applicationOpenError)
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
