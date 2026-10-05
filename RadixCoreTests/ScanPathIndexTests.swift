import Foundation
import Testing

@testable import RadixCore

struct ScanPathIndexTests {
    @Test(arguments: ["/ascii", "/café"])
    func testFinalLookupPreservesOffsetsAfterDiscoveryStateIsReleased(prefix: String) throws {
        let (index, nodes) = try Self.discover(prefix: prefix)
        var progress: [Int] = []
        let lookup = try index.nodeIndex(
            nodes: nodes, progressInterval: 256, cancellationCheck: {}
        ) { progress.append($0) }

        #expect(lookup.count == nodes.count)
        for (offset, node) in nodes.enumerated() {
            #expect(lookup[node.id]?.rawValue == UInt32(offset))
        }
        #expect(progress == [256, 512, 768, 1_024, 1_025])
    }

    @Test(arguments: ["/ascii", "/café"])
    func testCancellationDuringFinalLookup(prefix: String) throws {
        let (index, nodes) = try Self.discover(prefix: prefix)
        var cancelled = false
        var progress: [Int] = []
        #expect(throws: CancellationError.self) {
            try index.nodeIndex(nodes: nodes, progressInterval: 256, cancellationCheck: {
                if cancelled { throw CancellationError() }
            }) { count in
                progress.append(count)
                cancelled = true
            }
        }
        #expect(progress == [256])
    }

    private static func discover(prefix: String) throws -> (ScanPathIndex, [FileNodeRecord]) {
        var index = ScanPathIndex()
        let paths = [prefix] + (0..<1_024).map { "\(prefix)/file-\($0)" }
        for (key, path) in paths.enumerated() {
            let inserted = try index.insert(path: path, parentKey: key == 0 ? -1 : 0,
                                        scanKey: key, mayHaveChildren: key == 0)
            #expect(inserted)
        }
        index.releaseDiscoveryState()
        return (index, paths.reversed().map { makeTestFileNode(id: $0, name: $0) })
    }

    @Test
    func testParentNameDiscoveryPreservesGlobalPathEquality() throws {
        var index = ScanPathIndex()
        var reference: Set<String> = []
        // Parent indices are hints; paths from another parent must still dedupe.
        let entries: [(String, Int, Bool)] = [
            ("/", -1, true), ("/café", 0, true), ("/other", 0, true),
            ("/café/file", 1, false), ("/cafe\u{301}/file", 2, false),
            ("/café/file", 2, false), ("/other/file", 1, false),
            ("/other/file", 2, false), ("/café/文件😀", 1, false),
            ("/other/文件😀", 2, false), ("/café/100% #?.dat", 1, false),
            ("/café/a/b", 1, false), ("/café/a/b", 2, false),
            ("//file", 0, false), ("/file", 0, false), ("file", -1, false),
            ("", -1, false), ("/", 0, false), ("/other/", 2, true),
            ("/other/file", 18, false),
            // Canonical equivalence can cross the ASCII/Unicode routing boundary.
            ("/K", 0, true), ("/K/file", 2, false), ("/K/file", 20, false),
            ("/K", 0, true), ("/K-first", 0, true),
            ("/K-first/file", 24, false), ("/K-first/file", 2, false)
        ]
        for (ordinal, entry) in entries.enumerated() {
            #expect(try index.insert(path: entry.0, parentKey: entry.1, scanKey: ordinal,
                                 mayHaveChildren: entry.2) == reference.insert(entry.0).inserted)
        }
        for ordinal in 0..<2_000 {
            let path = "/café/entry-\(ordinal % 137)-é"
            #expect(try index.insert(path: path, parentKey: ordinal % 3, scanKey: ordinal + entries.count,
                                 mayHaveChildren: false) == reference.insert(path).inserted)
        }
    }

    @Test
    func testLateUnicodeDirectoryMigratesEarlierUnexpectedDiscoveries() throws {
        var index = ScanPathIndex()
        let entries: [(String, Int, Bool)] = [
            ("/", -1, true), ("/ascii", 0, true),
            ("/café/file", 1, false), ("/ascii/文件", 1, false),
            ("/K-first/file", 1, false), ("/café", 0, true),
            ("/K-first", 0, true)
        ]
        for (key, entry) in entries.enumerated() {
            let inserted = try index.insert(path: entry.0, parentKey: entry.1, scanKey: key,
                                        mayHaveChildren: entry.2)
            #expect(inserted)
        }
        #expect(try index.insert(path: "/cafe\u{301}/file", parentKey: 5, scanKey: 7,
                             mayHaveChildren: false) == false)
        #expect(try index.insert(path: "/ascii/文件", parentKey: 5, scanKey: 7,
                             mayHaveChildren: false) == false)
        #expect(try index.insert(path: "/K-first/file", parentKey: 6, scanKey: 7,
                             mayHaveChildren: false) == false)
        index.releaseDiscoveryState()
        let nodes = entries.reversed().map { makeTestFileNode(id: $0.0, name: $0.0) }
        let lookup = try index.nodeIndex(nodes: nodes, progressInterval: 512,
                                         cancellationCheck: {}, indexingProgress: { _ in })
        for (offset, node) in nodes.enumerated() {
            #expect(lookup[node.id]?.rawValue == UInt32(offset))
        }
    }
}
