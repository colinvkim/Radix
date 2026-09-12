import Foundation
import Testing

@testable import RadixCore

@MainActor
struct AppPreferencesStoreTests {
    private let temporaryDefaults = TemporaryTestDefaults()

    @Test
    func testLoadPreferencesUsesAppDefaultsWhenValuesAreMissing() throws {
        let defaults = try temporaryDefaults.make()
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)

        #expect(store.loadPreferences() == .defaults)
    }

    @Test
    func testSaveAndReloadScanPreferencesRoundTripsValues() throws {
        let defaults = try temporaryDefaults.make()
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        let preferences = AppScanPreferences(
            showHiddenFiles: false,
            treatPackagesAsDirectories: true,
            maxRenderedDepth: 9,
            autoSummarizeDirectories: false,
            showFreeSpaceInDiskMaps: true,
            visualizationMode: .treemap,
            useScanExclusions: true,
            exclusionPatterns: ["node_modules", "*.log"]
        )

        store.saveScanPreferences(preferences)

        #expect(store.loadPreferences().scan == preferences)
        #expect(!(store.loadPreferences().didCompleteOnboarding))

        store.markOnboardingComplete()

        #expect(store.loadPreferences().didCompleteOnboarding)

        store.markOnboardingIncomplete()

        #expect(!(store.loadPreferences().didCompleteOnboarding))
    }

    @Test
    func testLoadPreferencesClampsInvalidDepthAndPreservesExplicitFalseValues() throws {
        let defaults = try temporaryDefaults.make()
        defaults.set(false, forKey: "showHiddenFiles")
        defaults.set(true, forKey: "treatPackagesAsDirectories")
        defaults.set(42, forKey: "maxRenderedDepth")
        defaults.set(false, forKey: "autoSummarizeDirectories")
        defaults.set(true, forKey: "showFreeSpaceInSunburst")
        defaults.set("treemap", forKey: "scanVisualizationMode")
        defaults.set(true, forKey: "useScanExclusions")
        defaults.set([".DS_Store"], forKey: "exclusionPatterns")

        let preferences = UserDefaultsAppPreferencesStore(defaults: defaults).loadPreferences().scan

        #expect(!(preferences.showHiddenFiles))
        #expect(preferences.treatPackagesAsDirectories)
        #expect(preferences.maxRenderedDepth == AppScanPreferences.defaults.maxRenderedDepth)
        #expect(!(preferences.autoSummarizeDirectories))
        #expect(preferences.showFreeSpaceInDiskMaps)
        #expect(preferences.visualizationMode == .treemap)
        #expect(preferences.useScanExclusions)
        #expect(preferences.exclusionPatterns == [".DS_Store"])
    }

    @Test
    func testOnboardingPageSurvivesRelaunchAndUnknownValuesFallBackToWelcome() throws {
        let defaults = try temporaryDefaults.make()
        let store = UserDefaultsAppPreferencesStore(defaults: defaults)
        store.saveOnboardingPage(.access)
        store.markOnboardingIncomplete()

        let restored = UserDefaultsAppPreferencesStore(defaults: defaults).loadPreferences()
        #expect(restored.onboardingPage == .access)
        #expect(!(restored.didCompleteOnboarding))

        defaults.set("unrecognized", forKey: "onboardingPage")
        #expect(store.loadPreferences().onboardingPage == .welcome)
    }
}
