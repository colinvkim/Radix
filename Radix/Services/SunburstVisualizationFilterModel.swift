//
//  SunburstVisualizationFilterModel.swift
//  Radix
//

import Combine
import Foundation

@MainActor
final class SunburstVisualizationFilterModel: ObservableObject {
    @Published private var cachedResult: SunburstVisualizationFilterResult?

    private var pendingKey: SunburstVisualizationFilterKey?
    private var filterTask: Task<Void, Never>?

    deinit {
        filterTask?.cancel()
    }

    func input(
        baseInput: SunburstVisualizationInput,
        snapshotID: UUID,
        focusNodeID: FileNodeRecord.ID,
        hiddenNodeIDs: Set<FileNodeRecord.ID>
    ) -> SunburstVisualizationInput {
        guard !hiddenNodeIDs.isEmpty else {
            clearFilter()
            return baseInput
        }

        let key = SunburstVisualizationFilterKey(
            snapshotID: snapshotID,
            focusNodeID: focusNodeID,
            rootNodeID: baseInput.rootNode.id,
            baseLayoutIDComponent: baseInput.layoutIDComponent,
            hiddenNodeIDs: hiddenNodeIDs.sorted()
        )

        if cachedResult?.key == key {
            return cachedResult?.input ?? baseInput
        }

        if pendingKey != key {
            startFiltering(baseInput: baseInput, key: key)
        }

        return baseInput
    }

    private func startFiltering(
        baseInput: SunburstVisualizationInput,
        key: SunburstVisualizationFilterKey
    ) {
        filterTask?.cancel()
        pendingKey = key

        filterTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let filteredStore = try baseInput.treeStore.removingSubtrees(
                    rootedAt: key.hiddenNodeIDs,
                    cancellationCheck: Task.checkCancellation
                )
                return SunburstVisualizationInput(
                    rootNode: filteredStore.node(id: baseInput.rootNode.id) ?? filteredStore.root,
                    treeStore: filteredStore,
                    layoutIDComponent: [
                        baseInput.layoutIDComponent,
                        key.discardPileLayoutComponent
                    ].joined(separator: "|")
                )
            }

            do {
                let input = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                self?.cache(input, for: key)
            } catch is CancellationError {
                return
            } catch {
                self?.clearPendingFilter(for: key)
            }
        }
    }

    private func cache(_ input: SunburstVisualizationInput, for key: SunburstVisualizationFilterKey) {
        guard pendingKey == key else { return }
        cachedResult = SunburstVisualizationFilterResult(key: key, input: input)
        pendingKey = nil
        filterTask = nil
    }

    private func clearPendingFilter(for key: SunburstVisualizationFilterKey) {
        guard pendingKey == key else { return }
        pendingKey = nil
        filterTask = nil
    }

    private func clearFilter() {
        guard filterTask != nil || pendingKey != nil || cachedResult != nil else { return }
        filterTask?.cancel()
        filterTask = nil
        pendingKey = nil
        cachedResult = nil
    }
}

private nonisolated struct SunburstVisualizationFilterResult {
    let key: SunburstVisualizationFilterKey
    let input: SunburstVisualizationInput
}

private nonisolated struct SunburstVisualizationFilterKey: Hashable, Sendable {
    let snapshotID: UUID
    let focusNodeID: FileNodeRecord.ID
    let rootNodeID: FileNodeRecord.ID
    let baseLayoutIDComponent: String
    let hiddenNodeIDs: [FileNodeRecord.ID]

    nonisolated var discardPileLayoutComponent: String {
        hiddenNodeIDs.reduce("discard-pile:\(hiddenNodeIDs.count)") { component, id in
            component + ":\(id.count):\(id)"
        }
    }
}
