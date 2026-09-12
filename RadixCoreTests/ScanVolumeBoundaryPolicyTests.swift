import Foundation
import Testing

@testable import RadixCore

struct ScanVolumeBoundaryPolicyTests {
    private let systemVolumeDevice: UInt64 = 0x0100_0001
    private let dataVolumeDevice: UInt64 = 0x0100_0005
    private let externalVolumeDevice: UInt64 = 0x0200_0002
    private let diskImageDevice: UInt64 = 0x0300_0004
    private let virtualMemoryVolumeDevice: UInt64 = 0x0100_0004

    private func makeDefaultMounts() -> [ScanEngine.ScanMountedFileSystem] {
        [
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/",
                deviceName: "/dev/disk1s1s1",
                fileSystemType: "apfs",
                deviceID: systemVolumeDevice
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/Data",
                deviceName: "/dev/disk1s5",
                fileSystemType: "apfs",
                deviceID: dataVolumeDevice
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/VM",
                deviceName: "/dev/disk1s4",
                fileSystemType: "apfs",
                deviceID: virtualMemoryVolumeDevice
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/Volumes/External",
                deviceName: "/dev/disk2s2",
                fileSystemType: "apfs",
                deviceID: externalVolumeDevice
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/home",
                deviceName: "map auto_home",
                fileSystemType: "autofs"
            ),
        ]
    }

    @Test
    func testFirmlinkedSameContainerMountsRemainTraversable() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        #expect(!(policy.shouldStopDescent(childDeviceID: dataVolumeDevice)))
        #expect(!(policy.shouldStopDescent(childDeviceID: virtualMemoryVolumeDevice)))
    }

    @Test
    func testStartupVolumeBulkEntriesRemainTraversable() throws {
        let mounts = ScanEngine.defaultMountedFileSystems()
        guard mounts.contains(where: { $0.mountPath == "/" && $0.fileSystemType == "apfs" }) else {
            throw TestFixtureError("This integration test requires an APFS startup volume.")
        }
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: rootURL.path,
            rootDeviceID: try #require(rootMetadata.fileIdentity?.fileSystemDeviceID),
            mountedFileSystems: mounts
        )
        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)

        for name in ["System", "Users", "Library"] {
            let entry = try #require(result.entries.first { $0.url.lastPathComponent == name })
            let deviceID = try #require(entry.metadata?.fileIdentity?.fileSystemDeviceID)
            #expect(
                policy.descentBoundaryError(for: entry.url, childDeviceID: deviceID) == nil,
                "The startup volume must allow traversal into \(entry.url.path).")
            if name == "System" {
                // This is an ordinary directory on the sealed volume, so its
                // bulk identity must also pass descriptor replacement checks.
                let pool = ScanDirectoryDescriptorPool()
                let outcome = try pool.openRoot(
                    at: entry.url,
                    expectedIdentity: entry.metadata?.fileIdentity,
                    cancellationCheck: {}
                )
                guard case .lease(let lease) = outcome else {
                    Issue.record("The System directory should open without a fallback.")
                    return
                }
                lease.close()
            }
        }
    }

    @Test
    func testForeignContainerMountsBecomeLeaves() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        #expect(policy.shouldStopDescent(childDeviceID: externalVolumeDevice))
        #expect(policy.shouldStopDescent(childDeviceID: diskImageDevice))
    }

    @Test
    func testDiskImageMountInsideScannedTreeBecomesLeaf() {
        var mounts = makeDefaultMounts()
        mounts.append(
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/Data/Users/tester/MountedImage",
                deviceName: "/dev/disk3s4",
                fileSystemType: "apfs",
                deviceID: diskImageDevice
            ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/System/Volumes/Data/Users/tester",
            rootDeviceID: dataVolumeDevice,
            mountedFileSystems: mounts
        )

        #expect(policy.shouldStopDescent(childDeviceID: diskImageDevice))
        #expect(!(policy.shouldStopDescent(childDeviceID: dataVolumeDevice)))
    }

    @Test
    func testFolderScanOnExternalVolumeUsesItsOwnContainer() {
        var mounts = makeDefaultMounts()
        mounts.append(
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/Volumes/External/SecondSlice",
                deviceName: "/dev/disk2s3",
                fileSystemType: "apfs",
                deviceID: 0x0200_0003
            ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/Volumes/External/scan-me",
            rootDeviceID: externalVolumeDevice,
            mountedFileSystems: mounts
        )

        #expect(!(policy.shouldStopDescent(childDeviceID: 0x0200_0003)))
        #expect(policy.shouldStopDescent(childDeviceID: dataVolumeDevice))
    }

    @Test
    func testMissingChildDeviceStopsWhenRootDeviceIsKnown() throws {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )
        #expect(policy.shouldStopDescent(childDeviceID: nil))
        let url = URL(filePath: "/unverified", directoryHint: .isDirectory)
        let error = try #require(policy.descentBoundaryError(for: url, childDeviceID: nil))
        #expect(ScanWarningFactory.makeWarning(for: url, error: error).category == .fileSystem)
    }

    @Test
    func testMissingRootDeviceLeavesBoundaryPolicyUnrestricted() {
        let unresolvedPolicy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: nil,
            mountedFileSystems: makeDefaultMounts()
        )
        #expect(!(unresolvedPolicy.shouldStopDescent(childDeviceID: externalVolumeDevice)))
        #expect(!(unresolvedPolicy.shouldStopDescent(childDeviceID: nil)))
    }

    @Test
    func testNonAPFSMountsWithMatchingDiskPrefixStayBlocked() {
        var mounts = makeDefaultMounts()
        mounts.append(
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/LegacySlice",
                deviceName: "/dev/disk1s7",
                fileSystemType: "hfs",
                deviceID: 0x0100_0007
            ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: mounts
        )

        #expect(policy.shouldStopDescent(childDeviceID: 0x0100_0007))
    }

    @Test
    func testRootMountMatchesFolderScansBelowSlash() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/Users/tester",
            rootDeviceID: dataVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        #expect(!(policy.shouldStopDescent(childDeviceID: virtualMemoryVolumeDevice)))
        #expect(policy.shouldStopDescent(childDeviceID: externalVolumeDevice))
    }

    @Test
    func testSameContainerMountWithoutDeviceIdentityStaysBlocked() {
        var mounts = makeDefaultMounts()
        mounts.append(
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/Unresolved",
                deviceName: "/dev/disk1s7",
                fileSystemType: "apfs"
            ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: mounts
        )

        #expect(policy.shouldStopDescent(childDeviceID: 0x0100_0007))
    }
}
