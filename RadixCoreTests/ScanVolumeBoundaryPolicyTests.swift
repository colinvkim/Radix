import XCTest
@testable import RadixCore

final class ScanVolumeBoundaryPolicyTests: XCTestCase {
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

    func testFirmlinkedSameContainerMountsRemainTraversable() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        XCTAssertFalse(policy.shouldStopDescent(childDeviceID: dataVolumeDevice))
        XCTAssertFalse(policy.shouldStopDescent(childDeviceID: virtualMemoryVolumeDevice))
    }

    func testStartupVolumeBulkEntriesRemainTraversable() throws {
        let mounts = ScanEngine.defaultMountedFileSystems()
        guard mounts.contains(where: { $0.mountPath == "/" && $0.fileSystemType == "apfs" }) else {
            throw XCTSkip("This integration test requires an APFS startup volume.")
        }
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: rootURL.path,
            rootDeviceID: try XCTUnwrap(rootMetadata.fileIdentity?.fileSystemDeviceID),
            mountedFileSystems: mounts
        )
        let result = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        ))

        for name in ["System", "Users", "Library"] {
            let entry = try XCTUnwrap(result.entries.first { $0.url.lastPathComponent == name })
            let deviceID = try XCTUnwrap(entry.metadata?.fileIdentity?.fileSystemDeviceID)
            XCTAssertNil(
                policy.descentBoundaryError(for: entry.url, childDeviceID: deviceID),
                "The startup volume must allow traversal into \(entry.url.path)."
            )
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
                    return XCTFail("The System directory should open without a fallback.")
                }
                lease.close()
            }
        }
    }

    func testForeignContainerMountsBecomeLeaves() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: externalVolumeDevice))
        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: diskImageDevice))
    }

    func testDiskImageMountInsideScannedTreeBecomesLeaf() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
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

        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: diskImageDevice))
        XCTAssertFalse(policy.shouldStopDescent(childDeviceID: dataVolumeDevice))
    }

    func testFolderScanOnExternalVolumeUsesItsOwnContainer() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
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

        XCTAssertFalse(policy.shouldStopDescent(childDeviceID: 0x0200_0003))
        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: dataVolumeDevice))
    }

    func testMissingChildDeviceStopsWhenRootDeviceIsKnown() throws {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )
        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: nil))
        let url = URL(filePath: "/unverified", directoryHint: .isDirectory)
        let error = try XCTUnwrap(
            policy.descentBoundaryError(for: url, childDeviceID: nil)
        )
        XCTAssertEqual(ScanWarningFactory.makeWarning(for: url, error: error).category, .fileSystem)
    }

    func testMissingRootDeviceLeavesBoundaryPolicyUnrestricted() {
        let unresolvedPolicy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: nil,
            mountedFileSystems: makeDefaultMounts()
        )
        XCTAssertFalse(unresolvedPolicy.shouldStopDescent(childDeviceID: externalVolumeDevice))
        XCTAssertFalse(unresolvedPolicy.shouldStopDescent(childDeviceID: nil))
    }

    func testNonAPFSMountsWithMatchingDiskPrefixStayBlocked() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
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

        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: 0x0100_0007))
    }

    func testRootMountMatchesFolderScansBelowSlash() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/Users/tester",
            rootDeviceID: dataVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        XCTAssertFalse(policy.shouldStopDescent(childDeviceID: virtualMemoryVolumeDevice))
        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: externalVolumeDevice))
    }

    func testSameContainerMountWithoutDeviceIdentityStaysBlocked() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
            mountPath: "/System/Volumes/Unresolved",
            deviceName: "/dev/disk1s7",
            fileSystemType: "apfs"
        ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: mounts
        )

        XCTAssertTrue(policy.shouldStopDescent(childDeviceID: 0x0100_0007))
    }
}
