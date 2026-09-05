import XCTest
@testable import RadixCore

final class CancellableSortTests: XCTestCase {
    func testOwnedBufferSortPreservesStableTieOrder() throws {
        let input = (0..<20_000).map { (key: $0 % 7, position: $0) }
        var values = input
        try CancellableSort.sort(&values, cancellationCheck: Task.checkCancellation) { $0.key < $1.key }
        XCTAssertEqual(values.map(\.position), input.sorted { $0.key < $1.key }.map(\.position))
    }

    func testOwnedBufferSortCanCancelDuringComparisons() {
        var values = Array((0..<100_000).reversed())
        var comparisons = 0
        XCTAssertThrowsError(try CancellableSort.sort(&values, cancellationCheck: {
            if comparisons > 0 { throw CancellationError() }
        }, by: {
            comparisons += 1
            return $0 < $1
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(comparisons, 0)
        XCTAssertLessThan(comparisons, values.count - 1)
    }

    func testOwnedBufferSortChecksCancellationForEmptyInput() {
        var values: [Int] = []
        XCTAssertThrowsError(try CancellableSort.sort(&values, cancellationCheck: {
            throw CancellationError()
        }, by: <)) { XCTAssertTrue($0 is CancellationError) }
    }
}
