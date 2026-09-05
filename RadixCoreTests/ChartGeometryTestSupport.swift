import Foundation
@testable import RadixCore

/// Counts projection work at the tree boundary without inspecting layout internals.
nonisolated final class ChartReadProbe: DiskMapTreeReading, @unchecked Sendable {
    let store: FileTreeStore
    private let lock = NSLock()
    private var readsByID: [String: Int] = [:]
    private var projectedCount = 0

    init(_ store: FileTreeStore) { self.store = store }

    var rootID: String { store.rootID }
    var projectedNodeCount: Int { lock.withLock { projectedCount } }
    func childReadCount(for id: String) -> Int { lock.withLock { readsByID[id] ?? 0 } }
    func node(id: String?) -> FileNodeRecord? { store.node(id: id) }
    func parentID(of id: String?) -> String? { store.parentID(of: id) }
    func path(to id: String?) -> [FileNodeRecord] { store.path(to: id) }

    func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    func children(of id: String?, cancellationCheck: () throws -> Void) throws -> [FileNodeRecord] {
        let result = try store.children(of: id, cancellationCheck: cancellationCheck)
        lock.withLock {
            readsByID[id ?? rootID, default: 0] += 1
            projectedCount += result.count
        }
        return result
    }
}
