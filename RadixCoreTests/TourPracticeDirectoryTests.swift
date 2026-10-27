import Darwin
import Foundation
import Testing

@testable import RadixCore

struct TourPracticeDirectoryTests {
    @Test
    func testCreationAndRemovalStayInTheConfiguredNamespace() throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let alias = fixture.rootURL.appending(path: "../tours", directoryHint: .isDirectory)
        let directory = try TourPracticeDirectory.create(in: alias)
        let manager = FileManager.default

        #expect(directory.containerURL.deletingLastPathComponent() == fixture.rootURL.standardizedFileURL)
        #expect(directory.containerURL.lastPathComponent == directory.sessionID.uuidString)
        #expect(directory.target.url.path.hasPrefix(directory.containerURL.path + "/"))
        for url in [fixture.rootURL, directory.containerURL] {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        }
        let files = try #require(manager.enumerator(at: directory.target.url, includingPropertiesForKeys: [.isRegularFileKey]))
        let fileURLs = try files.compactMap { value -> URL? in
            let url = try #require(value as? URL)
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
        #expect(fileURLs.count == 4)
        #expect(try fileURLs.allSatisfy { !(try Data(contentsOf: $0).isEmpty) })

        directory.remove()
        directory.remove()

        #expect(!manager.fileExists(atPath: directory.containerURL.path))
        #expect(manager.fileExists(atPath: fixture.outsideSentinelURL.path))
    }

    @Test(arguments: TourMarkerIdentityChange.allCases)
    func testSessionRemovalRetainsDirectoriesWithChangedIdentity(change: TourMarkerIdentityChange) throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let directory = try TourPracticeDirectory.create(in: fixture.rootURL)
        let sentinel = try fixture.addSentinel(in: directory.containerURL)
        try fixture.writeMarker(
            in: directory.containerURL,
            sessionID: change == .session ? UUID() : directory.sessionID,
            processID: change == .process ? try exitedProcessID() : getpid()
        )

        directory.remove()

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func testAbandonedCleanupRemovesOnlyOwnedDirectoriesOfExitedProcesses() throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let current = try TourPracticeDirectory.create(in: fixture.rootURL)
        let currentSentinel = try fixture.addSentinel(in: current.containerURL)
        let active = try TourPracticeDirectory.create(in: fixture.rootURL)
        let activeSentinel = try fixture.addSentinel(in: active.containerURL)
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        try fixture.writeMarker(in: active.containerURL, sessionID: active.sessionID, processID: child.processIdentifier)
        let abandoned = try TourPracticeDirectory.create(in: fixture.rootURL)
        try fixture.writeMarker(in: abandoned.containerURL, sessionID: abandoned.sessionID, processID: exitedProcessID())

        TourPracticeDirectory.removeAbandonedDirectories(in: fixture.rootURL)

