import Darwin
import Foundation

/// Rejects duplicate discoveries without repeatedly normalizing long Unicode
/// prefixes. ASCII prefixes keep the scanner's existing full-path dictionary.
/// Parent keys are hints: unexpected paths resolve their actual namespace.
nonisolated struct ScanPathIndex {
    private struct Key: Hashable {
        let namespace: Int
        let name: String
    }

    private struct Namespace {
        let id: Int
        let usesParentKeys: Bool
    }

    private enum Parent {
        case pending(String)
        case indexed(Namespace, [UInt8])
    }

    private var keys: Set<Key> = []
    private var directoryNamespaces: [String: Namespace] = [:]
    private var parents: [Int: Parent] = [:]
    private var fullPathKeys: [String: Int] = [:]
    private var compactScanKeys: [Int] = []
    private var usesCompactKeys = false

    @inline(__always)
    mutating func insert(path: String, parentKey: Int, scanKey: Int, mayHaveChildren: Bool) -> Bool {
        if !usesCompactKeys, mayHaveChildren, path.utf8.contains(where: { $0 >= 0x80 }) {
            activateCompactKeys()
        }
        let key = usesCompactKeys ? discoveryKey(for: path, parentKey: parentKey) : nil
        if let key {
            guard keys.insert(key).inserted else { return false }
            compactScanKeys.append(scanKey)
        } else if let previousKey = fullPathKeys.updateValue(scanKey, forKey: path) {
            fullPathKeys[path] = previousKey
            return false
        }
        if mayHaveChildren {
            parents[scanKey] = .pending(path)
        }
        return true
    }

    private mutating func activateCompactKeys() {
        usesCompactKeys = true
        // Unexpected Unicode paths may precede their directory. Migrate those
        // discoveries so changing routes preserves global duplicate equality.
        var compactPaths: [String] = []
        for (path, scanKey) in fullPathKeys {
            let isASCII = path.utf8.withContiguousStorageIfAvailable {
                $0.reduce(UInt8(0), |) < 0x80
            } ?? path.utf8.allSatisfy { $0 < 0x80 }
            if isASCII { continue }
            if let key = discoveryKey(for: path, parentKey: -1) {
                keys.insert(key)
                compactScanKeys.append(scanKey)
                compactPaths.append(path)
            }
        }
        for path in compactPaths { fullPathKeys.removeValue(forKey: path) }
    }

    private mutating func resolvedParent(for scanKey: Int) -> Parent? {
        guard let parent = parents[scanKey] else { return nil }
        guard case .pending(let path) = parent else { return parent }
        let indexed = indexedParent(for: path)
        parents[scanKey] = indexed
        return indexed
    }

    private mutating func indexedParent(for path: String) -> Parent {
        var utf8Path = path
        var prefix = utf8Path.withUTF8 { Array($0) }
        if prefix.last != UInt8(ascii: "/") { prefix.append(UInt8(ascii: "/")) }
        return .indexed(namespace(for: String(decoding: prefix, as: UTF8.self)), prefix)
    }

    @inline(__always)
    private mutating func discoveryKey(for path: String, parentKey: Int) -> Key? {
        if let key = path.utf8.withContiguousStorageIfAvailable({
            discoveryKey(in: $0, parentKey: parentKey)
        }) {
            return key
        }
        var utf8Path = path
        return utf8Path.withUTF8 { discoveryKey(in: $0, parentKey: parentKey) }
    }

    @inline(__always)
    private mutating func discoveryKey(in bytes: UnsafeBufferPointer<UInt8>, parentKey: Int) -> Key? {
        if case let .indexed(namespace, prefix)? = resolvedParent(for: parentKey), bytes.count >= prefix.count,
           prefix.withUnsafeBufferPointer({ prefix in
               memcmp(bytes.baseAddress!, prefix.baseAddress!, prefix.count) == 0
           }), !bytes.dropFirst(prefix.count).contains(UInt8(ascii: "/")) {
            guard namespace.usesParentKeys else { return nil }
            return Key(namespace: namespace.id,
                       name: String(decoding: bytes.dropFirst(prefix.count), as: UTF8.self))
        }
        // Unexpected entries and canonically equivalent parent spellings use
        // String's existing equality/hash semantics through the interner.
        let slash = bytes.lastIndex(of: UInt8(ascii: "/"))
        let nameStart = slash.map { bytes.index(after: $0) } ?? bytes.startIndex
        let parentPrefix = String(decoding: bytes[..<nameStart], as: UTF8.self)
        let namespace = namespace(for: parentPrefix)
        guard namespace.usesParentKeys else { return nil }
        return Key(namespace: namespace.id,
                   name: String(decoding: bytes[nameStart...], as: UTF8.self))
    }

    mutating func releaseDiscoveryState() {
        keys = []
        directoryNamespaces = [:]
        parents = [:]
    }

    func nodeIndex(
        nodes: [FileNodeRecord],
        progressInterval: Int,
        cancellationCheck: () throws -> Void,
        indexingProgress: (Int) -> Void
    ) throws -> [String: FileTreeNodeIndex] {
        try cancellationCheck()
        var indexedItems = 0
        func didIndexItem() throws {
            indexedItems += 1
            if indexedItems.isMultiple(of: 256) { try cancellationCheck() }
            if indexedItems.isMultiple(of: progressInterval) || indexedItems == nodes.count {
                indexingProgress(indexedItems)
            }
        }
        // ASCII namespaces retain the existing dictionary's keys and capacity.
        var index = try fullPathKeys.mapValues { scanKey in
            let nodeIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count - scanKey - 1))
            try didIndexItem()
            return nodeIndex
        }
        if !compactScanKeys.isEmpty {
            try cancellationCheck()
            index.reserveCapacity(nodes.count)
            for scanKey in compactScanKeys {
                let offset = nodes.count - scanKey - 1
                index[nodes[offset].id] = FileTreeNodeIndex(rawValue: UInt32(offset))
                try didIndexItem()
            }
        }
        try cancellationCheck()
        assert(index.count == nodes.count)
        return index
    }

    private mutating func namespace(for path: String) -> Namespace {
        if let existing = directoryNamespaces[path] { return existing }
        // Canonically ASCII prefixes (including the Kelvin sign) always keep
        // full-path keys, so earlier ASCII discoveries need no migration.
        let usesParentKeys = !path.utf8.allSatisfy({ $0 < 0x80 })
            && !path.precomposedStringWithCanonicalMapping.utf8.allSatisfy({ $0 < 0x80 })
        let namespace = Namespace(id: directoryNamespaces.count, usesParentKeys: usesParentKeys)
        directoryNamespaces[path] = namespace
        return namespace
    }
}
