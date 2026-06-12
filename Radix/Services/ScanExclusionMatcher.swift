//
//  ScanExclusionMatcher.swift
//  Radix
//

import Foundation

nonisolated struct ScanExclusionMatcher {
    static let commonPresetPatterns = [
        "node_modules/",
        "*.log",
        ".DS_Store",
        "build/",
        "DerivedData/"
    ]

    private let rootPath: String
    private let patterns: [CompiledPattern]

    init(patterns: [String], rootURL: URL) {
        self.init(patterns: patterns, rootPath: rootURL.standardizedFileURL.path)
    }

    init(patterns: [String], rootPath: String) {
        self.rootPath = Self.normalizedRootPath(rootPath)
        self.patterns = Self.normalizedPatterns(patterns).compactMap(CompiledPattern.init(rawPattern:))
    }

    var isEmpty: Bool {
        patterns.isEmpty
    }

    func excludes(_ url: URL, isDirectory: Bool) -> Bool {
        guard !patterns.isEmpty,
              let relativePath = relativePath(for: url),
              !relativePath.isEmpty else {
            return false
        }

        let basename = url.lastPathComponent
        return patterns.contains { pattern in
            pattern.matches(
                basename: basename,
                relativePath: relativePath,
                isDirectory: isDirectory
            )
        }
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

    private func relativePath(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }

        if rootPath == "/" {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }
}

nonisolated private struct CompiledPattern {
    private let matchesBasename: Bool
    private let directoryOnly: Bool
    private let exactPattern: String?
    private let globPatterns: [GlobPattern]
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
            self.exactPattern = nil
            self.globPatterns = Self.globstarSlashVariants(for: pattern).map {
                GlobPattern(pattern: $0, matchesPath: !matchesBasename)
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
            self.exactPattern = pattern
            self.globPatterns = []
            self.directoryPrefixPatterns = []
        }
    }

    func matches(basename: String, relativePath: String, isDirectory: Bool) -> Bool {
        guard !directoryOnly || isDirectory else { return false }

        let value = matchesBasename ? basename : relativePath
        if let exactPattern {
            return value == exactPattern
        }

        if globPatterns.contains(where: { $0.matches(value) }) {
            return true
        }

        return isDirectory && directoryPrefixPatterns.contains { $0.matches(relativePath) }
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

nonisolated private struct GlobPattern {
    private enum Token {
        case literal(Character)
        case anySingle(allowsSlash: Bool)
        case anyRun(allowsSlash: Bool)
    }

    private struct MemoKey: Hashable {
        let tokenIndex: Int
        let valueIndex: Int
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

    func matches(_ value: String) -> Bool {
        let characters = Array(value)
        var memo: [MemoKey: Bool] = [:]

        func match(tokenIndex: Int, valueIndex: Int) -> Bool {
            let key = MemoKey(tokenIndex: tokenIndex, valueIndex: valueIndex)
            if let cached = memo[key] {
                return cached
            }

            let result: Bool
            if tokenIndex == tokens.count {
                result = valueIndex == characters.count
            } else {
                switch tokens[tokenIndex] {
                case .literal(let character):
                    result = valueIndex < characters.count &&
                        characters[valueIndex] == character &&
                        match(tokenIndex: tokenIndex + 1, valueIndex: valueIndex + 1)
                case .anySingle(let allowsSlash):
                    result = valueIndex < characters.count &&
                        (allowsSlash || characters[valueIndex] != "/") &&
                        match(tokenIndex: tokenIndex + 1, valueIndex: valueIndex + 1)
                case .anyRun(let allowsSlash):
                    if match(tokenIndex: tokenIndex + 1, valueIndex: valueIndex) {
                        result = true
                    } else if valueIndex < characters.count &&
                                (allowsSlash || characters[valueIndex] != "/") {
                        result = match(tokenIndex: tokenIndex, valueIndex: valueIndex + 1)
                    } else {
                        result = false
                    }
                }
            }

            memo[key] = result
            return result
        }

        return match(tokenIndex: 0, valueIndex: 0)
    }
}
