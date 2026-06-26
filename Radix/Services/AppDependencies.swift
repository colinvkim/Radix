//
//  AppDependencies.swift
//  Radix
//

import Foundation

@MainActor
struct AppDependencies {
    var preferences: any AppPreferencesPersisting
    var recentTargets: RecentTargetStore
    var systemActions: AppSystemActions
    var scanService: any ScanEventStreaming
    var scanArchiveService: any ScanArchiveServicing

    init(
        preferences: any AppPreferencesPersisting,
        recentTargets: RecentTargetStore,
        systemActions: AppSystemActions,
        scanService: any ScanEventStreaming = ScanEngine(),
        scanArchiveService: any ScanArchiveServicing = ScanArchiveService()
    ) {
        self.preferences = preferences
        self.recentTargets = recentTargets
        self.systemActions = systemActions
        self.scanService = scanService
        self.scanArchiveService = scanArchiveService
    }

    static var live: AppDependencies {
        let systemActions = AppSystemActions.live
        return AppDependencies(
            preferences: UserDefaultsAppPreferencesStore(),
            recentTargets: RecentTargetStore(
                persistence: UserDefaultsRecentTargetPersistence(),
                isAvailable: { target in
                    systemActions.isExistingDirectory(target.url)
                }
            ),
            systemActions: systemActions,
            scanService: ScanEngine()
        )
    }
}
