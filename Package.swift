// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RadixCore",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "RadixCore",
            targets: ["RadixCore"]
        )
    ],
    targets: [
        .target(
            name: "RadixCore",
            path: "Radix",
            exclude: [
                "App",
                "AppIcon.icon",
                "Assets.xcassets",
                "ContentView.swift",
                "Features",
                "Info.plist",
                "RadixApp.swift",
                "Shared",
                "Views"
            ],
            sources: [
                "Models/FileNodeActions.swift",
                "Models/FileNodeRecord.swift",
                "Models/FileTreeStore.swift",
                "Models/ScanProgress.swift",
                "Models/ScanSnapshot.swift",
                "Models/ScanTarget.swift",
                "Models/TrashSafetyPolicy.swift",
                "Services/AtomicDirectorySummarizer.swift",
                "Services/AppDependencies.swift",
                "Services/AppPreferencesStore.swift",
                "Services/AppSystemActions.swift",
                "Services/FileBrowserModel.swift",
                "Services/FileSizeFormatter.swift",
                "Services/HardLinkDeduplicator.swift",
                "Services/QuickLookIntegration.swift",
                "Services/RecentTargetStore.swift",
                "Services/ScanDiagnostics.swift",
                "Services/ScanCoordinator.swift",
                "Services/ScanEngine.swift",
                "Services/ScanExclusionMatcher.swift",
                "Services/ScanMetadataLoader.swift",
                "Services/ScanSnapshotTransformService.swift",
                "Services/SunburstChartModel.swift",
                "Services/SunburstGeometry.swift",
                "Services/SystemIntegration.swift",
                "ViewModels/AppModel.swift",
                "ViewModels/SidebarModel.swift",
                "ViewModels/WorkspaceNavigationModel.swift"
            ]
        ),
        .testTarget(
            name: "RadixCoreTests",
            dependencies: ["RadixCore"],
            path: "RadixCoreTests"
        )
    ]
)
