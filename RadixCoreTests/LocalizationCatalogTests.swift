import Foundation
import Testing

struct LocalizationCatalogTests {
    private let supportedLocales = ["de", "es", "fr", "it", "ru", "zh-Hans"]

    private struct LocalizedSourceLiteral {
        let value: String
        let table: String
        let file: String
        let line: Int
    }

    @Test
    func testCatalogProvidesEveryExtractedKeyInSupportedLocales() throws {
        let catalogs = try appLocalizationCatalogs()
        let duplicateKeys = Set(catalogs["Localizable", default: [:]].keys)
            .intersection(catalogs["Interface", default: [:]].keys)
        #expect(duplicateKeys.isEmpty, "Localization keys must belong to exactly one table: \(duplicateKeys.sorted())")

        let strings = catalogs.values.reduce(into: [String: Any]()) { merged, catalog in
            merged.merge(catalog) { existing, _ in existing }
        }
        #expect(strings[""] == nil, "The localization catalogs must not contain an empty key.")
        let fragmentKeys = strings.keys.filter {
            $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(
            fragmentKeys.isEmpty,
            "Localize complete phrases instead of whitespace-dependent fragments: \(fragmentKeys.sorted())")

        let supportedLocaleSet = Set(supportedLocales)
        for (key, value) in strings {
            let entry = try #require(value as? [String: Any], "Invalid catalog entry for \(key)")
            #expect(entry["extractionState"] as? String != "stale", "Stale localization key \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            #expect(supportedLocaleSet.isSubset(of: Set(localizations.keys)), "Missing supported locale for \(key)")

            for locale in supportedLocales {
                let localization = try #require(localizations[locale] as? [String: Any])
                if let stringUnit = localization["stringUnit"] as? [String: Any] {
                    try assertTranslated(stringUnit, locale: locale, key: key)
                } else {
                    let variations = try #require(localization["variations"] as? [String: Any])
                    let plurals = try #require(variations["plural"] as? [String: Any])
                    #expect(!(plurals.isEmpty), "Missing plural variants for \(locale) key \(key)")
                    if locale == "ru" {
                        #expect(
                            Set(["one", "few", "many", "other"]).isSubset(of: Set(plurals.keys)),
                            "Missing Russian plural categories for \(key)")
                    }
                    for (category, value) in plurals {
                        let variant = try #require(value as? [String: Any])
                        let stringUnit = try #require(variant["stringUnit"] as? [String: Any])
                        try assertTranslated(stringUnit, locale: locale, key: "\(key) [\(category)]")
                    }
                }
            }
        }
    }

    @Test
    func testInfoPlistCatalogProvidesSupportedLocalesForEveryEntry() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot =
            testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL =
            repositoryRoot
            .appendingPathComponent("Radix")
            .appendingPathComponent("InfoPlist.xcstrings")

