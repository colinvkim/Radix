//
//  ScanExclusionMatcher.swift
//  Radix
//

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
    private let basenamePatterns: [CompiledPattern]
    private let pathPatterns: [CompiledPattern]
    private let hasActiveRule: Bool

    init(
        patterns: [String],
        rootURL: URL
    ) {
        self.init(
            patterns: patterns,
            rootPath: rootURL.standardizedFileURL.path
        )
    }

    init(
        patterns: [String],
        rootPath: String
    ) {
        let normalizedRootPath = Self.normalizedRootPath(rootPath)
        let compiledPatterns = Self.normalizedPatterns(patterns).compactMap(CompiledPattern.init(rawPattern:))
        self.rootPath = normalizedRootPath
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
        guard path != rootPath else { return "" }

        if rootPath == "/" {
            return path.hasPrefix("/") ? path.dropFirst() : path[...]
        }

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(rootPrefix) else { return nil }
        return path.dropFirst(rootPrefix.count)
    }
}

nonisolated private struct CompiledPattern: Sendable {
    let matchesBasename: Bool
    private let directoryOnly: Bool
    private let matchers: [PatternMatcher]
    private let directoryPrefixPatterns: [GlobPattern]

    init?(rawPattern: String) {
        var pattern = rawPattern
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly {
            pattern.removeLast()
        }

        guard !pattern.isEmpty else { return nil }

        let matchesBasename = !pattern.contains("/")
        self.matchesBasename = matchesBasename
        self.directoryOnly = directoryOnly

        if Self.containsGlobSyntax(pattern) {
            self.matchers = Self.globstarSlashVariants(for: pattern).map {
                PatternMatcher(pattern: $0, matchesPath: !matchesBasename)
            }

            if !matchesBasename, pattern.hasSuffix("/**") {
                let prefixPattern = String(pattern.dropLast(3))
                self.directoryPrefixPatterns = Self.globstarSlashVariants(for: prefixPattern).map {
                    GlobPattern(pattern: $0, matchesPath: true)
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

        if matchers.contains(where: { $0.matches(value) }) {
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

    init(pattern: String, matchesPath: Bool) {
        guard !matchesPath, !pattern.contains("?") else {
            self = .glob(GlobPattern(pattern: pattern, matchesPath: matchesPath))
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
            self = .glob(GlobPattern(pattern: pattern, matchesPath: matchesPath))
        }
    }

    func matches<Value: StringProtocol>(_ value: Value) -> Bool {
        switch self {
        case .exact(let pattern):
            return value.elementsEqual(pattern)
        case .prefix(let prefix):
            return value.hasPrefix(prefix)
        case .suffix(let suffix):
            return value.hasSuffix(suffix)
        case .contains(let substring):
            return value.range(of: substring) != nil
        case .glob(let pattern):
            return pattern.matches(value)
        }
    }
}

nonisolated private struct GlobPattern: Sendable {
    private enum Token: Sendable {
        case literal(Character)
        case anySingle(allowsSlash: Bool)
        case anyRun(allowsSlash: Bool)
    }

    private let tokens: [Token]

    init(pattern: String, matchesPath: Bool) {
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
            } else {
                tokens.append(.literal(character))
                index += 1
            }
        }

        self.tokens = tokens
    }

    func matches<Value: StringProtocol>(_ value: Value) -> Bool {
        let characters = Array(value)
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
