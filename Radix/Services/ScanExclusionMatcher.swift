import Foundation

nonisolated struct ScanExclusionMatcher: Sendable {
    static let commonPresetPatterns = [
        "node_modules/",
        "*.log",
        ".DS_Store",
        "build/",
        "DerivedData/"
    ]

    private let rootPath: String
    private let isCaseSensitive: Bool
    private let basenamePatterns: [CompiledPattern]
    private let pathPatterns: [CompiledPattern]
    private let hasActiveRule: Bool

    init(
        patterns: [String],
        rootURL: URL,
        volumeSupportsCaseSensitiveNames: Bool? = nil
    ) {
        self.init(
            patterns: patterns,
            rootPath: rootURL.standardizedFileURL.path,
            volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
        )
    }

    init(
        patterns: [String],
        rootPath: String,
        volumeSupportsCaseSensitiveNames: Bool? = nil
    ) {
        let normalizedRootPath = Self.normalizedRootPath(rootPath)
        let normalizedPatterns = Self.normalizedPatterns(patterns)
        let isCaseSensitive = normalizedPatterns.isEmpty ? true : volumeSupportsCaseSensitiveNames
            ?? (try? URL(fileURLWithPath: normalizedRootPath, isDirectory: true)
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames)
            ?? true
        let compiledPatterns = normalizedPatterns.compactMap {
            CompiledPattern(rawPattern: $0, isCaseSensitive: isCaseSensitive)
        }
        self.rootPath = normalizedRootPath
        self.isCaseSensitive = isCaseSensitive
        self.basenamePatterns = compiledPatterns.filter(\.matchesBasename)
        self.pathPatterns = compiledPatterns.filter { !$0.matchesBasename }
        self.hasActiveRule = !compiledPatterns.isEmpty
    }

    var isEmpty: Bool {
        !hasActiveRule
    }

    /// Scan enumeration constructs child URLs from an already-normalized parent
    /// and a single filesystem entry name. Preserve that scan namespace:
    /// Foundation file-URL standardization can rewrite `/private/var` to `/var`
    /// and cause root-relative exclusion rules to stop matching.
    func excludesKnownNormalizedPath(_ path: String, isDirectory: Bool) -> Bool {
        guard hasActiveRule else { return false }
        return excludes(normalizedPath: path, isDirectory: isDirectory)
    }

    /// Matches a validated child name without constructing its full path when
    /// all active rules are basename-only.
    func excludesKnownNormalizedChild(
        named childName: String,
        under parentPath: String,
        isDirectory: Bool
    ) -> Bool {
        guard hasActiveRule else { return false }
        if excludesBasename(childName, isDirectory: isDirectory) {
            return true
        }
        guard !pathPatterns.isEmpty else {
            return false
        }
        let childPath = parentPath == "/"
            ? parentPath + childName
            : parentPath + "/" + childName
        return excludesPathRules(normalizedPath: childPath, isDirectory: isDirectory)
    }

    private func excludes(normalizedPath: String, isDirectory: Bool) -> Bool {
        let basename = Self.basename(fromNormalizedPath: normalizedPath)
        if excludesBasename(basename, isDirectory: isDirectory) {
            return true
        }
        return excludesPathRules(normalizedPath: normalizedPath, isDirectory: isDirectory)
    }

    private func excludesBasename<Value: StringProtocol>(
        _ basename: Value,
        isDirectory: Bool
    ) -> Bool {
        basenamePatterns.contains {
            $0.matches(value: basename, isDirectory: isDirectory)
        }
    }

    private func excludesPathRules(normalizedPath: String, isDirectory: Bool) -> Bool {
        guard !pathPatterns.isEmpty,
              let relativePath = relativePath(forNormalizedPath: normalizedPath),
              !relativePath.isEmpty else {
            return false
        }

        return pathPatterns.contains { $0.matches(value: relativePath, isDirectory: isDirectory) }
    }

    static func normalizedPatterns(_ patterns: [String]) -> [String] {
        var normalizedPatterns: [String] = []
        var seenPatterns = Set<String>()

        for pattern in patterns {
            guard let normalizedPattern = normalizedPattern(pattern),
                  seenPatterns.insert(normalizedPattern).inserted else {
                continue
            }
            normalizedPatterns.append(normalizedPattern)
        }

        return normalizedPatterns
    }

    static func patternsRequirePathScopedRoot(_ patterns: [String]) -> Bool {
        normalizedPatterns(patterns).contains { pattern in
            pathMatchPortion(of: pattern).contains("/")
        }
    }

    static func normalizedRootPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func pathMatchPortion(of pattern: String) -> String {
        pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
    }

    private static func basename(fromNormalizedPath path: String) -> Substring {
        let endIndex = path.count > 1 && path.hasSuffix("/")
            ? path.index(before: path.endIndex)
            : path.endIndex
        guard let separatorIndex = path[..<endIndex].lastIndex(of: "/") else {
            return path[..<endIndex]
        }

        let basenameStartIndex = path.index(after: separatorIndex)
        return path[basenameStartIndex..<endIndex]
    }

    private static func normalizedPattern(_ pattern: String) -> String? {
        var normalized = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }

        var isDirectoryOnly = false
        while normalized.hasSuffix("/") {
            isDirectoryOnly = true
            normalized.removeLast()
        }

        guard !normalized.isEmpty else { return nil }
        return isDirectoryOnly ? "\(normalized)/" : normalized
    }

    private func relativePath(forNormalizedPath path: String) -> Substring? {
        if isCaseSensitive {
            guard path != rootPath else { return "" }
        } else if path.compare(rootPath, options: .caseInsensitive) == .orderedSame {
            return ""
        }

        if rootPath == "/" {
            return path.hasPrefix("/") ? path.dropFirst() : path[...]
        }

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        if isCaseSensitive {
            guard path.hasPrefix(rootPrefix) else { return nil }
            return path.dropFirst(rootPrefix.count)
        }
        guard let range = path.range(of: rootPrefix, options: [.caseInsensitive, .anchored]) else {
            return nil
        }
        return path[range.upperBound...]
    }
}

