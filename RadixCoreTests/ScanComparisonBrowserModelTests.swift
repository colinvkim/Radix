import Foundation
import Testing

@testable import RadixCore

@MainActor
struct ScanComparisonBrowserModelTests {
    @Test
    func testRefreshPreservesPublishedRowsThenReconcilesSelection() async throws {
        let gate = ComparisonProcessorGate()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { input in
                try await gate.process(input)
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first")
        )
        try await waitUntil { await gate.requestCount == 1 }
        await gate.resumeRequest(at: 0)
        try await waitUntil { model.displayedRows.map(\.name) == ["first.txt"] }

        model.selection = [rows[0].id]
        model.aggregateSelection = ["stale-aggregate-id"]
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second")
        )
        try await waitUntil { await gate.requestCount == 2 }

        #expect(model.isRefreshing)
        #expect(model.displayedRows.map(\.name) == ["first.txt"])
        #expect(model.selection == [rows[0].id])

        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["second.txt"] }
        #expect(!(model.isRefreshing))
        #expect(model.selection.isEmpty)
        #expect(model.aggregateSelection.isEmpty)
    }

    @Test
    func testOlderCancelledRefreshCannotOverwriteNewerResult() async throws {
        let gate = ComparisonProcessorGate()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { input in
                try await gate.process(input)
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first")
        )
        try await waitUntil { await gate.requestCount == 1 }
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second")
        )
        try await waitUntil { await gate.requestCount == 2 }

        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["second.txt"] }
        await gate.resumeRequest(at: 0)
        await Task.yield()

        #expect(model.displayedRows.map(\.name) == ["second.txt"])
        #expect(!(model.isRefreshing))
    }

    @Test
    func testCancelledRefreshCanRestartSameRequest() async throws {
        let gate = ComparisonProcessorGate()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { input in
                try await gate.process(input)
            }
        )
        let rows = [makeRow("first.txt")]
        let comparisonID = UUID()
        let query = query("first")

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query
        )
        try await waitUntil { await gate.requestCount == 1 }
        model.cancel()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query
        )
        try await waitUntil { await gate.requestCount == 2 }
        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["first.txt"] }
        await gate.resumeRequest(at: 0)

        #expect(!(model.isRefreshing))
    }

    @Test
    func testDefaultProcessorFiltersRowsAndBuildsProjection() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)
        let rows = [makeRow("first.txt"), makeRow("second.txt")]

        model.refresh(
            comparisonID: UUID(),
            rows: rows,
            changeTree: .empty,
            query: query("second", changeKinds: [.added])
        )

        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows.map(\.name) == ["second.txt"])
        #expect(model.projection.roots.isEmpty)
        #expect(model.projection.changeKinds == [.added])
    }

    @Test
    func testSearchUsesRowsFromTheReplacementComparison() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)

        model.refresh(
            comparisonID: UUID(),
            rows: [makeRow("first.txt")],
            changeTree: .empty,
            query: query("first")
        )
        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows.map(\.name) == ["first.txt"])

        model.refresh(
            comparisonID: UUID(),
            rows: [makeRow("second.txt")],
            changeTree: .empty,
            query: query("second")
        )
        try await waitUntil { !model.isRefreshing }

        #expect(model.displayedRows.map(\.name) == ["second.txt"])
    }

    @Test
    func sortingDuringARefreshUsesTheRequestedComparisonAndFilters() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)
        let id = UUID()
        let rows = ["keep-b", "other", "keep-a"].map(makeRow)
        func refresh(_ text: String, order: [ScanComparisonRowComparator], comparisonID: UUID? = nil) {
            model.refresh(
                comparisonID: comparisonID ?? id, rows: rows, changeTree: .empty,
                query: ScanComparisonRowQuery(searchText: text, sortOrder: order)
            )
        }
        let ascending = [ScanComparisonRowComparator(field: .relativePath)]
        let descending = [ScanComparisonRowComparator(field: .relativePath, order: .reverse)]
        refresh("keep", order: ascending)
        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows.map(\.name) == ["keep-a", "keep-b"])
        model.selection = [rows[0].id]

        refresh("other", order: ascending, comparisonID: UUID())
        refresh("keep", order: descending)
        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows.map(\.name) == ["keep-b", "keep-a"])
        #expect(model.selection == [rows[0].id])

        refresh("other", order: ascending)
        refresh("other", order: descending)
        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows.map(\.name) == ["other"])
        #expect(model.selection.isEmpty)

        refresh("", order: [])
        try await waitUntil { !model.isRefreshing }
        #expect(model.displayedRows == rows)
    }

    @Test
    func testRapidSearchChangesDebounceSupersededQuery() async throws {
        let recorder = ComparisonProcessorRecorder()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 1,
            processor: { input in
                try await recorder.process(input)
            },
            sleeper: { _ in
                await Task.yield()
                try Task.checkCancellation()
            }
        )
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let comparisonID = UUID()

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("")
        )
        try await waitUntil { await recorder.searchTexts.count == 1 }

        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("first")
        )
        model.refresh(
            comparisonID: comparisonID,
            rows: rows,
            changeTree: .empty,
            query: query("second")
        )

        try await waitUntil { await recorder.searchTexts.count == 2 }
        let processedSearchTexts = await recorder.searchTexts
        #expect(processedSearchTexts == ["", "second"])
    }

    @Test
    func testProjectionTracksTheSelectedKindsAndCurrentComparison() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)
        let before = makeComparisonSnapshot(rootPath: "/scan", fileSize: 10)
        let service = ScanComparisonService()
        let first = try await service.compare(
            before: before, after: makeComparisonSnapshot(rootPath: "/scan", fileSize: 20))
        let second = try await service.compare(
            before: before, after: makeComparisonSnapshot(rootPath: "/scan", fileSize: 40))

        let cases: [(ScanComparison, ScanComparisonChangeKind, Int64)] = [
            (first, .added, 0),
            (first, .grew, 10),
            (second, .grew, 30),
        ]
        for (comparison, kind, growth) in cases {
            model.refresh(
                comparisonID: comparison.id, rows: comparison.rows,
                changeTree: comparison.changeTree, query: query("", changeKinds: [kind])
            )
            try await waitUntil { !model.isRefreshing }
            #expect(model.projection.changeKinds == [kind])
            #expect(model.projection.totalImpact == growth)
        }
    }

    private func query(
        _ searchText: String,
        changeKinds: Set<ScanComparisonChangeKind> = Set(ScanComparisonChangeKind.allCases)
    ) -> ScanComparisonRowQuery {
        ScanComparisonRowQuery(
            changeKinds: changeKinds,
            searchText: searchText,
            sortOrder: [ScanComparisonRowComparator.defaultOrder]
        )
    }

    private func makeRow(_ name: String) -> ScanComparisonRow {
        let relativePath = "folder/\(name)"
        let url = URL(filePath: "/root/\(relativePath)", directoryHint: .notDirectory)
        let node = FileNodeRecord(
            id: url.path,
            url: url,
            name: name,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 1,
            logicalSize: 1,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        return ScanComparisonRow(
            relativePath: relativePath,
            kind: .added,
            beforeNode: nil,
            afterNode: node
        )
    }

}

private actor ComparisonProcessorGate {
    private var inputs: [ScanComparisonBrowserModel.WorkInput] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    var requestCount: Int { inputs.count }

    func process(
        _ input: ScanComparisonBrowserModel.WorkInput
    ) async throws -> ScanComparisonBrowserModel.WorkOutput {
        let index = inputs.count
        inputs.append(input)
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
        return ScanComparisonBrowserModel.WorkOutput(
            rows: try input.query.applying(
                to: input.rows,
                cancellationCheck: {}
            ),
            projection: input.changeTree.significantProjection(changeKinds: input.query.changeKinds, cancellationCheck: {})
        )
    }

    func resumeRequest(at index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }
}

private actor ComparisonProcessorRecorder {
    private(set) var searchTexts: [String] = []

    func process(
        _ input: ScanComparisonBrowserModel.WorkInput
    ) throws -> ScanComparisonBrowserModel.WorkOutput {
        searchTexts.append(input.query.searchText)
        return ScanComparisonBrowserModel.WorkOutput(
            rows: try input.query.applying(
                to: input.rows,
                cancellationCheck: {}
            ),
            projection: input.projection ?? input.changeTree.significantProjection(changeKinds: input.query.changeKinds, cancellationCheck: {})
        )
    }
}
