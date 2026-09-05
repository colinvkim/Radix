//
//  CancellableSort.swift
//  Radix
//

nonisolated enum CancellableSort {
    /// Avoids moving large values through the chunk and merge buffers.
    static func sortedByIndex<Element>(
        _ elements: [Element],
        cancellationCheck: () throws -> Void,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) rethrows -> [Element] {
        var indices: [Int] = []
        indices.reserveCapacity(elements.count)
        for offset in elements.indices {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            indices.append(offset)
        }
        let sortedIndices = try sorted(&indices, cancellationCheck: cancellationCheck) {
            areInIncreasingOrder(elements[$0], elements[$1])
        }
        var result: [Element] = []
        result.reserveCapacity(elements.count)
        for (offset, index) in sortedIndices.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            result.append(elements[index])
        }
        try cancellationCheck()
        return result
    }

    private static let chunkSize = 16_384

    static func sorted<Element>(
        _ elements: inout [Element],
        cancellationCheck: () throws -> Void,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) rethrows -> [Element] {
        guard elements.count > chunkSize else {
            return elements.sorted(by: areInIncreasingOrder)
        }

        var source: [Element] = []
        source.reserveCapacity(elements.count)

        for start in stride(from: 0, to: elements.count, by: chunkSize) {
            try cancellationCheck()
            let end = min(start + chunkSize, elements.count)
            source.append(contentsOf: elements[start..<end].sorted(by: areInIncreasingOrder))
        }
        elements.removeAll(keepingCapacity: false)
        try cancellationCheck()

        var destination = source
        var runSize = chunkSize
        while runSize < source.count {
            let combinedRunSize = runSize * 2
            for start in stride(from: 0, to: source.count, by: combinedRunSize) {
                try mergeSortedRuns(
                    from: source,
                    into: &destination,
                    start: start,
                    middle: min(start + runSize, source.count),
                    end: min(start + combinedRunSize, source.count),
                    cancellationCheck: cancellationCheck,
                    by: areInIncreasingOrder
                )
            }
            swap(&source, &destination)
            runSize = combinedRunSize
        }
        return source
    }

    private static func mergeSortedRuns<Element>(
        from source: [Element],
        into destination: inout [Element],
        start: Int,
        middle: Int,
        end: Int,
        cancellationCheck: () throws -> Void,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) rethrows {
        var lhsIndex = start
        var rhsIndex = middle

        for writeIndex in start..<end {
            if (writeIndex - start).isMultiple(of: 256) {
                try cancellationCheck()
            }
            if lhsIndex == middle {
                destination[writeIndex] = source[rhsIndex]
                rhsIndex += 1
            } else if rhsIndex == end ||
                        !areInIncreasingOrder(source[rhsIndex], source[lhsIndex]) {
                destination[writeIndex] = source[lhsIndex]
                lhsIndex += 1
            } else {
                destination[writeIndex] = source[rhsIndex]
                rhsIndex += 1
            }
        }
    }
}
