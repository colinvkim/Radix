import Foundation
import Testing

@testable import RadixCore

@MainActor
struct SidebarModelTests {
    @Test
    func testRecentTargetReadsUseCachedAvailability() {
        let recent = makeSidebarTarget("/recent/cached")
        var availabilityCheckCount = 0
        let model = SidebarModel(
            recentTargetStore: RecentTargetStore(
                persistence: TestRecentTargetPersistence(),
                isAvailable: { _ in
                    availabilityCheckCount += 1
                    return true
                }
            ),
            preferredSmartTargetIDs: { [] }
        )

        model.refreshTargetSections(availableTargets: [], recentTargets: [recent])
        let checksAfterRefresh = availabilityCheckCount

        #expect(model.recentScanTargets == [recent])
        #expect(model.recentScanTargetRows.map(\.target) == [recent])
        #expect(model.recentScanTargets == [recent])
        #expect(availabilityCheckCount == checksAfterRefresh)
    }

    @Test
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
                externalVolume.id: "512 GB free of 2 TB",
            ]
        )

        #expect(model.smartTargets == [startupDisk, externalVolume, home, desktop])
        #expect(model.smartTargetRows.map(\.target) == [startupDisk, externalVolume, home, desktop])

        let subtitlesByID = Dictionary(uniqueKeysWithValues: model.smartTargetRows.map { ($0.id, $0.subtitle) })
        #expect(subtitlesByID[startupDisk.id] == "128 GB free of 1 TB")
        #expect(subtitlesByID[externalVolume.id] == "512 GB free of 2 TB")
        #expect(subtitlesByID[home.id] == home.url.path)
    }

    @Test
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

        #expect(model.smartTargets == [home])
        #expect(model.recentScanTargets == [project, downloads])
        #expect(model.recentScanTargetRows.map(\.target) == [project, downloads])
        #expect(model.target(id: home.id) == home)
        #expect(model.target(id: project.id) == project)
        #expect(model.target(id: unavailable.id) == nil)
    }

    @Test
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
        #expect(model.activeTargetID == nil)

        model.refreshTargetSections(availableTargets: [smart], recentTargets: [smart])
        model.setActiveTargetID(smart.id)
        model.clearActiveTargetIfNeededAfterRemovingRecentTarget(smart)
        #expect(model.activeTargetID == smart.id)
    }

    @Test
    func testRebuildingTargetSectionsClearsMissingActiveTarget() {
        let recent = makeSidebarTarget("/recent/active")
        let smart = makeSidebarTarget("/Users/example")
        let model = SidebarModel(
            recentTargetStore: makeSidebarRecentTargetStore(),
            preferredSmartTargetIDs: { [smart.id] }
        )

        model.refreshTargetSections(availableTargets: [], recentTargets: [recent])
        model.setActiveTargetID(recent.id)

        model.refreshTargetSections(availableTargets: [], recentTargets: [])

        #expect(model.activeTargetID == nil)

        model.refreshTargetSections(availableTargets: [smart], recentTargets: [smart])
        model.setActiveTargetID(smart.id)

        model.refreshTargetSections(availableTargets: [smart], recentTargets: [])

        #expect(model.activeTargetID == smart.id)
    }
}

@MainActor
private func makeSidebarRecentTargetStore(
    isAvailable: @escaping (ScanTarget) -> Bool = { _ in true }
) -> RecentTargetStore {
    RecentTargetStore(
        persistence: TestRecentTargetPersistence(),
        isAvailable: isAvailable
    )
}

private func makeSidebarTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}