nonisolated private struct CompiledPattern: Sendable {
    let matchesBasename: Bool
    private let directoryOnly: Bool
    private let isCaseSensitive: Bool
    private let matchers: [PatternMatcher]
    private let directoryPrefixPatterns: [GlobPattern]

    init?(rawPattern: String, isCaseSensitive: Bool) {
        var pattern = rawPattern
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly {
            pattern.removeLast()
        }

        guard !pattern.isEmpty else { return nil }

        let matchesBasename = !pattern.contains("/")
        self.matchesBasename = matchesBasename
        self.directoryOnly = directoryOnly
        self.isCaseSensitive = isCaseSensitive

        if Self.containsGlobSyntax(pattern) {
            self.matchers = Self.globstarSlashVariants(for: pattern).map {
                PatternMatcher(pattern: $0, matchesPath: !matchesBasename, isCaseSensitive: isCaseSensitive)
            }

            if !matchesBasename, pattern.hasSuffix("/**") {
                let prefixPattern = String(pattern.dropLast(3))
                self.directoryPrefixPatterns = Self.globstarSlashVariants(for: prefixPattern).map {
                    GlobPattern(pattern: $0, matchesPath: true, isCaseSensitive: isCaseSensitive)
                }
            } else {
                self.directoryPrefixPatterns = []
            }
        } else {
            self.matchers = [.exact(pattern)]
            self.directoryPrefixPatterns = []
        }
    }

    func matches<Value: StringProtocol>(value: Value, isDirectory: Bool) -> Bool {
        guard !directoryOnly || isDirectory else { return false }

        if matchers.contains(where: { $0.matches(value, isCaseSensitive: isCaseSensitive) }) {
            return true
        }

        return isDirectory && directoryPrefixPatterns.contains { $0.matches(value) }
    }

    private static func containsGlobSyntax(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    private static func globstarSlashVariants(for pattern: String) -> [String] {
        var variants: Set<String> = [pattern]
        var addedVariant = true

        while addedVariant {
            addedVariant = false

            for variant in Array(variants) {
                var additions = Set<String>()

                if variant.hasPrefix("**/") {
                    additions.insert(String(variant.dropFirst(3)))
                }

                var searchStart = variant.startIndex
                while let range = variant.range(of: "/**/", range: searchStart..<variant.endIndex) {
                    var collapsed = variant
                    collapsed.replaceSubrange(range, with: "/")
                    additions.insert(collapsed)
                    searchStart = range.upperBound
                }

                for addition in additions where variants.insert(addition).inserted {
                    addedVariant = true
                }
            }
        }

        return variants.sorted()
    }
}

/// Common basename patterns stay in String's optimized native search
/// operations. The general glob engine remains the compatibility path for
/// multi-wildcard, single-character, and path-scoped patterns.
nonisolated private enum PatternMatcher: Sendable {
    case exact(String)
    case prefix(String)
    case suffix(String)
    case contains(String)
    case glob(GlobPattern)

    init(pattern: String, matchesPath: Bool, isCaseSensitive: Bool) {
        guard !matchesPath, !pattern.contains("?") else {
            self = .glob(GlobPattern(pattern: pattern, matchesPath: matchesPath, isCaseSensitive: isCaseSensitive))
            return
        }

        let starCount = pattern.reduce(into: 0) { count, character in
            if character == "*" {
                count += 1
            }
        }

        if starCount == 1, pattern.first == "*" {
            self = .suffix(String(pattern.dropFirst()))
        } else if starCount == 1, pattern.last == "*" {
            self = .prefix(String(pattern.dropLast()))
        } else if starCount == 2, pattern.first == "*", pattern.last == "*" {
            self = .contains(String(pattern.dropFirst().dropLast()))
        } else {
            self = .glob(GlobPattern(pattern: pattern, matchesPath: matchesPath, isCaseSensitive: isCaseSensitive))
        }
    }

    func matches<Value: StringProtocol>(_ value: Value, isCaseSensitive: Bool) -> Bool {
        switch self {
        case .exact(let pattern):
            return isCaseSensitive
                ? value.elementsEqual(pattern)
                : value.compare(pattern, options: .caseInsensitive) == .orderedSame
        case .prefix(let prefix):
            return isCaseSensitive
                ? value.hasPrefix(prefix)
                : value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        case .suffix(let suffix):
            return isCaseSensitive
                ? value.hasSuffix(suffix)
                : value.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case .contains(let substring):
            return value.range(of: substring, options: isCaseSensitive ? [] : .caseInsensitive) != nil
        case .glob(let pattern):
            return pattern.matches(value)
        }
    }
}

nonisolated private struct GlobPattern: Sendable {
    private enum Token: Sendable {
        case literal(Character)
        case literalRun(String)
        case anySingle(allowsSlash: Bool)
        case anyRun(allowsSlash: Bool)
    }

    private let tokens: [Token]
    private let isCaseSensitive: Bool

    init(pattern: String, matchesPath: Bool, isCaseSensitive: Bool) {
        let characters = Array(pattern)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                if matchesPath,
                   index + 1 < characters.count,
                   characters[index + 1] == "*" {
                    tokens.append(.anyRun(allowsSlash: true))
                    index += 2
                } else {
                    tokens.append(.anyRun(allowsSlash: !matchesPath))
                    index += 1
                }
            } else if character == "?" {
                tokens.append(.anySingle(allowsSlash: !matchesPath))
                index += 1
            } else if isCaseSensitive {
                tokens.append(.literal(character))
                index += 1
            } else {
                // Literal case folds can expand while wildcards still consume original characters.
                let start = index
                while index < characters.count, characters[index] != "*", characters[index] != "?" {
                    index += 1
                }
                tokens.append(.literalRun(String(characters[start..<index])))
            }
        }

        self.tokens = tokens
        self.isCaseSensitive = isCaseSensitive
    }

    func matches<Value: StringProtocol>(_ value: Value) -> Bool {
        let characters = Array(value)
        let boundaries = isCaseSensitive ? [] : Array(value.indices) + [value.endIndex]
        let boundaryOffsets = Dictionary(uniqueKeysWithValues: boundaries.enumerated().map { ($0.element, $0.offset) })
        var previous = Array(repeating: false, count: characters.count + 1)
        var current = previous
        previous[0] = true

        for token in tokens {
            for index in current.indices {
                current[index] = false
            }
            switch token {
            case .literal(let literal):
                for valueIndex in characters.indices where previous[valueIndex] {
                    current[valueIndex + 1] = characters[valueIndex] == literal
                }
            case .literalRun(let literal):
                for valueIndex in characters.indices where previous[valueIndex] {
                    guard let range = value.range(
                        of: literal,
                        options: [.caseInsensitive, .anchored],
                        range: boundaries[valueIndex]..<value.endIndex
                    ), let endOffset = boundaryOffsets[range.upperBound] else {
                        continue
                    }
                    current[endOffset] = true
                }
            case .anySingle(let allowsSlash):
                for valueIndex in characters.indices where previous[valueIndex] {
                    current[valueIndex + 1] = allowsSlash || characters[valueIndex] != "/"
                }
            case .anyRun(let allowsSlash):
                current[0] = previous[0]
                for valueIndex in characters.indices {
                    current[valueIndex + 1] = previous[valueIndex + 1]
                        || (current[valueIndex]
                            && (allowsSlash || characters[valueIndex] != "/"))
                }
            }
            swap(&previous, &current)
        }

        return previous[characters.count]
    }
}
