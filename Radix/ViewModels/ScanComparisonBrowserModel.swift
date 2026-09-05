import Combine
import Foundation

/// Owns the derived state used by the comparison browser. Expensive filtering,
/// sorting, and significant-tree projection happen away from the main actor;
/// only the latest completed request is allowed to publish.
@MainActor
final class ScanComparisonBrowserModel: ObservableObject {
    nonisolated struct WorkInput: Equatable, Sendable {
        let rows: [ScanComparisonRow]
        let changeTree: ScanComparisonChangeTree
        let query: ScanComparisonRowQuery
        let searchIndex: ScanComparisonSearchIndex?
        var projection: ScanComparisonChangeTreeProjection? = nil
    }

    nonisolated struct WorkOutput: Equatable, Sendable {
        let rows: [ScanComparisonRow]
        let projection: ScanComparisonChangeTreeProjection
        let searchIndex: ScanComparisonSearchIndex?

        init(
            rows: [ScanComparisonRow],
            projection: ScanComparisonChangeTreeProjection,
            searchIndex: ScanComparisonSearchIndex? = nil
        ) {
            self.rows = rows
            self.projection = projection
            self.searchIndex = searchIndex
        }
    }

    typealias Processor = @Sendable (WorkInput) async throws -> WorkOutput
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    @Published private(set) var displayedRows: [ScanComparisonRow] = []
    @Published private(set) var projection = ScanComparisonChangeTreeProjection(
        roots: [],
        changeKinds: [],
        namedRootCount: 0,
        hiddenRootCount: 0,
        representedImpact: 0,
        totalImpact: 0,
        groupedAffectedCount: 0
    )
    @Published private(set) var isRefreshing = false
    @Published var selection = Set<ScanComparisonRow.ID>()
    @Published var aggregateSelection = Set<ScanComparisonChangeTreeNode.ID>()

    private let searchDebounceNanoseconds: UInt64
    private let processor: Processor
    private let sleeper: Sleeper
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var latestComparisonID: UUID?
    private var latestQuery: ScanComparisonRowQuery?
    private var searchIndex: ScanComparisonSearchIndex?
    private var projectionComparisonID: UUID?

    init(
        searchDebounceNanoseconds: UInt64 = 200_000_000,
        processor: @escaping Processor = ScanComparisonBrowserModel.process,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.processor = processor
        self.sleeper = sleeper
    }

    func refresh(
        comparisonID: UUID,
        rows: [ScanComparisonRow],
        changeTree: ScanComparisonChangeTree,
        query: ScanComparisonRowQuery
    ) {
        guard latestComparisonID != comparisonID ||
                latestQuery != query else {
            return
        }

        let datasetChanged = latestComparisonID != comparisonID
        let shouldDebounceSearch = !datasetChanged &&
            latestQuery?.searchText != query.searchText
        if datasetChanged {
            searchIndex = nil
        }
        latestComparisonID = comparisonID
        latestQuery = query

        refreshTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let input = WorkInput(
            rows: rows,
            changeTree: changeTree,
            query: query,
            searchIndex: searchIndex,
            projection: projectionComparisonID == comparisonID && projection.changeKinds == query.changeKinds
                ? projection : nil
        )
        let processor = self.processor
        let sleeper = self.sleeper
        let debounceNanoseconds = shouldDebounceSearch ? searchDebounceNanoseconds : 0
        isRefreshing = true

        refreshTask = Task { [weak self] in
            do {
                if debounceNanoseconds > 0 {
                    try await sleeper(debounceNanoseconds)
                }
                let output = try await processor(input)
                try Task.checkCancellation()
                guard let self, generation == requestGeneration else { return }

                displayedRows = output.rows
                if input.projection == nil {
                    projection = output.projection
                    projectionComparisonID = comparisonID
                }
                searchIndex = output.searchIndex ?? searchIndex
                selection.formIntersection(output.rows.lazy.map(\.id))
                aggregateSelection = aggregateSelection.filter {
                    output.projection.node(withID: $0) != nil
                }
                isRefreshing = false
                refreshTask = nil
            } catch {
                guard let self, generation == requestGeneration else { return }
                isRefreshing = false
                refreshTask = nil
            }
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        generation &+= 1
        latestComparisonID = nil
        latestQuery = nil
        searchIndex = nil
        projectionComparisonID = nil
        isRefreshing = false
    }

    nonisolated static func process(_ input: WorkInput) async throws -> WorkOutput {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let cancellationCheck: CancellationCheck = {
                try Task.checkCancellation()
            }
            let searchIndex: ScanComparisonSearchIndex?
            if let existingSearchIndex = input.searchIndex {
                searchIndex = existingSearchIndex
            } else if input.query.hasSearchText {
                searchIndex = try ScanComparisonSearchIndex(
                    rows: input.rows,
                    cancellationCheck: cancellationCheck
                )
            } else {
                searchIndex = nil
            }
            let rows = try input.query.applying(
                to: input.rows,
                searchIndex: searchIndex,
                cancellationCheck: cancellationCheck
            )
            try Task.checkCancellation()
            let projection = try input.projection ?? input.changeTree.significantProjection(
                changeKinds: input.query.changeKinds,
                cancellationCheck: cancellationCheck
            )
            try Task.checkCancellation()
            return WorkOutput(
                rows: rows,
                projection: projection,
                searchIndex: searchIndex
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
