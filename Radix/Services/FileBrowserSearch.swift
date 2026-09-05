//
//  FileBrowserSearch.swift
//  Radix
//

import Foundation

protocol FileSearching: Sendable {
    /// Returns matching tree records with at most one entry per node ID.
    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord]

    func pruneIndexes(keeping snapshotID: UUID?) async
}

extension FileSearching {
    func pruneIndexes(keeping snapshotID: UUID?) async {}
}

actor FileBrowserDisplayService {
    func currentContentsProjection(
        _ nodes: [FileNodeRecord],
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?,
        debounceDuration: Duration
    ) async throws -> FileBrowserDisplayProjection {
        try await Task.sleep(for: debounceDuration)
        let cancellationCheck: @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
        let visibleNodes = try FileBrowserResults.visibleNodes(
            nodes,
            hiddenNodeIDs: hiddenNodeIDs,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        let refreshedNodes = try FileBrowserResults.filteredAndSortedCurrentContents(
            visibleNodes,
            query: query,
            sortOrder: sortOrder,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        return try FileBrowserDisplayProjection(
            nodes: refreshedNodes,
            cancellationCheck: cancellationCheck
        )
    }

    func projection(
        _ nodes: [FileNodeRecord],
        hiddenNodeIDs: Set<FileNodeRecord.ID>,
        fileTreeStore: FileTreeStore?
    ) throws -> FileBrowserDisplayProjection {
        let cancellationCheck: @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
        let visibleNodes = try FileBrowserResults.visibleNodes(
            nodes,
            hiddenNodeIDs: hiddenNodeIDs,
            fileTreeStore: fileTreeStore,
            cancellationCheck: cancellationCheck
        )
        return try FileBrowserDisplayProjection(
            nodes: visibleNodes,
            cancellationCheck: cancellationCheck
        )
    }
}

actor FileSearchService: FileSearching {
    private var cachedIndex: CachedFileSearchIndex?

    func search(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        query: FileBrowserQuery,
        sortOrder: [FileNodeTableComparator]
    ) async throws -> [FileNodeRecord] {
        guard query.isActive else { return [] }
        try Task.checkCancellation()
        let matchedNodes = try matchingNodes(
            snapshotID: snapshotID,
            treeStore: treeStore,
            preparedQuery: query.prepared()
        )
        let sortedNodes = try FileBrowserResults.sorted(
            matchedNodes,
            sortOrder: sortOrder,
            fileTreeStore: treeStore,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
        try Task.checkCancellation()
        return sortedNodes
    }

    private func matchingNodes(
        snapshotID: UUID,
        treeStore: FileTreeStore,
        preparedQuery: PreparedFileBrowserQuery
    ) throws -> [FileNodeRecord] {
        let indexKey = FileSearchIndexKey(
            snapshotID: snapshotID,
            treeContentID: treeStore.contentID
        )
        if cachedIndex?.key != indexKey {
            cachedIndex = nil
        }
        var matchedNodes: [FileNodeRecord] = []
        matchedNodes.reserveCapacity(min(treeStore.nodeCount, 256))

        // Reuse a valid text index, but do not build one just to filter metadata.
        if !preparedQuery.hasText, cachedIndex == nil {
            for (offset, nodeIndex) in treeStore.indexedNodeIndices().enumerated() {
                if offset.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                // Match the text index's membership rules, including scoped roots.
                guard treeStore.parentIndex(of: nodeIndex) != nil,
                      let node = treeStore.node(at: nodeIndex) else { continue }
                if preparedQuery.matchesMetadata(
                    allocatedSize: node.allocatedSize,
                    itemKind: FileBrowserItemKindFilter.classification(for: node)
                ) {
                    matchedNodes.append(node)
                }
            }
            try Task.checkCancellation()
            return matchedNodes
        }

        if cachedIndex == nil {
            let index = try makeIndex(treeStore: treeStore)
            cachedIndex = CachedFileSearchIndex(
                key: indexKey,
                index: index
            )
        }
        guard let index = cachedIndex?.index else { return [] }
        let entries = index.entries
        let normalizedTextCount = preparedQuery.normalizedText.count

        let pathQuery = preparedQuery.includesPath
            ? ParentPathQuery(normalizedPathText: preparedQuery.normalizedPathText)
            : nil
        var parentQueryStates = pathQuery == nil
            ? []
            : Array(
                repeating: ParentPathMatchState.unresolved,
                count: index.parentGroups.count
            )
        var unresolvedParentOffsets: [Int] = []
        unresolvedParentOffsets.reserveCapacity(min(index.parentGroups.count, 64))

        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard preparedQuery.matchesMetadata(
                allocatedSize: entry.allocatedSize,
                itemKind: entry.itemKind
            ) else {
                continue
            }

            if !preparedQuery.hasText ||
                (entry.normalizedNameKindHaystack.count >= normalizedTextCount &&
                    entry.normalizedNameKindHaystack.contains(preparedQuery.normalizedText)) {
                if let node = treeStore.node(at: entry.nodeIndex) {
                    matchedNodes.append(node)
                }
                continue
            }

            guard let pathQuery,
                  entry.parentPathSlot != UInt32.max else {
                continue
            }

            let parentPathOffset = Int(entry.parentPathSlot)
            let parentQueryState: ParentPathMatchState
            if parentQueryStates[parentPathOffset].isResolved {
                parentQueryState = parentQueryStates[parentPathOffset]
            } else {
                parentQueryState = try index.parentPathMatchState(
                    at: parentPathOffset,
                    query: pathQuery,
                    states: &parentQueryStates,
                    unresolvedOffsets: &unresolvedParentOffsets,
                    treeStore: treeStore
                )
            }
            let matchesPath = pathQuery.containsWholePath(in: parentQueryState) ||
                (pathQuery.parentSuffixMatcher.isFullMatch(
                    state: parentQueryState.parentSuffixMatchLength
                ) &&
                    entry.normalizedPathComponent.hasPrefix(pathQuery.componentPrefix))
            if matchesPath, let node = treeStore.node(at: entry.nodeIndex) {
                matchedNodes.append(node)
            }
        }
        try Task.checkCancellation()
        return matchedNodes
    }

    func pruneIndexes(keeping snapshotID: UUID?) {
        guard let snapshotID else {
            cachedIndex = nil
            return
        }

        if cachedIndex?.key.snapshotID != snapshotID {
            cachedIndex = nil
        }
    }

    private func makeIndex(treeStore: FileTreeStore) throws -> FileSearchIndex {
        let indexedNodeIndices = treeStore.indexedNodeIndices()
        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(max(indexedNodeIndices.count - 1, 0))

        var parentGroups: [ParentGroupSource] = []
        var hasCanonicalPathByEntry: [Bool] = []
        hasCanonicalPathByEntry.reserveCapacity(max(indexedNodeIndices.count - 1, 0))
        // Full stores benefit from direct indexing; small logical scopes must not
        // allocate temporary storage proportional to their backing scan.
        let usesDenseParentSlots = treeStore.backingNodeCapacity <= max(
            indexedNodeIndices.count * 4,
            4_096
        )
        var denseParentPathSlots = usesDenseParentSlots
            ? Array(repeating: UInt32.max, count: treeStore.backingNodeCapacity)
            : []
        var sparseParentPathSlots: [FileTreeNodeIndex: UInt32] = [:]
        if !usesDenseParentSlots {
            sparseParentPathSlots.reserveCapacity(indexedNodeIndices.count)
        }
        var exceptionalParentPathSlots: [String: UInt32] = [:]

        for (offset, nodeIndex) in indexedNodeIndices.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard let parentIndex = treeStore.parentIndex(of: nodeIndex),
                  let node = treeStore.node(at: nodeIndex),
                  let parent = treeStore.node(at: parentIndex) else {
                continue
            }

            let nodePath = node.url.path
            let finalSeparator = nodePath.lastIndex(of: "/")
            let pathComponent: String
            let containingPath: Substring
            if let finalSeparator {
                let componentStart = nodePath.index(after: finalSeparator)
                let component = nodePath[componentStart...]
                pathComponent = component == node.name[...] ? node.name : String(component)
                containingPath = nodePath[..<finalSeparator]
            } else {
                pathComponent = nodePath == node.name ? node.name : nodePath
                containingPath = nodePath[nodePath.startIndex..<nodePath.startIndex]
            }

            let parentPathSlot: UInt32
            let expectedParentPath = childPathPrefix(for: parent.id)
            if finalSeparator == nil {
                parentPathSlot = UInt32.max
            } else if containingPath == expectedParentPath {
                let parentOffset = Int(parentIndex.rawValue)
                let existingSlot: UInt32? = if usesDenseParentSlots {
                    denseParentPathSlots[parentOffset] == UInt32.max
                        ? nil
                        : denseParentPathSlots[parentOffset]
                } else {
                    sparseParentPathSlots[parentIndex]
                }
                if let existingSlot {
                    parentPathSlot = existingSlot
                } else {
                    parentPathSlot = UInt32(parentGroups.count)
                    if usesDenseParentSlots {
                        denseParentPathSlots[parentOffset] = parentPathSlot
                    } else {
                        sparseParentPathSlots[parentIndex] = parentPathSlot
                    }
                    parentGroups.append(.nodeID(parentIndex))
                }
            } else if let existingSlot = exceptionalParentPathSlots[String(containingPath)] {
                parentPathSlot = existingSlot
            } else {
                // Search semantics are based on URL paths. Synthetic or imported
                // records may not follow the store's ID topology, so share their
                // exact containing path without collapsing separators.
                parentPathSlot = UInt32(parentGroups.count)
                exceptionalParentPathSlots[String(containingPath)] = parentPathSlot
                parentGroups.append(.containingDirectory(nodeIndex))
            }

            hasCanonicalPathByEntry.append(
                nodePath[...] == childPathPrefix(for: node.id)
            )
            entries.append(FileSearchEntry(
                nodeIndex: nodeIndex,
                parentPathSlot: parentPathSlot,
                normalizedPathComponent: SearchNormalizer.normalizePathComponent(pathComponent),
                normalizedNameKindHaystack: SearchNormalizer.normalizedNameKindHaystack(for: node),
                allocatedSize: node.allocatedSize,
                itemKind: FileBrowserItemKindFilter.classification(for: node)
            ))
        }

        for (entryOffset, entry) in entries.enumerated() {
            if entryOffset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard entry.parentPathSlot != UInt32.max,
                  hasCanonicalPathByEntry[entryOffset] else {
                continue
            }
            let parentSlot: UInt32?
            if usesDenseParentSlots {
                let slot = denseParentPathSlots[Int(entry.nodeIndex.rawValue)]
                parentSlot = slot == UInt32.max ? nil : slot
            } else {
                parentSlot = sparseParentPathSlots[entry.nodeIndex]
            }
            guard let parentSlot else { continue }
            parentGroups[Int(parentSlot)] = .entry(UInt32(entryOffset))
        }

        return FileSearchIndex(
            entries: entries,
            parentGroups: parentGroups
        )
    }
}

enum SearchNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated static func normalizePathComponent(_ value: String) -> String {
        if value.utf8.allSatisfy({ byte in
            byte < 0x80 && !(0x41...0x5A).contains(byte)
        }) {
            return value
        }
        return normalize(value)
    }

    nonisolated static func queryIncludesPath(_ query: String) -> Bool {
        query.contains("/") || query.contains("\\")
    }

    nonisolated static func nodeMatches(
        _ node: FileNodeRecord,
        normalizedQuery: String,
        normalizedPathQuery: String,
        includesPath: Bool
    ) -> Bool {
        if normalizedNameKindHaystack(for: node).contains(normalizedQuery) {
            return true
        }

        guard includesPath else { return false }
        return normalize(node.url.path).contains(normalizedPathQuery)
    }

    nonisolated static func normalizedNameKindHaystack(for node: FileNodeRecord) -> String {
        normalize([node.name, node.itemKind].joined(separator: "\n"))
    }
}

