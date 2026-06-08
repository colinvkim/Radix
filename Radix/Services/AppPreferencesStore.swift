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

    static let defaults = AppScanPreferences(
        showHiddenFiles: true,
        treatPackagesAsDirectories: false,
        maxRenderedDepth: 6,
        autoSummarizeDirectories: true
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

        return AppPreferences(
            scan: AppScanPreferences(
                showHiddenFiles: showHiddenFiles,
                treatPackagesAsDirectories: defaults.bool(forKey: Key.treatPackagesAsDirectories),
                maxRenderedDepth: maxRenderedDepth,
                autoSummarizeDirectories: autoSummarizeDirectories
            ),
            didCompleteOnboarding: defaults.bool(forKey: Key.didCompleteOnboarding)
        )
    }

    func saveScanPreferences(_ preferences: AppScanPreferences) {
        defaults.set(preferences.showHiddenFiles, forKey: Key.showHiddenFiles)
        defaults.set(preferences.treatPackagesAsDirectories, forKey: Key.treatPackagesAsDirectories)
        defaults.set(preferences.maxRenderedDepth, forKey: Key.maxRenderedDepth)
        defaults.set(preferences.autoSummarizeDirectories, forKey: Key.autoSummarizeDirectories)
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: Key.didCompleteOnboarding)
    }

    func markOnboardingIncomplete() {
        defaults.set(false, forKey: Key.didCompleteOnboarding)
    }
}
