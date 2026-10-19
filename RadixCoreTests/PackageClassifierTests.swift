import Darwin
import Foundation
import Testing

@testable import RadixCore

struct PackageClassifierTests {
    @Test
    func testClassifierRoutesEachDirectoryToTheCheapestSource() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return ["Sample.app", "Custom.weird"].contains(url.lastPathComponent)
        })

        let ordinaryURL = URL(filePath: "/tmp/Ordinary.TXT", directoryHint: .isDirectory)
        #expect(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: false).source == .fastNegative)
        #expect(counters.foundationCount == 0)

        let appURL = URL(filePath: "/tmp/Sample.app", directoryHint: .isDirectory)
        #expect(classifier.classification(for: appURL, hasFinderPackageFlag: false).isPackage)
        #expect(classifier.classification(for: appURL, hasFinderPackageFlag: false).isPackage)
        #expect(counters.foundationCount == 2)

        let customURL = URL(filePath: "/tmp/Custom.weird", directoryHint: .isDirectory)
        #expect(classifier.classification(for: customURL, hasFinderPackageFlag: false).isPackage)
        #expect(counters.foundationCount == 3)

        let extensionlessURL = URL(filePath: "/tmp/Extensionless", directoryHint: .isDirectory)
        let extensionlessClassification = classifier.classification(
            for: extensionlessURL,
            hasFinderPackageFlag: false
        )
        #expect(!(extensionlessClassification.isPackage))
        #expect(extensionlessClassification.source == .fastNegative)
        #expect(counters.foundationCount == 3)

        #expect(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: true).isPackage)
        #expect(counters.foundationCount == 3)

        #expect(!(classifier.classification(for: ordinaryURL, hasFinderPackageFlag: nil).isPackage))
        #expect(counters.foundationCount == 4)
    }

    @Test
    func testBulkEnumerationUsesClassifierOnlyForNeededDirectories() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for name in ["Ordinary.txt", "Sample.app", "Custom.weird", "Extensionless"] {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return ["Sample.app", "Custom.weird", "Extensionless"].contains(url.lastPathComponent)
        })
        let metadataLoader = ScanMetadataLoader(packageClassifier: classifier)
        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)
        let packageValueByName = Dictionary(
            uniqueKeysWithValues: result.entries.map {
                ($0.url.lastPathComponent, $0.metadata?.isPackage ?? false)
            })

        #expect(packageValueByName["Ordinary.txt"] == false)
        #expect(packageValueByName["Sample.app"] == true)
        #expect(packageValueByName["Custom.weird"] == true)
        #expect(packageValueByName["Extensionless"] == false)
        #expect(counters.foundationCount == 2)

        let noPackageResultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                loadsPackageMetadata: false,
                metadataLoader: metadataLoader,
                cancellationCheck: {}
            ))
        let noPackageResult = try #require(noPackageResultValue)
        #expect(noPackageResult.entries.allSatisfy { $0.metadata?.isPackage == false })
        #expect(counters.foundationCount == 2)
    }

    @Test
    func testDefaultPolicyFastNegativesOnlyKnownContentExtensions() {
        let counters = PackageClassifierCounters()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counters.recordFoundation(url)
            return false
        })

        for name in ["Ordinary.txt", "English.lproj"] {
            let classification = classifier.classification(
                for: URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory),
                hasFinderPackageFlag: false
            )
            #expect(!(classification.isPackage))
            #expect(classification.source == .fastNegative)
        }
        #expect(counters.foundationCount == 0)

        let unknownClassification = classifier.classification(
            for: URL(filePath: "/tmp/Unknown.radixunknown", directoryHint: .isDirectory),
            hasFinderPackageFlag: false
        )
        #expect(!(unknownClassification.isPackage))
        #expect(unknownClassification.source == .foundation)
        #expect(counters.foundationCount == 1)
    }

    @Test
    func testFinderBundleBitPreservesExtensionlessAndOrdinaryExtensionPackages() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let extensionlessURL = rootURL.appending(path: "MarkedPackage", directoryHint: .isDirectory)
        let ordinaryExtensionURL = rootURL.appending(path: "MarkedPackage.txt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensionlessURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinaryExtensionURL, withIntermediateDirectories: true)
        try setFinderBundleBit(at: extensionlessURL)
        try setFinderBundleBit(at: ordinaryExtensionURL)

        #expect(try extensionlessURL.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
        #expect(try ordinaryExtensionURL.resourceValues(forKeys: [.isPackageKey]).isPackage == true)

        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)
        #expect(result.entries.allSatisfy { $0.metadata?.isPackage == true })
    }

    @Test
    func testBundleShapedExtensionlessDirectoryMatchesFoundation() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bundleURL = rootURL.appending(path: "BundleShaped", directoryHint: .isDirectory)
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.radix.bundle-shaped",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try infoPlist.write(to: contentsURL.appending(path: "Info.plist"))
        try Data("APPL????".utf8).write(to: contentsURL.appending(path: "PkgInfo"))

        #expect(try bundleURL.resourceValues(forKeys: [.isPackageKey]).isPackage == false)

        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)
        #expect(result.entries.map(\.url.lastPathComponent) == ["BundleShaped"])
        #expect(result.entries.allSatisfy { $0.metadata?.isPackage == false })
    }

    @Test
    func testPackageDecisionsDoNotDependOnClassificationOrder() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bundleURL = rootURL.appending(path: "Bundle.component", directoryHint: .isDirectory)
        let folderURL = rootURL.appending(path: "Folder.component", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: bundleURL.appending(path: "Contents", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("BNDL????".utf8).write(to: bundleURL.appending(path: "Contents/PkgInfo"))

        #expect(try bundleURL.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
        #expect(try folderURL.resourceValues(forKeys: [.isPackageKey]).isPackage == false)

        for order in [[bundleURL, folderURL], [folderURL, bundleURL]] {
            let classifier = PackageClassifier()
            let isPackageByName = Dictionary(
                uniqueKeysWithValues: order.map {
                    ($0.lastPathComponent, classifier.classification(for: $0, hasFinderPackageFlag: false).isPackage)
                })
            #expect(isPackageByName == ["Bundle.component": true, "Folder.component": false])
        }
    }

    @Test
    func testRegisteredPackageExtensionsMatchFoundation() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let names = [
            "Application.app", "Installer.pkg", "MetaInstaller.mpkg",
            "Presentation.key", "Book.epub",
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let resultValue = try
            (BulkDirectoryEnumerator.directoryEntries(
                at: rootURL,
                includeHiddenFiles: true,
                metadataLoader: ScanMetadataLoader(),
                cancellationCheck: {}
            ))
        let result = try #require(resultValue)
        let bulkValueByName = Dictionary(
            uniqueKeysWithValues: result.entries.map {
                ($0.url.lastPathComponent, $0.metadata?.isPackage ?? false)
            })

        for name in names {
            let url = rootURL.appending(path: name, directoryHint: .isDirectory)
            let foundationValue = try url.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false
            #expect(bulkValueByName[name] == foundationValue, "Package mismatch for .\(url.pathExtension)")
        }
    }

    private func setFinderBundleBit(at url: URL) throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x20
        let result = finderInfo.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return setxattr(
                    path,
                    "com.apple.FinderInfo",
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private final class PackageClassifierCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var foundationURLs: [URL] = []

    var foundationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return foundationURLs.count
    }

    func recordFoundation(_ url: URL) {
        lock.lock()
        foundationURLs.append(url)
        lock.unlock()
    }
}