private nonisolated struct FileSearchIndex {
    let entries: [FileSearchEntry]
    let parentGroups: [ParentGroupSource]

    func parentPathMatchState(
        at offset: Int,
        query: ParentPathQuery,
        states: inout [ParentPathMatchState],
        unresolvedOffsets: inout [Int],
        treeStore: FileTreeStore
    ) throws -> ParentPathMatchState {
        if states[offset].isResolved {
            return states[offset]
        }

        unresolvedOffsets.removeAll(keepingCapacity: true)
        var currentOffset = offset
        var state = ParentPathMatchState.unresolved

        resolveBase: while true {
            if states[currentOffset].isResolved {
                state = states[currentOffset]
                break
            }

            switch parentGroups[currentOffset] {
            case .entry(let entryOffset):
                let entry = entries[Int(entryOffset)]
                guard entry.parentPathSlot != UInt32.max else {
                    state = query.matchState(for: "")
                    states[currentOffset] = state
                    break resolveBase
                }
                unresolvedOffsets.append(currentOffset)
                if unresolvedOffsets.count.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                currentOffset = Int(entry.parentPathSlot)
            case .nodeID(let nodeIndex):
                let path: String
                if let node = treeStore.node(at: nodeIndex) {
                    let prefix = childPathPrefix(for: node.id)
                    path = prefix.endIndex == node.id.endIndex
                        ? node.id
                        : String(prefix)
                } else {
                    path = ""
                }
                state = query.matchState(for: path)
                states[currentOffset] = state
                break resolveBase
            case .containingDirectory(let nodeIndex):
                let path: String
                if let sourcePath = treeStore.node(at: nodeIndex)?.url.path,
                   let finalSeparator = sourcePath.lastIndex(of: "/") {
                    path = String(sourcePath[..<finalSeparator])
                } else {
                    path = ""
                }
                state = query.matchState(for: path)
                states[currentOffset] = state
                break resolveBase
            }
        }

        for unresolvedOffset in unresolvedOffsets.reversed() {
            guard case .entry(let entryOffset) = parentGroups[unresolvedOffset] else {
                continue
            }
            state = query.advancing(
                state,
                component: entries[Int(entryOffset)].normalizedPathComponent
            )
            states[unresolvedOffset] = state
        }
        return state
    }
}

