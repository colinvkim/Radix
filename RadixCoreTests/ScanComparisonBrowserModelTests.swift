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
    func testDefaultProcessorBuildsSearchIndexOnlyForNonemptySearch() async throws {
        let rows = [makeRow("first.txt"), makeRow("second.txt")]
        let emptyOutput = try await ScanComparisonBrowserModel.process(
            ScanComparisonBrowserModel.WorkInput(
                rows: rows,
                changeTree: .empty,
                query: query(""),
                searchIndex: nil
            )
        )

        #expect(emptyOutput.searchIndex == nil)

        let searchOutput = try await ScanComparisonBrowserModel.process(
            ScanComparisonBrowserModel.WorkInput(
                rows: rows,
                changeTree: .empty,
                query: query("second"),
                searchIndex: nil
            )
        )

        #expect(searchOutput.searchIndex != nil)
        #expect(searchOutput.rows.map(\.name) == ["second.txt"])
    }

    @Test
    func testDefaultProcessorRebuildsSearchIndexForReplacementDataset() async throws {
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
    func testProjectionReuseRequiresCompletedMatchingDatasetAndKinds() async throws {
        let recorder = ComparisonProcessorRecorder()
        let model = ScanComparisonBrowserModel(
            searchDebounceNanoseconds: 0,
            processor: { try await recorder.process($0) }
        )
        let id = UUID()
        let rows = [makeRow("first.txt")]
        let requests: [(UUID, ScanComparisonRowQuery)] = [
            (id, query("")),
            (id, .init(searchText: "", sortOrder: [], pathPrefix: "folder")),
            (id, .init(searchText: "", sortOrder: [.defaultOrder])),
            (id, query("first")),
            (id, query("first", changeKinds: [.added])),
            (UUID(), query("first", changeKinds: [.added])),
        ]
        for (comparisonID, query) in requests {
            model.refresh(comparisonID: comparisonID, rows: rows, changeTree: .empty, query: query)
            try await waitUntil { !model.isRefreshing }
        }
        let reused = await recorder.reusedProjections
        #expect(reused == [false, true, true, true, false, false])
        model.cancel()
        let last = try #require(requests.last)
        model.refresh(comparisonID: last.0, rows: rows, changeTree: .empty, query: last.1)
        try await waitUntil { !model.isRefreshing }
        let reusedAfterCancel = await recorder.reusedProjections.last
        #expect(reusedAfterCancel == false)
    }

    @Test
    func testDefaultProcessorUsesSuppliedProjection() async throws {
        let expected = ScanComparisonChangeTree.empty.significantProjection(changeKinds: [.added])
        let output = try await ScanComparisonBrowserModel.process(
            .init(
                rows: [], changeTree: .empty, query: query(""), searchIndex: nil,
                projection: expected
            ))
        #expect(output.projection == expected)
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
            projection: input.changeTree.significantProjection(changeKinds: input.query.changeKinds)
        )
    }

    func resumeRequest(at index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }
}

private actor ComparisonProcessorRecorder {
    private(set) var searchTexts: [String] = []
    private(set) var reusedProjections: [Bool] = []

    func process(
        _ input: ScanComparisonBrowserModel.WorkInput
    ) throws -> ScanComparisonBrowserModel.WorkOutput {
        searchTexts.append(input.query.searchText)
        reusedProjections.append(input.projection != nil)
        return ScanComparisonBrowserModel.WorkOutput(
            rows: try input.query.applying(
                to: input.rows,
                cancellationCheck: {}
            ),
            projection: input.projection ?? input.changeTree.significantProjection(changeKinds: input.query.changeKinds)
        )
    }
}
