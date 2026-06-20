//
//  AppPreferencesStore.swift
//  Radix
//

import Foundation

struct AppScanPreferences: Equatable {
    var showHiddenFiles: Bool
    var treatPackagesAsDirectories: Bool
    var maxRenderedDepth: Int
    var autoSummarizeDirectories: Bool
    var showFreeSpaceInSunburst: Bool
    var scanCloudStorageFolders: Bool
    var useScanExclusions: Bool
    var exclusionPatterns: [String]

    static let defaults = AppScanPreferences(
        showHiddenFiles: true,
        treatPackagesAsDirectories: false,
        maxRenderedDepth: 6,
        autoSummarizeDirectories: true,
        showFreeSpaceInSunburst: false,
        scanCloudStorageFolders: false,
        useScanExclusions: false,
        exclusionPatterns: ScanExclusionMatcher.commonPresetPatterns
    )
}

struct AppPreferences: Equatable {
    var scan: AppScanPreferences
    var didCompleteOnboarding: Bool

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
}

final class UserDefaultsAppPreferencesStore: AppPreferencesPersisting {
    private enum Key {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let showHiddenFiles = "showHiddenFiles"
        static let treatPackagesAsDirectories = "treatPackagesAsDirectories"
        static let maxRenderedDepth = "maxRenderedDepth"
        static let autoSummarizeDirectories = "autoSummarizeDirectories"
        static let showFreeSpaceInSunburst = "showFreeSpaceInSunburst"
        static let scanCloudStorageFolders = "scanCloudStorageFolders"
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

        let scanCloudStorageFolders: Bool
        if defaults.object(forKey: Key.scanCloudStorageFolders) == nil {
            scanCloudStorageFolders = AppScanPreferences.defaults.scanCloudStorageFolders
        } else {
            scanCloudStorageFolders = defaults.bool(forKey: Key.scanCloudStorageFolders)
        }

        let showFreeSpaceInSunburst: Bool
        if defaults.object(forKey: Key.showFreeSpaceInSunburst) == nil {
            showFreeSpaceInSunburst = AppScanPreferences.defaults.showFreeSpaceInSunburst
        } else {
            showFreeSpaceInSunburst = defaults.bool(forKey: Key.showFreeSpaceInSunburst)
        }

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
                showFreeSpaceInSunburst: showFreeSpaceInSunburst,
                scanCloudStorageFolders: scanCloudStorageFolders,
                useScanExclusions: useScanExclusions,
                exclusionPatterns: exclusionPatterns
            ),
            didCompleteOnboarding: defaults.bool(forKey: Key.didCompleteOnboarding)
        )
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        defaults.set(preferences.showHiddenFiles, forKey: Key.showHiddenFiles)
        defaults.set(preferences.treatPackagesAsDirectories, forKey: Key.treatPackagesAsDirectories)
        defaults.set(preferences.maxRenderedDepth, forKey: Key.maxRenderedDepth)
        defaults.set(preferences.autoSummarizeDirectories, forKey: Key.autoSummarizeDirectories)
        defaults.set(preferences.showFreeSpaceInSunburst, forKey: Key.showFreeSpaceInSunburst)
        defaults.set(preferences.scanCloudStorageFolders, forKey: Key.scanCloudStorageFolders)
        defaults.set(preferences.useScanExclusions, forKey: Key.useScanExclusions)
        defaults.set(preferences.exclusionPatterns, forKey: Key.exclusionPatterns)
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: Key.didCompleteOnboarding)
    }

    func markOnboardingIncomplete() {
        defaults.set(false, forKey: Key.didCompleteOnboarding)
    }
}