private nonisolated func childPathPrefix(for directoryPath: String) -> Substring {
    directoryPath.hasSuffix("/") ? directoryPath.dropLast() : directoryPath[...]
}

private nonisolated enum ParentGroupSource {
    case entry(UInt32)
    case nodeID(FileTreeNodeIndex)
    case containingDirectory(FileTreeNodeIndex)
}

private nonisolated struct ParentPathQuery {
    let wholePathMatcher: PathSubstringMatcher
    let parentSuffixMatcher: PathSubstringMatcher
    let componentPrefix: String

    init?(normalizedPathText: String) {
        guard let finalSlash = normalizedPathText.lastIndex(of: "/") else { return nil }
        // A child path match is either already present in its parent path or
        // crosses the final parent/component separator.
        wholePathMatcher = PathSubstringMatcher(normalizedPathText)
        parentSuffixMatcher = PathSubstringMatcher(String(normalizedPathText[..<finalSlash]))
        componentPrefix = String(normalizedPathText[normalizedPathText.index(after: finalSlash)...])
    }

    func matchState(for path: String) -> ParentPathMatchState {
        var state = ParentPathMatchState.initial
        let normalizedPath = SearchNormalizer.normalizePathComponent(path)
        for character in normalizedPath {
            advance(&state, with: character)
            if containsWholePath(in: state) { break }
        }
        return state
    }

    func advancing(
        _ state: ParentPathMatchState,
        component: String
    ) -> ParentPathMatchState {
        guard !containsWholePath(in: state) else { return state }
        var result = state
        advance(&result, with: "/")
        if containsWholePath(in: result) { return result }
        for character in component {
            advance(&result, with: character)
            if containsWholePath(in: result) { break }
        }
        return result
    }

    func containsWholePath(in state: ParentPathMatchState) -> Bool {
        wholePathMatcher.isFullMatch(state: state.wholePathMatchLength)
    }

    private func advance(
        _ state: inout ParentPathMatchState,
        with character: Character
    ) {
        if wholePathMatcher.advance(
            state: &state.wholePathMatchLength,
            with: character
        ) {
            return
        }
        _ = parentSuffixMatcher.advance(
            state: &state.parentSuffixMatchLength,
            with: character
        )
    }
}

