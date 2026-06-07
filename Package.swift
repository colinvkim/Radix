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
                "Models/ScanModels.swift",
                "Services/AppDependencies.swift",
                "Services/AppPreferencesStore.swift",
                "Services/AppSystemActions.swift",
                "Services/FileBrowserModel.swift",
                "Services/FileSizeFormatter.swift",
                "Services/QuickLookIntegration.swift",
                "Services/RecentTargetStore.swift",
                "Services/ScanCoordinator.swift",
                "Services/ScanEngine.swift",
                "Services/SunburstChartModel.swift",
                "Services/SunburstGeometry.swift",
                "Services/SystemIntegration.swift",
                "ViewModels/AppModel.swift",
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
