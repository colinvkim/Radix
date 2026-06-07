//
//  RecentTargetStore.swift
//  Radix
//

import Foundation

protocol RecentTargetPersisting: AnyObject {
    func loadRecentTargets() -> [ScanTarget]
    func saveRecentTargets(_ targets: [ScanTarget])
    func clearRecentTargets()
}

final class UserDefaultsRecentTargetPersistence: RecentTargetPersisting {
    private enum Key {
        static let recentTargets = "recentTargets"
    }

    private struct StoredRecentTarget: Codable {
        let path: String
        let kind: ScanTargetKind
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecentTargets() -> [ScanTarget] {
        guard let data = defaults.data(forKey: Key.recentTargets) else {
            return []
        }

        do {
            let storedTargets = try JSONDecoder().decode([StoredRecentTarget].self, from: data)
            return storedTargets.map { storedTarget in
                ScanTarget(
                    url: URL(filePath: storedTarget.path, directoryHint: .isDirectory),
                    kind: storedTarget.kind
                )
            }
        } catch {
            return []
        }
    }

    func saveRecentTargets(_ targets: [ScanTarget]) {
        let storedTargets = targets.map { target in
            StoredRecentTarget(path: target.url.path, kind: target.kind)
        }

        do {
            let data = try JSONEncoder().encode(storedTargets)
            defaults.set(data, forKey: Key.recentTargets)
        } catch {
            defaults.removeObject(forKey: Key.recentTargets)
        }
    }

    func clearRecentTargets() {
        defaults.removeObject(forKey: Key.recentTargets)
    }
}

struct RecentTargetStore {
    private let persistence: any RecentTargetPersisting
    private let isAvailable: (ScanTarget) -> Bool
    private let limit: Int

    init(
        persistence: any RecentTargetPersisting,
        isAvailable: @escaping (ScanTarget) -> Bool,
        limit: Int = 10
    ) {
        self.persistence = persistence
        self.isAvailable = isAvailable
        self.limit = limit
    }

    func loadAvailableTargets() -> [ScanTarget] {
        let targets = persistence.loadRecentTargets()
        let availableTargets = availableTargets(from: targets)
        if availableTargets.map(\.id) != targets.map(\.id) {
            persistence.saveRecentTargets(availableTargets)
        }
        return availableTargets
    }

    func record(_ target: ScanTarget, currentTargets: [ScanTarget]) -> [ScanTarget] {
        var updatedTargets = currentTargets.filter { existingTarget in
            existingTarget.id != target.id && isAvailable(existingTarget)
        }

        guard isAvailable(target) else {
            persistence.saveRecentTargets(updatedTargets)
            return updatedTargets
        }

        updatedTargets.insert(target, at: 0)
        if updatedTargets.count > limit {
            updatedTargets = Array(updatedTargets.prefix(limit))
        }

        persistence.saveRecentTargets(updatedTargets)
        return updatedTargets
    }

    func availableTargets(from targets: [ScanTarget]) -> [ScanTarget] {
        targets.filter(isAvailable)
    }

    func clear() {
        persistence.clearRecentTargets()
    }
}
