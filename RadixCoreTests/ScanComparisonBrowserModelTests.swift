import XCTest
@testable import RadixCore

@MainActor
final class ScanComparisonBrowserModelTests: XCTestCase {
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

        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.displayedRows.map(\.name), ["first.txt"])
        XCTAssertEqual(model.selection, [rows[0].id])

        await gate.resumeRequest(at: 1)
        try await waitUntil { model.displayedRows.map(\.name) == ["second.txt"] }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.aggregateSelection.isEmpty)
    }

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

        XCTAssertEqual(model.displayedRows.map(\.name), ["second.txt"])
        XCTAssertFalse(model.isRefreshing)
    }

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

        XCTAssertFalse(model.isRefreshing)
    }

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
        XCTAssertEqual(model.displayedRows.map(\.name), ["second.txt"])
        XCTAssertTrue(model.projection.roots.isEmpty)
        XCTAssertEqual(model.projection.changeKinds, [.added])
    }

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

        XCTAssertNil(emptyOutput.searchIndex)

        let searchOutput = try await ScanComparisonBrowserModel.process(
            ScanComparisonBrowserModel.WorkInput(
                rows: rows,
                changeTree: .empty,
                query: query("second"),
                searchIndex: nil
            )
        )

        XCTAssertNotNil(searchOutput.searchIndex)
        XCTAssertEqual(searchOutput.rows.map(\.name), ["second.txt"])
    }

    func testDefaultProcessorRebuildsSearchIndexForReplacementDataset() async throws {
        let model = ScanComparisonBrowserModel(searchDebounceNanoseconds: 0)

        model.refresh(
            comparisonID: UUID(),
            rows: [makeRow("first.txt")],
            changeTree: .empty,
            query: query("first")
        )
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.displayedRows.map(\.name), ["first.txt"])

        model.refresh(
            comparisonID: UUID(),
            rows: [makeRow("second.txt")],
            changeTree: .empty,
            query: query("second")
        )
        try await waitUntil { !model.isRefreshing }

        XCTAssertEqual(model.displayedRows.map(\.name), ["second.txt"])
    }

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
        XCTAssertEqual(processedSearchTexts, ["", "second"])
    }

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
            (UUID(), query("first", changeKinds: [.added]))
        ]
        for (comparisonID, query) in requests {
            model.refresh(comparisonID: comparisonID, rows: rows, changeTree: .empty, query: query)
            try await waitUntil { !model.isRefreshing }
        }
        let reused = await recorder.reusedProjections
        XCTAssertEqual(reused, [false, true, true, true, false, false])
        model.cancel()
        let last = try XCTUnwrap(requests.last)
        model.refresh(comparisonID: last.0, rows: rows, changeTree: .empty, query: last.1)
        try await waitUntil { !model.isRefreshing }
        let reusedAfterCancel = await recorder.reusedProjections.last
        XCTAssertEqual(reusedAfterCancel, false)
    }

    func testDefaultProcessorUsesSuppliedProjection() async throws {
        let expected = ScanComparisonChangeTree.empty.significantProjection(changeKinds: [.added])
        let output = try await ScanComparisonBrowserModel.process(.init(
            rows: [], changeTree: .empty, query: query(""), searchIndex: nil,
            projection: expected
        ))
        XCTAssertEqual(output.projection, expected)
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
