// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RadixCore",
    platforms: [
        .macOS(.v14)
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
                "Assets.xcassets",
                "ContentView.swift",
                "RadixApp.swift",
                "Services/SystemIntegration.swift",
                "ViewModels",
                "Views/FileBrowserTableView.swift",
                "Views/InspectorSidebarView.swift",
                "Views/OnboardingView.swift",
                "Views/SettingsView.swift",
                "Views/SunburstChartView.swift"
            ],
            sources: [
                "Models/ScanModels.swift",
                "Services/FileSizeFormatter.swift",
                "Services/ScanEngine.swift",
                "Services/SunburstGeometry.swift"
            ]
        ),
        .testTarget(
            name: "RadixCoreTests",
            dependencies: ["RadixCore"],
            path: "RadixCoreTests"
        )
    ]
)
