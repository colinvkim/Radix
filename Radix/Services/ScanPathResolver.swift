import Foundation

nonisolated struct ScanPathResolver: Sendable {
    let treeStore: FileTreeStore
    let baseDirectoryID: FileNodeRecord.ID?
    private let hiddenNodes: PreparedFileTreeNodeSet

    init(
        treeStore: FileTreeStore,
        hiddenNodeIDs: Set<FileNodeRecord.ID> = [],
        baseDirectoryID: FileNodeRecord.ID? = nil
    ) {
        self.treeStore = treeStore
        self.baseDirectoryID = baseDirectoryID
        hiddenNodes = treeStore.preparedNodeSet(for: hiddenNodeIDs)
    }

    var initialPath: String {
        let base = treeStore.node(id: baseDirectoryID) ?? treeStore.root
        return base.url.path.hasSuffix("/") ? base.url.path : base.url.path + "/"
    }

    func resolve(
        _ input: String,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileNodeRecord? {
        guard let path = absolutePath(input),
              let node = try node(at: path, cancellationCheck: cancellationCheck),
              !input.hasSuffix("/") || node.isDirectory else { return nil }
        return node
    }

    func completions(
        for input: String,
        limit: Int = 8,
        cancellationCheck: () throws -> Void = {}
    ) throws -> [FileNodeRecord] {
        guard limit > 0, let path = absolutePath(input) else { return [] }
        let rootPath = normalizedPath(treeStore.root.url.path)
        if path != rootPath,
           rootPath.range(of: path, options: [.anchored, .caseInsensitive]) != nil,
           isVisible(treeStore.root) {
            return [treeStore.root]
        }

        let listsChildren = input.hasSuffix("/") || input == "~"
            || input.split(separator: "/").last.map { $0 == "." || $0 == ".." } == true
        let components = path.split(separator: "/").map(String.init)
        let prefix = listsChildren ? "" : components.last ?? ""
        let parentPath = listsChildren ? path : "/" + components.dropLast().joined(separator: "/")
        guard let parent = try node(at: parentPath, cancellationCheck: cancellationCheck),
              parent.isDirectory else { return [] }
        var matches: [FileNodeRecord] = []
        for child in try treeStore.children(of: parent.id, cancellationCheck: cancellationCheck) {
            try cancellationCheck()
            guard isVisible(child),
                  prefix.isEmpty || child.url.lastPathComponent.range(
                    of: prefix, options: [.anchored, .caseInsensitive]
                  ) != nil else { continue }
            let insertion = matches.firstIndex { precedes(child, $0) } ?? matches.endIndex
            if insertion < limit {
                matches.insert(child, at: insertion)
                if matches.count > limit { matches.removeLast() }
            }
        }
        return matches
    }

    static func completionPath(for node: FileNodeRecord) -> String {
        let path = node.url.path
        return node.isDirectory && !path.hasSuffix("/") ? path + "/" : path
    }

    private func node(at path: String, cancellationCheck: () throws -> Void) throws -> FileNodeRecord? {
        try cancellationCheck()
        let rootComponents = normalizedPath(treeStore.root.url.path).split(separator: "/")
        let components = path.split(separator: "/")
        guard components.starts(with: rootComponents), isVisible(treeStore.root) else { return nil }
        var current = treeStore.root
        for component in components.dropFirst(rootComponents.count) {
            guard current.isDirectory else { return nil }
            let children = try treeStore.children(of: current.id, cancellationCheck: cancellationCheck)
            var match: FileNodeRecord?
            for child in children {
                try cancellationCheck()
                if child.url.lastPathComponent == component, isVisible(child) {
                    match = child
                    break
                }
            }
            guard let match else { return nil }
            current = match
        }
        return current
    }

    private func isVisible(_ node: FileNodeRecord) -> Bool {
        !node.isSynthetic && !treeStore.isNodeOrDescendant(node.id, of: hiddenNodes)
    }

    private func absolutePath(_ input: String) -> String? {
        guard !input.isEmpty, !input.contains("\0") else { return nil }
        let expanded: String
        if input == "~" || input.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path + input.dropFirst()
        } else if input.hasPrefix("~") {
            return nil
        } else {
            expanded = input
        }
        let base = treeStore.node(id: baseDirectoryID) ?? treeStore.root
        return normalizedPath(expanded.hasPrefix("/") ? expanded : base.url.path + "/" + expanded)
    }

    private func normalizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func precedes(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> Bool {
        let order = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
        return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
    }
}
