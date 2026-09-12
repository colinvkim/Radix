import Foundation
import Testing

@testable import RadixCore

struct IncrementalRescanPlannerTests {
    @Test
    func testInjectedHistoryProviderFeedsPlannerWithinExplicitCutoff() async throws {
        let fixture = makeFixture()
        let since = ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 10)
        let through = ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 30)
        let provider = FakeFileSystemEventHistoryProvider(
            checkpoint: through,
            history: FileSystemEventHistory(
                since: since,
                through: through,
                events: [
                    FileSystemEventRecord(
                        path: "/scan/folder/new.txt",
                        eventID: 20,
                        flags: [.itemCreated, .itemIsFile]
                    )
                ]
            )
        )

        let cutoff = try provider.currentCheckpoint(
            for: URL(filePath: "/scan", directoryHint: .isDirectory)
        )
        let eventHistory = try await provider.history(
            for: URL(filePath: "/scan", directoryHint: .isDirectory),
            since: since,
            through: cutoff
        )
        let plan = IncrementalRescanPlanner().plan(
            history: eventHistory,
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(cutoff == through)
        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [fixture.folder.id],
                    rescanSubtreeIDs: []
                ))
    }

    @Test
    func testFileEventRelistsContainingDirectory() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [fixture.folder.id],
                    rescanSubtreeIDs: []
                ))
    }

    @Test
    func testRootLevelFileEventRelistsScanRoot() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/new.txt", flags: [.itemCreated, .itemIsFile])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [fixture.store.rootID],
                    rescanSubtreeIDs: []
                ))
    }

    @Test
    func testDisjointRelistAndSubtreeRescanShareOnePlan() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile]),
                event(
                    "/scan/Tool.app/Contents/MacOS/Tool",
                    flags: [.itemModified, .itemIsFile]
                ),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [fixture.folder.id],
                    rescanSubtreeIDs: [fixture.package.id]
                ))
    }

    @Test
    func testAncestorRelistWithNestedUpdateFallsBackAtScanRoot() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/new.txt", flags: [.itemCreated, .itemIsFile]),
                event("/scan/folder/new.txt", flags: [.itemCreated, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(plan == .fullScan(reason: .changedScanRoot))
    }

    @Test
    func testBroadRelistPlanFallsBackToFullScan() {
        let directories = (0..<32).map { index in
            directory("/scan/directory-\(index)", children: [])
        }
        let root = directory("/scan", children: directories)
        let store = FileTreeStore(root: root, childrenByID: [root.id: directories])
        let events = directories.map { directory in
            event(
                directory.id + "/new.txt",
                flags: [.itemCreated, .itemIsFile]
            )
        }
        let plan = IncrementalRescanPlanner().plan(
            history: history(events),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        #expect(plan == .fullScan(reason: .incrementalWorkTooBroad))
    }

    @Test
    func testSingleBroadSubtreeFallsBackToFullScan() {
        let changedFiles = (0..<40).map { index in
            file("/scan/changed/file-\(index).dat")
        }
        let changed = directory("/scan/changed", children: changedFiles)
        let paddingFiles = (0..<20).map { index in
            file("/scan/padding-\(index).dat")
        }
        let rootChildren = [changed] + paddingFiles
        let root = directory("/scan", children: rootChildren)
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: rootChildren,
                changed.id: changedFiles,
            ])

        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event(changed.id, flags: [.mustScanSubdirectories, .itemIsDirectory])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        #expect(plan == .fullScan(reason: .incrementalWorkTooBroad))
    }

    @Test
    func testNestedEventsCoalesceToTopLevelChangedSubtree() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder", flags: [.mustScanSubdirectories, .itemIsDirectory]),
                event("/scan/folder/nested/payload.bin", flags: [.itemModified, .itemIsFile]),
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [],
                    rescanSubtreeIDs: [fixture.folder.id]
                ))
    }

    @Test
    func testManyDisjointEventsRemainIndependentRelistsBelowBroadWorkThreshold() {
        let directories = (0..<128).map { index in
            directory("/scan/directory-\(index)", children: [])
        }
        let paddingFiles = (0..<512).map { index in
            file("/scan/padding-\(index).dat")
        }
        let rootChildren = directories + paddingFiles
        let root = directory("/scan", children: rootChildren)
        let store = FileTreeStore(root: root, childrenByID: [root.id: rootChildren])
        let events = directories.map { directory in
            event(directory.id + "/new.txt", flags: [.itemCreated, .itemIsFile])
        }

        let plan = IncrementalRescanPlanner().plan(
            history: history(events),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: directories.map(\.id),
                    rescanSubtreeIDs: []
                ))
    }

    @Test
    func testDroppedRootAndMountEventsRequireFullScan() {
        let fixture = makeFixture()
        let target = ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory))
        let cases: [(FileSystemEventFlags, IncrementalRescanFallbackReason)] = [
            (.userDropped, .userDroppedEvents),
            (.kernelDropped, .kernelDroppedEvents),
            (.eventIDsWrapped, .eventIDsWrapped),
            (.rootChanged, .watchedRootChanged),
            (.volumeMounted, .nestedVolumeChanged),
            (.itemCloned, .cloneTopologyChanged),
        ]

        for (flags, expectedReason) in cases {
            let plan = IncrementalRescanPlanner().plan(
                history: history([event("/scan/folder", flags: flags)]),
                target: target,
                treeStore: fixture.store
            )
            #expect(plan == .fullScan(reason: expectedReason))
        }
    }

    @Test
    func testChangingExistingCloneMemberRequiresFullScan() {
        let clone = file(
            "/scan/folder/clone.bin",
            cloneIdentity: CloneIdentity(device: 1, cloneID: 42)
        )
        let folder = directory("/scan/folder", children: [clone])
        let root = directory("/scan", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: [clone],
            ])
        let target = ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory))

        for flags: FileSystemEventFlags in [
            [.itemModified, .itemIsFile],
            [.itemRemoved, .itemIsFile],
        ] {
            let plan = IncrementalRescanPlanner().plan(
                history: history([event(clone.id, flags: flags)]),
                target: target,
                treeStore: store
            )

            #expect(plan == .fullScan(reason: .cloneTopologyChanged))
        }
    }

    @Test
    func testHardLinkEventsRequireFullScan() {
        let identity = FileIdentity(device: 1, inode: 42)
        let hardLink = file(
            "/scan/folder/shared.bin",
            fileIdentity: identity,
            linkCount: 2
        )
        let folder = directory("/scan/folder", children: [hardLink])
        let root = directory("/scan", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder],
                folder.id: [hardLink],
            ])
        let target = ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory))

        let cases: [(FileSystemEventFlags, IncrementalRescanFallbackReason)] = [
            ([.itemModified, .itemIsFile], .sharedAllocationTopologyChanged),
            ([.itemMetadataModified, .itemIsFile], .sharedAllocationTopologyChanged),
            ([.itemCreated, .itemIsFile, .itemIsHardLink], .sharedAllocationTopologyChanged),
            ([.itemRemoved, .itemIsFile, .itemIsLastHardLink], .sharedAllocationTopologyChanged),
        ]
        for (flags, expectedReason) in cases {
            let eventPath =
                flags.contains(.itemCreated)
                ? "/scan/folder/new-link.bin"
                : hardLink.id
            let plan = IncrementalRescanPlanner().plan(
                history: history([event(eventPath, flags: flags)]),
                target: target,
                treeStore: store
            )

            #expect(plan == .fullScan(reason: expectedReason))
        }
    }

    @Test
    func testDirectoryLinkCountDoesNotRequireSharedAllocationFallback() {
        let folder = directory("/scan/folder", children: [], linkCount: 12)
        let root = directory("/scan", children: [folder])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [folder]])

        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event(folder.id, flags: [.itemModified, .itemIsDirectory])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [],
                    rescanSubtreeIDs: [folder.id]
                ))
    }

    @Test
    func testEventInsidePackageUsesMaterializedPackageLeaf() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/Tool.app/Contents/MacOS/Tool", flags: [.itemModified, .itemIsFile])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(
            plan
                == .update(
                    relistDirectoryIDs: [],
                    rescanSubtreeIDs: [fixture.package.id]
                ))
    }

    @Test
    func testEventInsideAutoSummaryFallsBackToFullScan() {
        let fixture = makeFixture()
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/cache/shard/payload", flags: [.itemModified, .itemIsFile])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store
        )

        #expect(plan == .fullScan(reason: .autoSummarizedBoundary))
    }

    @Test
    func testExcludedKnownEventDoesNotTriggerRescan() {
        let fixture = makeFixture()
        let matcher = ScanExclusionMatcher(
            patterns: ["*.log"],
            rootPath: "/scan"
        )
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event("/scan/folder/debug.log", flags: [.itemModified, .itemIsFile])
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store,
            exclusionMatcher: matcher
        )

        #expect(plan == .noChanges)
    }

    @Test
    func testExcludedSharedAllocationEventDoesNotTriggerFullScan() {
        let fixture = makeFixture()
        let matcher = ScanExclusionMatcher(
            patterns: ["*.log"],
            rootPath: "/scan"
        )
        let plan = IncrementalRescanPlanner().plan(
            history: history([
                event(
                    "/scan/folder/debug.log",
                    flags: [.itemModified, .itemIsFile, .itemCloned, .itemIsHardLink]
                )
            ]),
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: fixture.store,
            exclusionMatcher: matcher
        )

        #expect(plan == .noChanges)
    }

    private func history(_ events: [FileSystemEventRecord]) -> FileSystemEventHistory {
        FileSystemEventHistory(
            since: ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 10),
            through: ScanIncrementalCheckpoint(volumeUUID: "volume", eventID: 100),
            events: events
        )
    }

    private func event(
        _ path: String,
        flags: FileSystemEventFlags
    ) -> FileSystemEventRecord {
        FileSystemEventRecord(path: path, eventID: 20, flags: flags)
    }

    private func makeFixture() -> (
        store: FileTreeStore,
        folder: FileNodeRecord,
        package: FileNodeRecord,
        autoSummary: FileNodeRecord
    ) {
        let payload = file("/scan/folder/nested/payload.bin")
        let nested = directory("/scan/folder/nested", children: [payload])
        let folder = directory("/scan/folder", children: [nested])
        let package = FileNodeRecord(
            id: "/scan/Tool.app",
            url: URL(filePath: "/scan/Tool.app", directoryHint: .isDirectory),
            name: "Tool.app",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 10,
            logicalSize: 10,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let autoSummary = FileNodeRecord(
            id: "/scan/cache",
            url: URL(filePath: "/scan/cache", directoryHint: .isDirectory),
            name: "cache",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 20,
            logicalSize: 20,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let root = directory("/scan", children: [folder, package, autoSummary])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, package, autoSummary],
                folder.id: [nested],
                nested.id: [payload],
            ])
        return (store, folder, package, autoSummary)
    }

    private func directory(
        _ path: String,
        children: [FileNodeRecord],
        linkCount: UInt64 = 1
    ) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: path,
            url: URL(filePath: path, directoryHint: .isDirectory),
            name: URL(filePath: path).lastPathComponent,
            children: children,
            lastModified: nil,
            linkCount: linkCount,
            isPackage: false,
            isAccessible: true
        )
    }

    private func file(
        _ path: String,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        cloneIdentity: CloneIdentity? = nil
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: path,
            url: URL(filePath: path),
            name: URL(filePath: path).lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            cloneIdentity: cloneIdentity,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}

private nonisolated struct FakeFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    let checkpoint: ScanIncrementalCheckpoint
    let storedHistory: FileSystemEventHistory

    init(checkpoint: ScanIncrementalCheckpoint, history: FileSystemEventHistory) {
        self.checkpoint = checkpoint
        self.storedHistory = history
    }

    func currentCheckpoint(for targetURL: URL) throws -> ScanIncrementalCheckpoint {
        _ = targetURL
        return checkpoint
    }

    func history(
        for targetURL: URL,
        since: ScanIncrementalCheckpoint,
        through: ScanIncrementalCheckpoint
    ) async throws -> FileSystemEventHistory {
        _ = targetURL
        #expect(since == storedHistory.since)
        #expect(through == storedHistory.through)
        return storedHistory
    }
}
