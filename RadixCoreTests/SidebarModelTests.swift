import XCTest
@testable import RadixCore

final class SidebarModelTests: XCTestCase {
    @MainActor
    func testRecentTargetReadsUseCachedAvailability() {
        let recent = makeSidebarTarget("/recent/cached")
        var availabilityCheckCount = 0
        let model = SidebarModel(
            recentTargetStore: RecentTargetStore(
                persistence: SidebarRecentTargetPersistence(),
                isAvailable: { _ in
                    availabilityCheckCount += 1
                    return true
                }
            ),
            preferredSmartTargetIDs: { [] }
        )

        model.refreshTargetSections(availableTargets: [], recentTargets: [recent])
        let checksAfterRefresh = availabilityCheckCount

        XCTAssertEqual(model.recentScanTargets, [recent])
        XCTAssertEqual(model.recentScanTargetRows.map(\.target), [recent])
        XCTAssertEqual(model.recentScanTargets, [recent])
        XCTAssertEqual(availabilityCheckCount, checksAfterRefresh)
    }

    @MainActor
    func testSmartTargetsIncludeMountedVolumesBelowStartupDiskAndBuildSubtitles() {
        let startupDisk = makeSidebarTarget("/", kind: .volume)
        let externalVolume = makeSidebarTarget("/Volumes/External SSD", kind: .volume)
        let home = makeSidebarTarget("/Users/example")
        let desktop = makeSidebarTarget("/Users/example/Desktop")
        let model = SidebarModel(
            recentTargetStore: makeSidebarRecentTargetStore(),
            preferredSmartTargetIDs: { [startupDisk.id, home.id, desktop.id] }
        )

        model.refreshTargetSections(
            availableTargets: [startupDisk, home, desktop, externalVolume],
            recentTargets: []
        )
        model.replaceTargetCapacityDescriptions(
            [
                startupDisk.id: "128 GB free of 1 TB",
                externalVolume.id: "512 GB free of 2 TB"
            ]
        )

        XCTAssertEqual(model.smartTargets, [startupDisk, externalVolume, home, desktop])
        XCTAssertEqual(model.smartTargetRows.map(\.target), [startupDisk, externalVolume, home, desktop])

        let subtitlesByID = Dictionary(uniqueKeysWithValues: model.smartTargetRows.map { ($0.id, $0.subtitle) })
        XCTAssertEqual(subtitlesByID[startupDisk.id], "128 GB free of 1 TB")
        XCTAssertEqual(subtitlesByID[externalVolume.id], "512 GB free of 2 TB")
        XCTAssertEqual(subtitlesByID[home.id], home.url.path)
    }

    @MainActor
    func testRecentTargetsFilterUnavailableAndSmartTargetsWhilePreservingOrder() {
        let home = makeSidebarTarget("/Users/example")
        let project = makeSidebarTarget("/Work/Project")
        let unavailable = makeSidebarTarget("/Missing")
        let downloads = makeSidebarTarget("/Users/example/Downloads")
        let model = SidebarModel(
            recentTargetStore: makeSidebarRecentTargetStore { target in
                target.id != unavailable.id
            },
            preferredSmartTargetIDs: { [home.id] }
        )

        model.refreshTargetSections(
            availableTargets: [home],
            recentTargets: [project, home, unavailable, downloads]
        )

        XCTAssertEqual(model.smartTargets, [home])
        XCTAssertEqual(model.recentScanTargets, [project, downloads])
        XCTAssertEqual(model.recentScanTargetRows.map(\.target), [project, downloads])
        XCTAssertEqual(model.target(id: home.id), home)
        XCTAssertEqual(model.target(id: project.id), project)
        XCTAssertNil(model.target(id: unavailable.id))
    }

    @MainActor
    func testRemovingRecentTargetClearsActiveTargetOnlyWhenTargetIsNotSmart() {
        let recent = makeSidebarTarget("/recent/only")
        let smart = makeSidebarTarget("/Users/example")
        let model = SidebarModel(
            recentTargetStore: makeSidebarRecentTargetStore(),
            preferredSmartTargetIDs: { [smart.id] }
        )

        model.refreshTargetSections(availableTargets: [], recentTargets: [recent])
        model.setActiveTargetID(recent.id)
        model.clearActiveTargetIfNeededAfterRemovingRecentTarget(recent)
        XCTAssertNil(model.activeTargetID)

        model.refreshTargetSections(availableTargets: [smart], recentTargets: [smart])
        model.setActiveTargetID(smart.id)
        model.clearActiveTargetIfNeededAfterRemovingRecentTarget(smart)
        XCTAssertEqual(model.activeTargetID, smart.id)
    }
}

private func makeSidebarRecentTargetStore(
    isAvailable: @escaping (ScanTarget) -> Bool = { _ in true }
) -> RecentTargetStore {
    RecentTargetStore(
        persistence: SidebarRecentTargetPersistence(),
        isAvailable: isAvailable
    )
}

private func makeSidebarTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

private final class SidebarRecentTargetPersistence: RecentTargetPersisting {
    func loadRecentTargets() -> [ScanTarget] {
        []
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {}

    func clearRecentTargets() {}
}
