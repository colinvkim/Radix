// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RadixCore",
    platforms: [
        .macOS("26.0")
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
                "Services/SystemIntegration.swift",
                "Shared",
                "ViewModels",
                "Views"
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