        let data = try Data(contentsOf: catalogURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])
        #expect(!(strings.isEmpty))

        for (key, value) in strings {
            let entry = try #require(value as? [String: Any], "Invalid metadata catalog entry for \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            for locale in supportedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
                let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
                try assertTranslated(stringUnit, locale: locale, key: key)
            }
        }
    }

    @Test
    func testEveryAppSourceLocalizationLiteralExistsInCatalog() throws {
        let root = repositoryRoot
        let catalogTemplates = try appLocalizationCatalogs().mapValues { Set($0.keys.map(localizationTemplate)) }
        let sourceFiles = try swiftSourceFiles(in: root.appendingPathComponent("Radix"))

        let literals = try sourceFiles.flatMap(localizedLiterals)
        #expect(!literals.isEmpty, "The localization audit must extract app source literals.")

        let missing = literals.filter { catalogTemplates[$0.table]?.contains(localizationTemplate($0.value)) != true }
        #expect(
            missing.isEmpty,
            Comment(
                rawValue: missing.map {
                    "\($0.file):\($0.line): missing key in \($0.table) for \(String(reflecting: $0.value))"
                }
                .joined(separator: "\n")))
    }

    @Test
    func testRussianCountsRenderUsingCompiledCatalog() throws {
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        // Exercise Apple's catalog compiler and plural selection, including positional arguments.
        let compiler = Process()
        compiler.executableURL = URL(filePath: "/usr/bin/xcrun")
        compiler.arguments = [
            "xcstringstool", "compile",
            repositoryRoot.appendingPathComponent("Radix/Localizable.xcstrings").path,
            "--output-directory", output.path, "--language", "ru",
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0, "Failed to compile the Russian catalog")
        let bundle = try #require(Bundle(url: output.appendingPathComponent("ru.lproj")))
        func render(_ key: String, _ arguments: CVarArg...) -> String {
            String(
                format: bundle.localizedString(forKey: key, value: nil, table: "Localizable"),
                locale: Locale(identifier: "ru"), arguments: arguments)
        }

        let examples: [(Int64, String, String, String)] = [
            (0, "уровней", "файлов", "объектов"),
            (1, "уровень", "файл", "объект"),
            (2, "уровня", "файла", "объекта"),
            (3, "уровня", "файла", "объекта"),
            (4, "уровня", "файла", "объекта"),
            (5, "уровней", "файлов", "объектов"),
            (11, "уровней", "файлов", "объектов"),
            (21, "уровень", "файл", "объект"),
            (22, "уровня", "файла", "объекта"),
            (25, "уровней", "файлов", "объектов"),
        ]
        for (count, levels, files, items) in examples {
            #expect(render("%lld levels", count) == "\(count) \(levels)")
            #expect(
                render("%lld levels, including free space", count)
                    == "\(count) \(levels), включая свободное место")
            #expect(render("%lld files", count) == "\(count) \(files)")
            #expect(
                render("Move %lld Items to Trash", count) == "Переместить \(count) \(items) в Корзину")
            let adjective = items == "объект" ? "сгруппированный" : "сгруппированных"
            #expect(render("%lld grouped items", count) == "\(count) \(adjective) \(items)")
            let changes = items == "объект" ? "изменению" : "изменениям"
            #expect(render("%lld changes summarized", count) == "Сводка по \(count) \(changes)")
        }
        #expect(
            render(
                "Limited coverage: %lld unreadable locations. Missing entries below them are not necessarily deleted.",
                Int64(22))
                == "Ограниченный охват: не удалось прочитать 22 расположения. Отсутствующие в них объекты не обязательно были удалены.")
        #expect(
            render(
                "Radix will ask macOS to move %lld selected items to the Trash:\n%@%@",
                Int64(21), "/example", "\n+ ещё 20")
                == "Radix попросит macOS переместить 21 выбранный объект в Корзину:\n/example\n+ ещё 20")
    }

    @Test
    func testSwiftPackageCoreSourceListMatchesCoreFilesOnDisk() throws {
        let root = repositoryRoot
        let scratch = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let package = Process()
        let output = Pipe()
        package.executableURL = URL(filePath: "/usr/bin/xcrun")
        package.arguments = ["swift", "package", "--package-path", root.path, "--scratch-path", scratch.path, "describe", "--type", "json"]
        package.standardOutput = output
        try package.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        package.waitUntilExit()
        try #require(package.terminationStatus == 0)
        let description = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try #require(description["targets"] as? [[String: Any]])
        let core = try #require(targets.first { $0["name"] as? String == "RadixCore" })
        let listedSources = Set(try #require(core["sources"] as? [String]))

        let appSourceRoot = root.appendingPathComponent("Radix")
        let expectedSources = Set(
            try swiftSourceFiles(in: appSourceRoot).compactMap { url -> String? in
                let relativePath = String(url.path.dropFirst(appSourceRoot.path.count + 1))
                let firstComponent = relativePath.split(separator: "/").first.map(String.init)
                if ["App", "Features", "Shared"].contains(firstComponent) { return nil }
                if ["ContentView.swift", "RadixApp.swift"].contains(relativePath) { return nil }
                return relativePath
            })

        #expect(
            listedSources == expectedSources,
            "Package.swift's explicit RadixCore sources must track every non-UI Swift source exactly.")
    }

    @Test
    func testXcodeProjectDeclaresSupportedLocales() throws {
        let url = repositoryRoot.appendingPathComponent("Radix.xcodeproj/project.pbxproj")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let project = try #require(plist as? [String: Any])
        let objects = try #require(project["objects"] as? [String: Any])
        let rootID = try #require(project["rootObject"] as? String)
        let root = try #require(objects[rootID] as? [String: Any])
        let knownRegions = try #require(root["knownRegions"] as? [String])
        #expect(Set(["en"] + supportedLocales).isSubset(of: Set(knownRegions)))
    }

    private func assertTranslated(
        _ stringUnit: [String: Any],
        locale: String,
        key: String
    ) throws {
        #expect(stringUnit["state"] as? String == "translated", "Untranslated \(locale) value for \(key)")
        let value = try #require(stringUnit["value"] as? String, "Missing \(locale) value for \(key)")
        let sourceKey = key.components(separatedBy: " [").first ?? key
        #expect(
            formatSpecifiers(in: value) == formatSpecifiers(in: sourceKey),
            "Format specifiers changed in the \(locale) translation for \(key)")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizationCatalog(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sourceLanguage"] as? String == "en", "Unexpected source language in \(url.lastPathComponent)")
        return try #require(object["strings"] as? [String: Any])
    }

    private func appLocalizationCatalogs() throws -> [String: [String: Any]] {
        let radixRoot = repositoryRoot.appendingPathComponent("Radix")
        return [
            "Localizable": try localizationCatalog(at: radixRoot.appendingPathComponent("Localizable.xcstrings")),
            "Interface": try localizationCatalog(at: radixRoot.appendingPathComponent("Interface.xcstrings")),
        ]
    }

    private func swiftSourceFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ))
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                url.pathExtension == "swift",
                try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
            else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private func localizedLiterals(in fileURL: URL) throws -> [LocalizedSourceLiteral] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let patterns = [
            #"\b\w+\s*\(\s*localized\s*:\s*"((?:\\.|[^"\\])*)""#,
            #"\b(?:Text|Label|Button|Toggle|Picker|Section|TextField|SecureField|Menu|GroupBox|LabeledContent|NavigationLink|CommandMenu|ProgressView|TableColumn|Window)\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\bContentUnavailableView\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\.(?:navigationTitle|accessibilityLabel|accessibilityHint|help|confirmationDialog|alert)\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\.searchable\s*\([^\n]*\bprompt\s*:\s*"((?:\\.|[^"\\])*)""#,
        ]

        return try patterns.flatMap { pattern -> [LocalizedSourceLiteral] in
            let expression = try NSRegularExpression(
                pattern: pattern + #"(?:\s*,\s*table(?:Name)?\s*:\s*"([^"]+)")?"#)
            return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                guard let valueRange = Range(match.range(at: 1), in: source),
                      let fullRange = Range(match.range, in: source) else { return nil }
                let table = Range(match.range(at: 2), in: source).map { String(source[$0]) } ?? "Localizable"
                let location = source.distance(from: source.startIndex, to: fullRange.lowerBound)
                let prefix = source.prefix(location)
                let line = prefix.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                return LocalizedSourceLiteral(
                    value: decodedSwiftLiteral(String(source[valueRange])),
                    table: table,
                    file: fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""),
                    line: line
                )
            }
        }
    }

    private func decodedSwiftLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\t"#, with: "\t")
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
    }

    private func localizationTemplate(_ value: String) -> String {
        let withoutInterpolations = replacingSwiftInterpolations(in: value, with: "{value}")
        return withoutInterpolations.replacingOccurrences(
            of: #"%(?:[0-9]+\$)?(?:lld|ld|llu|lu|d|u|f|@)"#,
            with: "{value}",
            options: .regularExpression
        )
    }

    private func replacingSwiftInterpolations(in value: String, with replacement: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "\\" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let openParenthesis = value.index(after: index)
            guard openParenthesis < value.endIndex, value[openParenthesis] == "(" else {
                result.append(value[index])
                index = openParenthesis
                continue
            }

            var depth = 1
            var cursor = value.index(after: openParenthesis)
            while cursor < value.endIndex, depth > 0 {
                if value[cursor] == "(" { depth += 1 }
                if value[cursor] == ")" { depth -= 1 }
                cursor = value.index(after: cursor)
            }
            result += replacement
            index = cursor
        }
        return result
    }

    private func formatSpecifiers(in value: String) -> [String: Int] {
        let pattern = #"%(?:[0-9]+\$)?(?:lld|ld|llu|lu|d|u|f|@)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)

        return expression.matches(in: value, range: range).reduce(into: [:]) { counts, match in
            guard let range = Range(match.range, in: value) else { return }
            let specifier = value[range]
                .replacingOccurrences(of: #"%[0-9]+\$"#, with: "%", options: .regularExpression)
            counts[specifier, default: 0] += 1
        }
    }
}