        #expect(!manager.fileExists(atPath: abandoned.containerURL.path))
        #expect(manager.fileExists(atPath: currentSentinel.path))
        #expect(manager.fileExists(atPath: activeSentinel.path))
        #expect(manager.fileExists(atPath: fixture.outsideSentinelURL.path))
        #expect(child.isRunning)
    }

    @Test(arguments: TourMarkerDamage.allCases)
    func testAbandonedCleanupRetainsUntrustedMarkers(damage: TourMarkerDamage) throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let directory = try TourPracticeDirectory.create(in: fixture.rootURL)
        let sentinel = try fixture.addSentinel(in: directory.containerURL)
        let marker = directory.containerURL.appending(path: ".radix-tour.json")
        let deadPID = try exitedProcessID()
        try fixture.writeMarker(in: directory.containerURL, sessionID: directory.sessionID, processID: deadPID)
        switch damage {
        case .missing:
            try manager.removeItem(at: marker)
        case .invalidJSON:
            try Data("not-json".utf8).write(to: marker)
        case .wrongSession:
            try fixture.writeMarker(in: directory.containerURL, sessionID: UUID(), processID: deadPID)
        case .oversized:
            try fixture.writeMarker(
                in: directory.containerURL, sessionID: directory.sessionID, processID: deadPID,
                padding: String(repeating: "x", count: 2_048)
            )
        case .symbolicLink:
            let externalMarker = fixture.parentURL.appending(path: "external-marker.json")
            try manager.moveItem(at: marker, to: externalMarker)
            try manager.createSymbolicLink(at: marker, withDestinationURL: externalMarker)
        case .zeroProcess:
            try fixture.writeMarker(in: directory.containerURL, sessionID: directory.sessionID, processID: 0)
        case .negativeProcess:
            try fixture.writeMarker(in: directory.containerURL, sessionID: directory.sessionID, processID: -deadPID)
        }

        TourPracticeDirectory.removeAbandonedDirectories(in: fixture.rootURL)

        #expect(manager.fileExists(atPath: sentinel.path))
        #expect(manager.fileExists(atPath: fixture.outsideSentinelURL.path))
    }

    @Test
    func testAbandonedCleanupRetainsDirectoriesWithoutASessionName() throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let directory = try TourPracticeDirectory.create(in: fixture.rootURL)
        try fixture.writeMarker(in: directory.containerURL, sessionID: directory.sessionID, processID: exitedProcessID())
        let renamed = fixture.rootURL.appending(path: "other-directory", directoryHint: .isDirectory)
        try manager.moveItem(at: directory.containerURL, to: renamed)
        let sentinel = try fixture.addSentinel(in: renamed)

        TourPracticeDirectory.removeAbandonedDirectories(in: fixture.rootURL)

        #expect(manager.fileExists(atPath: sentinel.path))
    }

    @Test(arguments: TourSymlinkLocation.allCases)
    func testCleanupRejectsSymlinkedNamespacesAndContainers(location: TourSymlinkLocation) throws {
        let fixture = try TourDirectoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let directory = try TourPracticeDirectory.create(in: fixture.rootURL)
        let original = location == .root ? fixture.rootURL : directory.containerURL
        let destination = fixture.parentURL.appending(path: "outside-directory", directoryHint: .isDirectory)
        try manager.moveItem(at: original, to: destination)
        try manager.createSymbolicLink(at: original, withDestinationURL: destination)
        let sentinel = try fixture.addSentinel(in: destination)

        directory.remove()
        TourPracticeDirectory.removeAbandonedDirectories(in: fixture.rootURL)

        #expect(try manager.destinationOfSymbolicLink(atPath: original.path) == destination.path)
        #expect(manager.fileExists(atPath: sentinel.path))
        if location == .root {
            #expect(throws: CocoaError.self) {
                try TourPracticeDirectory.create(in: fixture.rootURL)
            }
        }
    }
}

enum TourMarkerIdentityChange: CaseIterable, Sendable {
    case session, process
}

enum TourMarkerDamage: CaseIterable, Sendable {
    case missing, invalidJSON, wrongSession, oversized, symbolicLink, zeroProcess, negativeProcess
}

enum TourSymlinkLocation: CaseIterable, Sendable {
    case root, container
}

private struct TourDirectoryFixture {
    let parentURL: URL
    let rootURL: URL
    let outsideSentinelURL: URL

    init() throws {
        parentURL = try makeTemporaryDirectory().resolvingSymlinksInPath()
        rootURL = parentURL.appending(path: "tours", directoryHint: .isDirectory)
        outsideSentinelURL = parentURL.appending(path: "outside-sentinel")
        try Data("keep".utf8).write(to: outsideSentinelURL)
    }

    func addSentinel(in directory: URL) throws -> URL {
        let url = directory.appending(path: "sentinel")
        try Data("keep".utf8).write(to: url)
        return url
    }

    func writeMarker(in directory: URL, sessionID: UUID, processID: Int32, padding: String = "") throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionID": sessionID.uuidString, "processID": processID, "padding": padding,
        ])
        try data.write(to: directory.appending(path: ".radix-tour.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: parentURL)
    }
}

private func exitedProcessID() throws -> Int32 {
    let child = Process()
    child.executableURL = URL(filePath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let processID = child.processIdentifier
    try #require(child.terminationStatus == 0)
    try #require(kill(processID, 0) == -1 && errno == ESRCH)
    return processID
}
