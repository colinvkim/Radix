import Foundation

struct FileBrowserDisplayRequest: Sendable {
    let generation: Int
    let displayContext: FileBrowserDisplayContext
}

struct FileBrowserDisplayContext: Equatable, Sendable {
    let contentID: String
    let contentRevision: Int
    let snapshotID: UUID?
    let searchScope: FileBrowserFindTarget
    let query: FileBrowserQuery
    let sortOrder: [FileNodeTableComparator]
    let hiddenNodeIDs: Set<FileNodeRecord.ID>

    static let empty = FileBrowserDisplayContext(
        contentID: "",
        contentRevision: 0,
        snapshotID: nil,
        searchScope: .currentContents,
        query: FileBrowserQuery(),
        sortOrder: [],
        hiddenNodeIDs: []
    )
}

nonisolated struct FileBrowserDisplayProjection: Sendable {
    let nodes: [FileNodeRecord]
    let indexesByNodeID: [FileNodeRecord.ID: Int]

    init(nodes: [FileNodeRecord]) {
        self.init(nodes: nodes, cancellationCheck: {})
    }

    init(
        nodes: [FileNodeRecord],
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows {
        var indexesByNodeID: [FileNodeRecord.ID: Int] = [:]
        indexesByNodeID.reserveCapacity(nodes.count)

        for (index, node) in nodes.enumerated() {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let previousIndex = indexesByNodeID.updateValue(index, forKey: node.id)
            assert(
                previousIndex == nil,
                "File Browser results contain duplicate node IDs"
            )
        }
        try cancellationCheck()

        self.nodes = nodes
        self.indexesByNodeID = indexesByNodeID
    }
}

struct FileBrowserDisplayState {
    var nodes: [FileNodeRecord]
    var context: FileBrowserDisplayContext
    var indexesByNodeID: [FileNodeRecord.ID: Int]
    var displayValueCache: FileBrowserDisplayValueCache

    init(
        nodes: [FileNodeRecord] = [],
        context: FileBrowserDisplayContext = .empty
    ) {
        self.init(
            projection: FileBrowserDisplayProjection(nodes: nodes),
            context: context
        )
    }

    init(
        projection: FileBrowserDisplayProjection,
        context: FileBrowserDisplayContext
    ) {
        self.nodes = projection.nodes
        self.context = context
        self.indexesByNodeID = projection.indexesByNodeID
        self.displayValueCache = FileBrowserDisplayValueCache()
    }

    func node(id: FileNodeRecord.ID) -> FileNodeRecord? {
        guard let index = indexesByNodeID[id],
              nodes.indices.contains(index) else {
            return nil
        }
        return nodes[index]
    }

    func nodes(ids: Set<FileNodeRecord.ID>) -> [FileNodeRecord] {
        var indexes = ids.compactMap { indexesByNodeID[$0] }
        indexes.sort()
        return indexes.map { nodes[$0] }
    }

    func displayValues(
        for node: FileNodeRecord,
        hidesPackageContents: Bool = false
    ) -> FileBrowserNodeDisplayValues {
        let cacheKey = FileBrowserDisplayValueCacheKey(
            nodeID: node.id,
            hidesPackageContents: hidesPackageContents
        )
        if let cachedValues = displayValueCache.valuesByKey[cacheKey] {
            return cachedValues
        }

        let values = FileBrowserNodeDisplayValues(
            node: node,
            hidesPackageContents: hidesPackageContents
        )
        displayValueCache.valuesByKey[cacheKey] = values
        return values
    }
}

final class FileBrowserDisplayValueCache {
    var valuesByKey: [FileBrowserDisplayValueCacheKey: FileBrowserNodeDisplayValues] = [:]
}

struct FileBrowserDisplayValueCacheKey: Hashable {
    let nodeID: FileNodeRecord.ID
    let hidesPackageContents: Bool
}

enum FileBrowserPackageContents {
    nonisolated static func areHidden(
        for node: FileNodeRecord,
        fileTreeStore: FileTreeStore?
    ) -> Bool {
        node.isPackage &&
            node.isDirectory &&
            !node.isAutoSummarized &&
            (node.descendantFileCount > 0 || node.allocatedSize > 0 || node.logicalSize > 0) &&
            fileTreeStore?.containsChildren(id: node.id) != true
    }
}

struct FileBrowserNodeDisplayValues: Equatable, Sendable {
    let allocatedSize: String
    let descendantCount: String
    let modifiedDate: String

    init(node: FileNodeRecord, hidesPackageContents: Bool = false) {
        allocatedSize = RadixFormatters.size(node.allocatedSize)
        descendantCount = Self.descendantCountText(
            for: node,
            hidesPackageContents: hidesPackageContents
        )
        modifiedDate = RadixFormatters.date(node.lastModified)
    }

    private static func descendantCountText(
        for node: FileNodeRecord,
        hidesPackageContents: Bool
    ) -> String {
        if hidesPackageContents && node.isPackage {
            return "—"
        }
        if node.isDirectory {
            return "\(node.descendantFileCount)"
        }
        if node.isSynthetic || node.isSymbolicLink {
            return "—"
        }
        return "1"
    }
}
