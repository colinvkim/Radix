import Combine
import Foundation

struct SidebarTargetDisplay: Equatable, Identifiable {
    let target: ScanTarget
    let subtitle: String

    var id: String {
        target.id
    }
}

@MainActor
final class SidebarModel: ObservableObject {
    @Published private(set) var smartTargetRows: [SidebarTargetDisplay] = []
    @Published private(set) var recentScanTargetRows: [SidebarTargetDisplay] = []
    @Published private(set) var activeTargetID: String?
    @Published private(set) var targetCapacityDescriptions: [String: String] = [:]

    private let recentTargetStore: RecentTargetStore
    private let preferredSmartTargetIDs: () -> [String]
    private var availableTargets: [ScanTarget] = []
    private var recentTargets: [ScanTarget] = []

    init(
        recentTargetStore: RecentTargetStore,
        preferredSmartTargetIDs: @escaping () -> [String]
    ) {
        self.recentTargetStore = recentTargetStore
        self.preferredSmartTargetIDs = preferredSmartTargetIDs
    }

    var smartTargets: [ScanTarget] {
        smartTargetRows.map(\.target)
    }

    var recentScanTargets: [ScanTarget] {
        recentScanTargetRows.map(\.target)
    }

    func refreshTargetSections(
        availableTargets: [ScanTarget],
        recentTargets: [ScanTarget]
    ) {
        self.availableTargets = availableTargets
        self.recentTargets = recentTargets
        rebuildTargetSections()
    }

    func replaceTargetCapacityDescriptions(_ descriptions: [String: String]) {
        guard targetCapacityDescriptions != descriptions else { return }

        targetCapacityDescriptions = descriptions
        rebuildTargetRows()
    }

    func setActiveTargetID(_ id: String?) {
        guard activeTargetID != id else { return }

        activeTargetID = id
    }

    func clearActiveTargetIfNeededAfterRemovingRecentTarget(_ target: ScanTarget) {
        guard activeTargetID == target.id,
              !smartTargetRows.contains(where: { $0.id == target.id }) else {
            return
        }

        activeTargetID = nil
    }

    func target(id: String) -> ScanTarget? {
        availableTargets.first { $0.id == id }
            ?? recentScanTargetRows.first { $0.id == id }?.target
    }

    func subtitle(for target: ScanTarget) -> String {
        if target.kind == .volume,
           let capacityDescription = targetCapacityDescriptions[target.id] {
            return capacityDescription
        }
        return target.url.path
    }

    private func rebuildTargetSections() {
        let smartTargets = makeSmartTargets()
        let excludedTargetIDs = Set(smartTargets.map(\.id))
        let recentScanTargets = recentTargetStore
            .availableTargets(from: recentTargets)
            .filter { !excludedTargetIDs.contains($0.id) }

        smartTargetRows = smartTargets.map(makeTargetDisplay)
        recentScanTargetRows = recentScanTargets.map(makeTargetDisplay)
        clearActiveTargetIfMissing()
    }

    private func rebuildTargetRows() {
        smartTargetRows = smartTargetRows.map { makeTargetDisplay(for: $0.target) }
        recentScanTargetRows = recentScanTargetRows.map { makeTargetDisplay(for: $0.target) }
    }

    private func makeTargetDisplay(for target: ScanTarget) -> SidebarTargetDisplay {
        SidebarTargetDisplay(target: target, subtitle: subtitle(for: target))
    }

    private func clearActiveTargetIfMissing() {
        guard let activeTargetID,
              !smartTargetRows.contains(where: { $0.id == activeTargetID }),
              !recentScanTargetRows.contains(where: { $0.id == activeTargetID }) else {
            return
        }

        self.activeTargetID = nil
    }

    private func makeSmartTargets() -> [ScanTarget] {
        let indexedTargets = Dictionary(uniqueKeysWithValues: availableTargets.map { ($0.id, $0) })
        let preferredTargets = preferredSmartTargetIDs().compactMap { indexedTargets[$0] }
        let preferredTargetIDs = Set(preferredTargets.map(\.id))
        let additionalVolumeTargets = availableTargets.filter { target in
            target.kind == .volume && !preferredTargetIDs.contains(target.id)
        }

        guard let startupDiskIndex = preferredTargets.firstIndex(where: { $0.url.path == "/" }) else {
            return additionalVolumeTargets + preferredTargets
        }

        var targets = preferredTargets
        targets.insert(contentsOf: additionalVolumeTargets, at: startupDiskIndex + 1)
        return targets
    }
}
