import Foundation

@MainActor
struct AppDependencies {
    var preferences: any AppPreferencesPersisting
    var recentTargets: RecentTargetStore
    var systemActions: AppSystemActions
    var scanService: any ScanEventStreaming
    var fileSystemChangeWatcher: any FileSystemChangeWatching
    var folderRefreshClock: FolderRefreshClock
    var scanArchiveService: any ScanArchiveServicing
    var usageStats: any AppUsageStatsPersisting

    init(
        preferences: any AppPreferencesPersisting,
        recentTargets: RecentTargetStore,
        systemActions: AppSystemActions,
        scanService: any ScanEventStreaming = IncrementalScanService(),
        fileSystemChangeWatcher: any FileSystemChangeWatching = DarwinFileSystemChangeWatcher(),
        scanArchiveService: any ScanArchiveServicing = ScanArchiveService(),
        usageStats: any AppUsageStatsPersisting = InMemoryAppUsageStatsStore(),
        folderRefreshClock: FolderRefreshClock = .continuous
    ) {
        self.preferences = preferences
        self.recentTargets = recentTargets
        self.systemActions = systemActions
        self.scanService = scanService
        self.fileSystemChangeWatcher = fileSystemChangeWatcher
        self.folderRefreshClock = folderRefreshClock
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
            scanService: IncrementalScanService(),
            usageStats: UserDefaultsAppUsageStatsStore()
        )
    }
}
