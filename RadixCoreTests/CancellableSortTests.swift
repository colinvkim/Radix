import Testing

@testable import RadixCore

struct CancellableSortTests {
    enum Algorithm: CaseIterable, Sendable {
        case ownedBuffer, chunked, indexed

        func sort(_ input: [(key: Int, position: Int)], cancellationCheck: () throws -> Void) rethrows -> [(
            key: Int, position: Int
        )] {
            var values = input
            switch self {
            case .ownedBuffer:
                try CancellableSort.sort(&values, cancellationCheck: cancellationCheck) { $0.key < $1.key }
                return values
            case .chunked:
                return try CancellableSort.sorted(&values, cancellationCheck: cancellationCheck) { $0.key < $1.key }
            case .indexed:
                return try CancellableSort.sortedByIndex(values, cancellationCheck: cancellationCheck) {
                    $0.key < $1.key
                }
            }
        }
    }

    // Boundaries exercise empty/singleton inputs, exact chunks, partial final
    // chunks, and more than one merge pass for every public sorting entry point.
    @Test(arguments: Algorithm.allCases, [0, 1, 255, 256, 16_383, 16_384, 16_385, 32_769, 50_000])
    func stableSortPreservesEveryElement(algorithm: Algorithm, count: Int) throws {
        let input = (0..<count).map { (key: ($0 * 13) % 7, position: $0) }
        let sorted = try algorithm.sort(input, cancellationCheck: Task.checkCancellation)
        #expect(sorted.count == input.count)
        try #require(Set(sorted.map(\.position)) == Set(0..<count))
        #expect(sorted.allSatisfy { $0.key == input[$0.position].key })
        // Check the contract independently instead of comparing two uses of sort.
        #expect(
            zip(sorted, sorted.dropFirst()).allSatisfy { previous, next in
                previous.key < next.key || (previous.key == next.key && previous.position < next.position)
            })
    }

    @Test(arguments: Algorithm.allCases, [0, 1, 20_000])
    func alreadyCancelledSortDoesNotReturnResults(algorithm: Algorithm, count: Int) {
        let input = (0..<count).map { (key: $0, position: $0) }
        #expect(throws: CancellationError.self) {
            try algorithm.sort(input) { throw CancellationError() }
        }
    }

    @Test(arguments: [4_096, 40_000])
    func chunkedSortChecksCancellationWithinSmallInputsAndRuns(count: Int) {
        var values = Array((0..<count).reversed())
        var comparisons = 0
        #expect(throws: CancellationError.self) {
            try CancellableSort.sorted(
                &values,
                cancellationCheck: {
                    if comparisons > 0 { throw CancellationError() }
                },
                by: {
                    comparisons += 1
                    return $0 < $1
                })
        }
        #expect(comparisons > 0)
        #expect(comparisons < 1_024)
    }

    @Test
    func ownedBufferSortCanCancelDuringComparisons() {
        var values = Array((0..<100_000).reversed())
        var comparisons = 0
        #expect(throws: CancellationError.self) {
            try CancellableSort.sort(
                &values,
                cancellationCheck: {
                    if comparisons > 0 { throw CancellationError() }
                },
                by: {
                    comparisons += 1
                    return $0 < $1
                })
        }
        #expect(comparisons > 0)
        #expect(comparisons < values.count - 1)
    }
}
