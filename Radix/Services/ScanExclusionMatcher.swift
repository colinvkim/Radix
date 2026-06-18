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
    private let patterns: [CompiledPattern]
    private let cloudLocations: [CloudLocation]

    init(
        patterns: [String],
        rootURL: URL,
        includeCloudStorage: Bool,
        cloudStorageRootPath: String = ScanOptions.defaultCloudStorageRootPath,
        iCloudDriveRootPath: String = ScanOptions.defaultICloudDriveRootPath
    ) {
        self.init(
            patterns: patterns,
            rootPath: rootURL.standardizedFileURL.path,
            includeCloudStorage: includeCloudStorage,
            cloudStorageRootPath: cloudStorageRootPath,
            iCloudDriveRootPath: iCloudDriveRootPath
        )
    }

    init(
        patterns: [String],
        rootPath: String,
        includeCloudStorage: Bool,
        cloudStorageRootPath: String = ScanOptions.defaultCloudStorageRootPath,
        iCloudDriveRootPath: String = ScanOptions.defaultICloudDriveRootPath
    ) {
        let normalizedRootPath = Self.normalizedRootPath(rootPath)
        self.rootPath = normalizedRootPath
        self.patterns = Self.normalizedPatterns(patterns).compactMap(CompiledPattern.init(rawPattern:))
        self.cloudLocations = [
            Self.cloudLocation(
                configuredRootPath: cloudStorageRootPath,
                userRelativeComponents: ["Library", "CloudStorage"],
                scanRootPath: normalizedRootPath,
                includeCloudStorage: includeCloudStorage
            ),
            Self.cloudLocation(
                configuredRootPath: iCloudDriveRootPath,
                userRelativeComponents: ["Library", "Mobile Documents"],
                scanRootPath: normalizedRootPath,
                includeCloudStorage: includeCloudStorage
            )
        ]
    }

    var isEmpty: Bool {
        patterns.isEmpty && !cloudLocations.contains { $0.isActive }
    }

    var hasUserExclusions: Bool {
        !patterns.isEmpty
    }

    func excludes(_ url: URL, isDirectory: Bool) -> Bool {
        let normalizedPath = url.standardizedFileURL.path
        return excludes(normalizedPath: normalizedPath, isDirectory: isDirectory)
    }

    private func excludes(normalizedPath: String, isDirectory: Bool) -> Bool {
        if excludesCloudStorage(path: normalizedPath) {
            return true
        }

        guard !patterns.isEmpty,
              let relativePath = relativePath(forNormalizedPath: normalizedPath),
              !relativePath.isEmpty else {
            return false
        }

        let basename = Self.basename(fromNormalizedPath: normalizedPath)
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

    private func excludesCloudStorage(path: String) -> Bool {
        guard path != rootPath else { return false }
        return cloudLocations.contains { $0.excludes(path: path) }
    }

    private static func cloudLocation(
        configuredRootPath: String,
        userRelativeComponents: [String],
        scanRootPath: String,
        includeCloudStorage: Bool
    ) -> CloudLocation {
        let normalizedConfiguredRootPath = normalizedRootPath(configuredRootPath)
        let explicitlyScanning = path(
            scanRootPath,
            isEqualToOrDescendantOf: normalizedConfiguredRootPath
        ) || isUsersCloudPath(scanRootPath, userRelativeComponents: userRelativeComponents)
        let currentLocationCanMatch = pathsOverlap(scanRootPath, normalizedConfiguredRootPath)
        let excludedRootPath = includeCloudStorage
            || explicitlyScanning
            || !currentLocationCanMatch
            ? nil
            : normalizedConfiguredRootPath
        let excludesAnyUser = !includeCloudStorage
            && !explicitlyScanning
            && usersCloudRuleCanMatchDescendant(
                of: scanRootPath,
                userRelativeComponents: userRelativeComponents
            )
        return CloudLocation(
            excludedRootPath: excludedRootPath,
            excludesAnyUser: excludesAnyUser,
            userRelativeComponents: userRelativeComponents
        )
    }

    private static func usersCloudRuleCanMatchDescendant(
        of rootPath: String,
        userRelativeComponents: [String]
    ) -> Bool {
        if rootPath == "/" || rootPath == "/Users" {
            return true
        }

        let components = pathComponents(rootPath)
        guard components.first == "Users" else { return false }

        // Full cloud path is /Users/<user>/<userRelativeComponents...>.
        let fullCount = 2 + userRelativeComponents.count
        if components.count < fullCount {
            // Scan root is an ancestor of the cloud path; the components it does
            // pin down must still match the cloud path's prefix.
            for index in 2..<components.count where components[index] != userRelativeComponents[index - 2] {
                return false
            }
            return true
        }

        // Scan root is at or below the cloud path's depth; it can only contain a
        // descendant of the rule when the root itself is the cloud path.
        return isUsersCloudPath(rootPath, userRelativeComponents: userRelativeComponents)
    }

    fileprivate static func isUsersCloudPath(
        _ path: String,
        userRelativeComponents: [String]
    ) -> Bool {
        let components = pathComponents(path)
        guard components.count >= 2 + userRelativeComponents.count else { return false }
        guard components[0] == "Users" else { return false }
        for (offset, expected) in userRelativeComponents.enumerated()
        where components[2 + offset] != expected {
            return false
        }
        return true
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func pathsOverlap(_ firstPath: String, _ secondPath: String) -> Bool {
        path(firstPath, isEqualToOrDescendantOf: secondPath)
            || path(secondPath, isEqualToOrDescendantOf: firstPath)
    }

    private static func path(_ path: String, isEqualToOrDescendantOf ancestorPath: String) -> Bool {
        if path == ancestorPath {
            return true
        }

        let ancestorPrefix = ancestorPath.hasSuffix("/") ? ancestorPath : "\(ancestorPath)/"
        return path.hasPrefix(ancestorPrefix)
    }

    private static func pathMatchPortion(of pattern: String) -> String {
        pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
    }

    private static func basename(fromNormalizedPath path: String) -> String {
        let endIndex = path.count > 1 && path.hasSuffix("/")
            ? path.index(before: path.endIndex)
            : path.endIndex
        guard let separatorIndex = path[..<endIndex].lastIndex(of: "/") else {
            return String(path[..<endIndex])
        }

        let basenameStartIndex = path.index(after: separatorIndex)
        return String(path[basenameStartIndex..<endIndex])
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

    private func relativePath(forNormalizedPath path: String) -> String? {
        guard path != rootPath else { return "" }

        if rootPath == "/" {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }
}

nonisolated private struct CloudLocation: Sendable {
    /// Concrete cloud root (current user's) to exclude, or nil when not applicable
    /// for this scan (e.g. the user opted in, or is explicitly scanning into it).
    let excludedRootPath: String?
    /// Whether the generic `/Users/*/<userRelativeComponents>` rule should apply,
    /// so that broad scans (`/`, `/Users`, ...) skip every user's cloud root.
    let excludesAnyUser: Bool
    /// Path components after `/Users/<user>` identifying this cloud location,
    /// e.g. `["Library", "CloudStorage"]` or `["Library", "Mobile Documents"]`.
    let userRelativeComponents: [String]

    var isActive: Bool {
        excludedRootPath != nil || excludesAnyUser
    }

    func excludes(path: String) -> Bool {
        if let excludedRootPath {
            if path == excludedRootPath {
                return true
            }

            let rootPrefix = excludedRootPath.hasSuffix("/")
                ? excludedRootPath
                : "\(excludedRootPath)/"
            if path.hasPrefix(rootPrefix) {
                return true
            }
        }

        return excludesAnyUser
            && ScanExclusionMatcher.isUsersCloudPath(path, userRelativeComponents: userRelativeComponents)
    }
}

nonisolated private struct CompiledPattern: Sendable {
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

nonisolated private struct GlobPattern: Sendable {
    private enum Token: Sendable {
        case literal(Character)
        case anySingle(allowsSlash: Bool)
        case anyRun(allowsSlash: Bool)
    }

    private struct MemoKey: Hashable, Sendable {
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
