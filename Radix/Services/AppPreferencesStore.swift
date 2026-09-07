//
//  AppPreferencesStore.swift
//  Radix
//

import Foundation

nonisolated enum ScanVisualizationMode: String, CaseIterable, Identifiable, Sendable {
    case sunburst
    case treemap

    var id: Self { self }
}

nonisolated struct AppScanPreferences: Equatable {
    var showHiddenFiles: Bool
    var treatPackagesAsDirectories: Bool
    var maxRenderedDepth: Int
    var autoSummarizeDirectories: Bool
    var showFreeSpaceInDiskMaps: Bool
    var visualizationMode: ScanVisualizationMode
    var useScanExclusions: Bool
    var exclusionPatterns: [String]

    static let defaults = AppScanPreferences(
        showHiddenFiles: true,
        treatPackagesAsDirectories: false,
        maxRenderedDepth: 6,
        autoSummarizeDirectories: true,
        showFreeSpaceInDiskMaps: false,
        visualizationMode: .sunburst,
        useScanExclusions: false,
        exclusionPatterns: ScanExclusionMatcher.commonPresetPatterns
    )
}

nonisolated struct AppPreferences: Equatable {
    var scan: AppScanPreferences
    var didCompleteOnboarding: Bool
    var onboardingPage: OnboardingPage = .welcome

    static let defaults = AppPreferences(
        scan: .defaults,
        didCompleteOnboarding: false
    )
}

protocol AppPreferencesPersisting: AnyObject {
    func loadPreferences() -> AppPreferences
    func saveScanPreferences(_ preferences: AppScanPreferences)
    func markOnboardingComplete()
    func markOnboardingIncomplete()
    func saveOnboardingPage(_ page: OnboardingPage)
}

final class UserDefaultsAppPreferencesStore: AppPreferencesPersisting {
    private enum Key {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let onboardingPage = "onboardingPage"
        static let showHiddenFiles = "showHiddenFiles"
        static let treatPackagesAsDirectories = "treatPackagesAsDirectories"
        static let maxRenderedDepth = "maxRenderedDepth"
        static let autoSummarizeDirectories = "autoSummarizeDirectories"
        // Keep the persisted key stable for existing installations.
        static let showFreeSpaceInDiskMaps = "showFreeSpaceInSunburst"
        static let visualizationMode = "scanVisualizationMode"
        static let useScanExclusions = "useScanExclusions"
        static let exclusionPatterns = "exclusionPatterns"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPreferences() -> AppPreferences {
        let showHiddenFiles: Bool
        if defaults.object(forKey: Key.showHiddenFiles) == nil {
            showHiddenFiles = AppScanPreferences.defaults.showHiddenFiles
        } else {
            showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)
        }

        let storedDepth = defaults.integer(forKey: Key.maxRenderedDepth)
        let maxRenderedDepth = (3...10).contains(storedDepth)
            ? storedDepth
            : AppScanPreferences.defaults.maxRenderedDepth

        let autoSummarizeDirectories: Bool
        if defaults.object(forKey: Key.autoSummarizeDirectories) == nil {
            autoSummarizeDirectories = AppScanPreferences.defaults.autoSummarizeDirectories
        } else {
            autoSummarizeDirectories = defaults.bool(forKey: Key.autoSummarizeDirectories)
        }

        let showFreeSpaceInDiskMaps: Bool
        if defaults.object(forKey: Key.showFreeSpaceInDiskMaps) == nil {
            showFreeSpaceInDiskMaps = AppScanPreferences.defaults.showFreeSpaceInDiskMaps
        } else {
            showFreeSpaceInDiskMaps = defaults.bool(forKey: Key.showFreeSpaceInDiskMaps)
        }

        let visualizationMode = defaults.string(forKey: Key.visualizationMode)
            .flatMap(ScanVisualizationMode.init(rawValue:))
            ?? AppScanPreferences.defaults.visualizationMode

        let useScanExclusions: Bool
        if defaults.object(forKey: Key.useScanExclusions) == nil {
            useScanExclusions = AppScanPreferences.defaults.useScanExclusions
        } else {
            useScanExclusions = defaults.bool(forKey: Key.useScanExclusions)
        }

        let exclusionPatterns = defaults.stringArray(forKey: Key.exclusionPatterns)
            ?? AppScanPreferences.defaults.exclusionPatterns

        return AppPreferences(
            scan: AppScanPreferences(
                showHiddenFiles: showHiddenFiles,
                treatPackagesAsDirectories: defaults.bool(forKey: Key.treatPackagesAsDirectories),
                maxRenderedDepth: maxRenderedDepth,
                autoSummarizeDirectories: autoSummarizeDirectories,
                showFreeSpaceInDiskMaps: showFreeSpaceInDiskMaps,
                visualizationMode: visualizationMode,
                useScanExclusions: useScanExclusions,
                exclusionPatterns: exclusionPatterns
            ),
            didCompleteOnboarding: defaults.bool(forKey: Key.didCompleteOnboarding),
            onboardingPage: defaults.string(forKey: Key.onboardingPage)
                .flatMap(OnboardingPage.init(rawValue:)) ?? .welcome
        )
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        defaults.set(preferences.showHiddenFiles, forKey: Key.showHiddenFiles)
        defaults.set(preferences.treatPackagesAsDirectories, forKey: Key.treatPackagesAsDirectories)
        defaults.set(preferences.maxRenderedDepth, forKey: Key.maxRenderedDepth)
        defaults.set(preferences.autoSummarizeDirectories, forKey: Key.autoSummarizeDirectories)
        defaults.set(preferences.showFreeSpaceInDiskMaps, forKey: Key.showFreeSpaceInDiskMaps)
        defaults.set(preferences.visualizationMode.rawValue, forKey: Key.visualizationMode)
        defaults.set(preferences.useScanExclusions, forKey: Key.useScanExclusions)
        defaults.set(preferences.exclusionPatterns, forKey: Key.exclusionPatterns)
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: Key.didCompleteOnboarding)
    }

    func markOnboardingIncomplete() {
        defaults.set(false, forKey: Key.didCompleteOnboarding)
    }

    func saveOnboardingPage(_ page: OnboardingPage) {
        defaults.set(page.rawValue, forKey: Key.onboardingPage)
    }
}