private nonisolated struct ParentPathMatchState {
    var wholePathMatchLength: Int
    var parentSuffixMatchLength: Int

    static let unresolved = Self(
        wholePathMatchLength: -1,
        parentSuffixMatchLength: 0
    )
    static let initial = Self(
        wholePathMatchLength: 0,
        parentSuffixMatchLength: 0
    )

    var isResolved: Bool {
        wholePathMatchLength >= 0
    }
}

private nonisolated struct PathSubstringMatcher {
    private let pattern: [Character]
    private let failureLengths: [Int]

    init(_ pattern: String) {
        self.pattern = Array(pattern)
        guard self.pattern.count > 1 else {
            failureLengths = Array(repeating: 0, count: self.pattern.count)
            return
        }

        // KMP state is small enough to inherit through the directory topology;
        // no full parent paths need to be constructed or retained.
        var failureLengths = Array(repeating: 0, count: self.pattern.count)
        var prefixLength = 0
        for offset in 1..<self.pattern.count {
            while prefixLength > 0,
                  self.pattern[prefixLength] != self.pattern[offset] {
                prefixLength = failureLengths[prefixLength - 1]
            }
            if self.pattern[prefixLength] == self.pattern[offset] {
                prefixLength += 1
            }
            failureLengths[offset] = prefixLength
        }
        self.failureLengths = failureLengths
    }

    func advance(state: inout Int, with character: Character) -> Bool {
        guard !pattern.isEmpty else { return false }
        while state > 0,
              (state == pattern.count || pattern[state] != character) {
            state = failureLengths[state - 1]
        }
        if pattern[state] == character {
            state += 1
        }
        return state == pattern.count
    }

    func isFullMatch(state: Int) -> Bool {
        pattern.isEmpty || state == pattern.count
    }
}

private struct CachedFileSearchIndex {
    let key: FileSearchIndexKey
    let index: FileSearchIndex
}

private nonisolated struct FileSearchIndexKey: Hashable, Sendable {
    let snapshotID: UUID
    let treeContentID: UUID
}

private struct FileSearchEntry {
    let nodeIndex: FileTreeNodeIndex
    let parentPathSlot: UInt32
    let normalizedPathComponent: String
    let normalizedNameKindHaystack: String
    let allocatedSize: Int64
    let itemKind: FileBrowserItemKindFilter?
}
