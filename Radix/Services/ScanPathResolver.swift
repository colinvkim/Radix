import Foundation

nonisolated struct ScanPathResolver: Sendable {
    struct CompletionMatch: Sendable {
        let componentIndex: Int
        let matchedCharacterCount: Int
    }

    private struct CompletionQuery {
        let path: String
        let components: [String]
        let listsChildren: Bool

        var prefix: String { listsChildren ? "" : components.last ?? "" }
        var parentPath: String { listsChildren ? path : "/" + components.dropLast().joined(separator: "/") }
    }

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
        guard limit > 0, let query = completionQuery(for: input) else { return [] }
        let path = query.path
        let listsChildren = query.listsChildren
        let rootPath = normalizedPath(treeStore.root.url.path)
        if (path.caseInsensitiveCompare(rootPath) != .orderedSame || !listsChildren),
           rootPath.range(of: path, options: [.anchored, .caseInsensitive]) != nil,
           isVisible(treeStore.root) {
            return [treeStore.root]
        }

        let prefix = query.prefix
        guard let parent = try node(at: query.parentPath, cancellationCheck: cancellationCheck),
              parent.isDirectory else { return [] }
        if listsChildren, limit == 1 { return [parent] }
        let childLimit = listsChildren ? limit - 1 : limit
        var matches: [FileNodeRecord] = []
        for child in try treeStore.children(of: parent.id, cancellationCheck: cancellationCheck) {
            try cancellationCheck()
            guard isVisible(child),
                  prefix.isEmpty || child.url.lastPathComponent.range(
                    of: prefix, options: [.anchored, .caseInsensitive]
                  ) != nil else { continue }
            let insertion = matches.firstIndex { precedes(child, $0, prefix: prefix) } ?? matches.endIndex
            if insertion < childLimit {
                matches.insert(child, at: insertion)
                if matches.count > childLimit { matches.removeLast() }
            }
        }
        return listsChildren ? [parent] + matches : matches
    }

    func completionMatch(for input: String, in node: FileNodeRecord) -> CompletionMatch? {
        guard let query = completionQuery(for: input), !query.prefix.isEmpty else { return nil }
        let componentIndex = query.components.count - 1
        let components = node.url.pathComponents.filter { $0 != "/" }
        guard componentIndex < components.count,
              let range = components[componentIndex].range(
                of: query.prefix, options: [.anchored, .caseInsensitive]
              ) else { return nil }
        return CompletionMatch(
            componentIndex: componentIndex,
            matchedCharacterCount: components[componentIndex][..<range.upperBound].count
        )
    }

    static func completionPath(for node: FileNodeRecord) -> String {
        let path = node.url.path
        return node.isDirectory && !path.hasSuffix("/") ? path + "/" : path
    }

    private func node(at path: String, cancellationCheck: () throws -> Void) throws -> FileNodeRecord? {
        try cancellationCheck()
        let rootComponents = normalizedPath(treeStore.root.url.path).split(separator: "/")
        let components = path.split(separator: "/")
        guard components.starts(with: rootComponents, by: {
            String($0).caseInsensitiveCompare(String($1)) == .orderedSame
        }), isVisible(treeStore.root) else { return nil }
        var current = treeStore.root
        for component in components.dropFirst(rootComponents.count) {
            guard current.isDirectory else { return nil }
            let requestedName = String(component)
            let children = try treeStore.children(of: current.id, cancellationCheck: cancellationCheck)
            var match: FileNodeRecord?
            var isAmbiguous = false
            for child in children {
                try cancellationCheck()
                guard isVisible(child) else { continue }
                let name = child.url.lastPathComponent
                if name == requestedName {
                    match = child
                    isAmbiguous = false
                    break
                }
                if name.caseInsensitiveCompare(requestedName) == .orderedSame {
                    if match != nil { isAmbiguous = true }
                    match = child
                }
            }
            guard let match, !isAmbiguous else { return nil }
            current = match
        }
        return current
    }

    private func isVisible(_ node: FileNodeRecord) -> Bool {
        !node.isSynthetic && !treeStore.isNodeOrDescendant(node.id, of: hiddenNodes)
    }

    private func completionQuery(for input: String) -> CompletionQuery? {
        guard let path = absolutePath(input) else { return nil }
        return CompletionQuery(
            path: path,
            components: path.split(separator: "/").map(String.init),
            listsChildren: input.hasSuffix("/") || input == "~"
                || input.split(separator: "/").last.map { $0 == "." || $0 == ".." } == true
        )
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

    private func precedes(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord, prefix: String) -> Bool {
        let lhsIsExact = lhs.url.lastPathComponent == prefix
        let rhsIsExact = rhs.url.lastPathComponent == prefix
        if lhsIsExact != rhsIsExact { return lhsIsExact }
        let order = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
        return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
    }
}
