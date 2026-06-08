import XCTest
@testable import RadixCore

final class AppPreferencesStoreTests: XCTestCase {
    func testLoadPreferencesUsesAppDefaultsWhenValuesAreMissing() {
        let defaults = makeIsolatedDefaults()
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.loadPreferences(), .defaults)
    }

    func testSaveAndReloadScanPreferencesRoundTripsValues() {
        let defaults = makeIsolatedDefaults()
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        let preferences = AppScanPreferences(
            showHiddenFiles: false,
            treatPackagesAsDirectories: true,
            maxRenderedDepth: 9,
            autoSummarizeDirectories: false
        )

        store.saveScanPreferences(preferences)

        XCTAssertEqual(store.loadPreferences().scan, preferences)
        XCTAssertFalse(store.loadPreferences().didCompleteOnboarding)

        store.markOnboardingComplete()

        XCTAssertTrue(store.loadPreferences().didCompleteOnboarding)

        store.markOnboardingIncomplete()

        XCTAssertFalse(store.loadPreferences().didCompleteOnboarding)
    }

    func testLoadPreferencesClampsInvalidDepthAndPreservesExplicitFalseValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "showHiddenFiles")
        defaults.set(true, forKey: "treatPackagesAsDirectories")
        defaults.set(42, forKey: "maxRenderedDepth")
        defaults.set(false, forKey: "autoSummarizeDirectories")

        let preferences = UserDefaultsAppPreferencesStore(defaults: defaults).loadPreferences().scan

        XCTAssertFalse(preferences.showHiddenFiles)
        XCTAssertTrue(preferences.treatPackagesAsDirectories)
        XCTAssertEqual(preferences.maxRenderedDepth, AppScanPreferences.defaults.maxRenderedDepth)
        XCTAssertFalse(preferences.autoSummarizeDirectories)
    }
}

private func makeIsolatedDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
) -> UserDefaults {
    let suiteName = "RadixTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create isolated UserDefaults suite.", file: file, line: line)
        return .standard
    }

    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
