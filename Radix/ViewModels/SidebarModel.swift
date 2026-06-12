//
//  SidebarModel.swift
//  Radix
//

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
    private var smartTargetValues: [ScanTarget] = []
    private var recentScanTargetValues: [ScanTarget] = []

    init(
        recentTargetStore: RecentTargetStore,
        preferredSmartTargetIDs: @escaping () -> [String]
    ) {
        self.recentTargetStore = recentTargetStore
        self.preferredSmartTargetIDs = preferredSmartTargetIDs
    }

    var smartTargets: [ScanTarget] {
        smartTargetValues
    }

    var recentScanTargets: [ScanTarget] {
        recentScanTargetValues
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
              !smartTargetValues.contains(where: { $0.id == target.id }) else {
            return
        }

        activeTargetID = nil
    }

    func target(id: String) -> ScanTarget? {
        (availableTargets + recentScanTargetValues).first { $0.id == id }
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

        smartTargetValues = smartTargets
        recentScanTargetValues = recentScanTargets
        rebuildTargetRows()
        clearActiveTargetIfMissing()
    }

    private func rebuildTargetRows() {
        smartTargetRows = smartTargetValues.map(makeTargetDisplay)
        recentScanTargetRows = recentScanTargetValues.map(makeTargetDisplay)
    }

    private func makeTargetDisplay(for target: ScanTarget) -> SidebarTargetDisplay {
        SidebarTargetDisplay(target: target, subtitle: subtitle(for: target))
    }

    private func clearActiveTargetIfMissing() {
        guard let activeTargetID,
              !smartTargetValues.contains(where: { $0.id == activeTargetID }),
              !recentScanTargetValues.contains(where: { $0.id == activeTargetID }) else {
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
