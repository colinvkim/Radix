import Foundation

/// Avoids repeated Foundation package-property lookups by combining the native
/// Finder bundle bit with scan-scoped filename-extension decisions. Without the
/// bundle bit, only a filename extension can make a directory a package, so
/// extensionless names never need Foundation; every new nonempty extension
/// retains one conservative Foundation compatibility lookup.
nonisolated final class PackageClassifier: @unchecked Sendable {
    enum ExtensionDisposition: Sendable {
        case knownNonPackage
        case ambiguous
    }

    enum Source: Sendable, Equatable {
        case fastNegative
        case finderInfo
        case foundation
        case extensionCache
    }

    struct Classification: Sendable {
        let isPackage: Bool
        let source: Source
    }

    typealias ExtensionDispositionProvider = @Sendable (String) -> ExtensionDisposition
    typealias FoundationPackageProvider = @Sendable (URL) -> Bool?

    private static let packageCandidateExtensions: Set<String> = [
        "action", "app", "appex", "audiounit", "band", "bundle", "component",
        "dashboard", "doccarchive", "dsym", "epub", "framework", "kext", "key",
        "logicx", "mailbundle", "mdimporter", "mlmodelc", "momd", "mpkg",
        "musiclibrary", "numbers", "pages", "photolibrary", "photoslibrary",
        "playground", "playgroundbook", "plugin", "pkg", "prefpane", "qlgenerator",
        "rtfd", "saver", "service", "systemextension", "vst", "vst3", "wdgt",
        "workflow", "xcarchive", "xcassets", "xcdatamodeld", "xcframework",
        "xcodeproj", "xcresult", "xctest", "xcworkspace", "xpc", "artifactbundle"
    ]

    /// Stable content-file extensions that cannot imply a package on their own.
    /// A native Finder bundle bit always takes precedence, and unknown extensions
    /// remain ambiguous so dynamically registered package types retain Foundation
    /// compatibility.
    private static let knownNonPackageExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "csv", "h", "hpp", "htm", "html", "js",
        "json", "log", "m", "md", "mm", "plist", "py", "sh", "strings",
        "swift", "text", "ts", "txt", "xml", "yaml", "yml"
    ]

    private let condition = NSCondition()
    private let extensionDispositionProvider: ExtensionDispositionProvider
    private let foundationPackageProvider: FoundationPackageProvider
    private var dispositionByExtension: [String: ExtensionDisposition] = [:]
    private var packageValueByExtension: [String: Bool] = [:]
    private var pendingFoundationExtensions: Set<String> = []

    init(
        extensionDispositionProvider: @escaping ExtensionDispositionProvider = PackageClassifier.defaultDisposition,
        foundationPackageProvider: @escaping FoundationPackageProvider = PackageClassifier.defaultFoundationPackageValue
    ) {
        self.extensionDispositionProvider = extensionDispositionProvider
        self.foundationPackageProvider = foundationPackageProvider
    }

    func classification(
        for url: URL,
        hasFinderPackageFlag: Bool? = nil
    ) -> Classification {
        if hasFinderPackageFlag == true {
            return Classification(isPackage: true, source: .finderInfo)
        }
        guard hasFinderPackageFlag == false else {
            return foundationClassification(for: url)
        }

        let pathExtension = url.pathExtension.lowercased()
        guard !pathExtension.isEmpty else {
            return Classification(isPackage: false, source: .fastNegative)
        }

        let disposition: ExtensionDisposition
        condition.lock()
        if let cachedPackageValue = packageValueByExtension[pathExtension] {
            condition.unlock()
            return Classification(isPackage: cachedPackageValue, source: .extensionCache)
        }
        if let cachedDisposition = dispositionByExtension[pathExtension] {
            disposition = cachedDisposition
            condition.unlock()
        } else {
            condition.unlock()
            let resolvedDisposition = Self.packageCandidateExtensions.contains(pathExtension)
                ? ExtensionDisposition.ambiguous
                : extensionDispositionProvider(pathExtension)
            condition.lock()
            let installedDisposition = dispositionByExtension[pathExtension] ?? resolvedDisposition
            dispositionByExtension[pathExtension] = installedDisposition
            disposition = installedDisposition
            condition.unlock()
        }

        switch disposition {
        case .knownNonPackage:
            return Classification(isPackage: false, source: .fastNegative)
        case .ambiguous:
            return resolveAmbiguousExtension(pathExtension, for: url)
        }
    }

    private func resolveAmbiguousExtension(
        _ pathExtension: String,
        for url: URL
    ) -> Classification {
        condition.lock()
        while pendingFoundationExtensions.contains(pathExtension) {
            condition.wait()
            if let cachedPackageValue = packageValueByExtension[pathExtension] {
                condition.unlock()
                return Classification(isPackage: cachedPackageValue, source: .extensionCache)
            }
        }
        if let cachedPackageValue = packageValueByExtension[pathExtension] {
            condition.unlock()
            return Classification(isPackage: cachedPackageValue, source: .extensionCache)
        }
        pendingFoundationExtensions.insert(pathExtension)
        condition.unlock()

        let packageValue = foundationPackageProvider(url)

        condition.lock()
        pendingFoundationExtensions.remove(pathExtension)
        if let packageValue {
            packageValueByExtension[pathExtension] = packageValue
        }
        condition.broadcast()
        condition.unlock()
        return Classification(isPackage: packageValue ?? false, source: .foundation)
    }

    private func foundationClassification(for url: URL) -> Classification {
        Classification(
            isPackage: foundationPackageProvider(url) ?? false,
            source: .foundation
        )
    }

    private static func defaultDisposition(for pathExtension: String) -> ExtensionDisposition {
        knownNonPackageExtensions.contains(pathExtension) ? .knownNonPackage : .ambiguous
    }

    private static func defaultFoundationPackageValue(for url: URL) -> Bool? {
        try? url.resourceValues(forKeys: [.isPackageKey]).isPackage
    }
}
