import Foundation

/// Avoids Foundation package-property lookups where the native Finder bundle bit
/// or the filename settles the answer. Without the bundle bit, only a filename
/// extension can make a directory a package, so extensionless names never need
/// Foundation. Foundation's answer for an extension still depends on each
/// directory, such as `Contents/PkgInfo` or a sandbox container, so it must not
/// be cached per extension.
nonisolated struct PackageClassifier: Sendable {
    enum Source: Sendable, Equatable {
        case fastNegative
        case finderInfo
        case foundation
    }

    struct Classification: Sendable {
        let isPackage: Bool
        let source: Source
    }

    typealias FoundationPackageProvider = @Sendable (URL) -> Bool?

    /// Stable content-file extensions that cannot imply a package on their own.
    /// A native Finder bundle bit always takes precedence, and unknown extensions
    /// go to Foundation so dynamically registered package types stay compatible.
    private static let knownNonPackageExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "csv", "h", "hpp", "htm", "html", "js",
        "json", "log", "lproj", "m", "md", "mm", "plist", "py", "sh", "strings",
        "swift", "text", "ts", "txt", "xml", "yaml", "yml"
    ]

    private let foundationPackageProvider: FoundationPackageProvider

    init(
        foundationPackageProvider: @escaping FoundationPackageProvider = PackageClassifier.defaultFoundationPackageValue
    ) {
        self.foundationPackageProvider = foundationPackageProvider
    }

    func classification(
        for url: URL,
        hasFinderPackageFlag: Bool? = nil
    ) -> Classification {
        if hasFinderPackageFlag == true {
            return Classification(isPackage: true, source: .finderInfo)
        }
        if hasFinderPackageFlag == false {
            let pathExtension = url.pathExtension.lowercased()
            if pathExtension.isEmpty || Self.knownNonPackageExtensions.contains(pathExtension) {
                return Classification(isPackage: false, source: .fastNegative)
            }
        }
        return Classification(
            isPackage: foundationPackageProvider(url) ?? false,
            source: .foundation
        )
    }

    private static func defaultFoundationPackageValue(for url: URL) -> Bool? {
        try? url.resourceValues(forKeys: [.isPackageKey]).isPackage
    }
}
