// swift-tools-version: 6.2

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
                "InfoPlist.xcstrings",
                "Info.plist",
                "Interface.xcstrings",
                "Localizable.xcstrings",
                "RadixApp.swift",
                "Shared"
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RadixCoreTests",
            dependencies: ["RadixCore"],
            path: "RadixCoreTests"
        )
    ]
)
