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
    var usageStats: any AppUsageStatsPersisting

    init(
        preferences: any AppPreferencesPersisting,
        recentTargets: RecentTargetStore,
        systemActions: AppSystemActions,
        scanService: any ScanEventStreaming = ScanEngine(),
        scanArchiveService: any ScanArchiveServicing = ScanArchiveService(),
        usageStats: any AppUsageStatsPersisting = InMemoryAppUsageStatsStore()
    ) {
        self.preferences = preferences
        self.recentTargets = recentTargets
        self.systemActions = systemActions
        self.scanService = scanService
        self.scanArchiveService = scanArchiveService
        self.usageStats = usageStats
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
            scanService: ScanEngine(),
            usageStats: UserDefaultsAppUsageStatsStore()
        )
    }
}
