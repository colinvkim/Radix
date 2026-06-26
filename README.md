<p align="center">
    <img src="./icon.png" alt="Radix" width="220">
</p>

# Radix

A fast, native macOS disk space analyzer that helps you find where your storage is going. Scan any folder or volume, explore results with an interactive sunburst chart and file browser, and clean up — all without leaving the app. Take a look at [Radix's beautiful website](https://radix.colinkim.dev)!

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Why Radix?

Storage fills up quietly. Radix makes it obvious where it went — no Terminal commands, no waiting through recursive scans that crawl forever. Point it at a folder, sit back, and explore a visual breakdown of every directory and file.

It's built from scratch in Swift and SwiftUI, designed to feel like a natural part of macOS.

## Features

### Scanning

- **Iterative file system traversal**
- **Real-time progress** with smooth, blended metrics so you know how far along things are
- **Auto-summarization** — directories with thousands of tiny files get collapsed into a single node
- **Respects permissions** — works on ordinary folders without special privileges; warns you when protected paths (Mail, Safari, Messages) are skipped

### Visual Exploration

- **Sunburst chart** — a radial treemap that shows your disk usage at a glance. Hover any segment to see what it is, double-click to drill down.
- **File browser** — a sortable table with informative columns.
- **Smart search** — filter just the current folder, or search the entire scan tree.
- **Breadcrumb navigation** with back/forward history so you don't lose your place.

### Built for macOS

- **Native SwiftUI app**
- **Sidebar** with Smart Locations (Macintosh HD, mounted volumes, Home, Desktop, Documents, Downloads, Library, Applications) and recent scans
- **Inspector panel** showing detailed metadata: allocated vs. logical size, parent directory, access level, largest children
- **File actions** — Reveal in Finder, Open, Copy Path, Move to Trash, all from context menus or the inspector
- **Snapshot import/export** — save completed scans as `.radixscan` packages and reopen them later as read-only snapshots
- **Drag & drop** any folder into the window to scan it
- **Automatic updates** powered by [Sparkle](https://sparkle-project.org/)

### Privacy & Permissions

Radix works out of the box on any folder you can already access. For folders like `~/Library` or Mail data, macOS may require **Full Disk Access**. Radix detects when files are skipped due to permissions and guides you through enabling it in System Settings.

## Requirements

- **macOS Sonoma 14** or later
- **Xcode 26+** with Swift 6.0 toolchain (for building from source)

## Installation

### Homebrew

```bash
brew install --cask radix
```

<details>
<summary>Click here to read a quick note of gratitude from me</summary>

When people began asking me to get Radix on Homebrew, I never imagined we'd get there so quickly. We only had half of the required stars, and I thought it might take a while before the project was ready.

But here we are now. Radix is on Homebrew, and it's because of your incredible support. Thank you for all the stars, comments, and feedback. Moreover, thank you for giving Radix a chance. I am so, so grateful for the positive feedback you all have given me.

I'm excited to continue improving Radix. Please keep the feedback coming, and thank you again!

</details>

### Download the Latest Release

Grab the latest release from the [Releases](https://github.com/colinvkim/Radix/releases) page, then drag Radix into your Applications folder.

## Building from Source

```bash
# Clone the repository
git clone https://github.com/colinvkim/Radix.git
cd radix

# Build and run package tests
swift test

# Open in Xcode for the full app
open Radix.xcodeproj
```

The `Package.swift` file contains the **RadixCore** library (scan engine, models, geometry, formatters) and has no external package dependencies. The full SwiftUI app is built through the Xcode project, which integrates Sparkle through Xcode's Swift Package Manager support.
Use SwiftPM for the package test suite and Xcode for the app build:

```bash
swift test
xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination 'platform=macOS' build
```

The shared `Radix` app scheme is not configured with an Xcode test action because the tests belong to the SwiftPM `RadixCoreTests` target.

### Project Structure

```
Radix/
├── App/                  # App entry point, commands, window management
├── Models/               # Core data types (FileNodeRecord, ScanSnapshot, etc.)
├── Services/             # Scan engine, sunburst geometry, formatters
├── ViewModels/           # AppModel — central state manager
├── Features/             # UI features (workspace, sidebar, file browser,
│   ├── Workspace/        #   visualization, inspector, settings, onboarding)
│   ├── Sidebar/
│   ├── FileList/
│   ├── Visualization/
│   ├── Inspector/
│   ├── Settings/
│   └── Onboarding/
└── Shared/               # Reusable components (breadcrumbs, helpers)
```

## Architecture Notes

- **ScanEngine** is an actor-based async scanner that uses iterative (not recursive) filesystem traversal for safety and performance.
- **AppModel** is the single source of truth — a `@MainActor` observable object that drives the entire UI.
- **ScanSnapshot** and **FileTreeStore** provide immutable scan results with O(1) path lookups, flat tree storage, and efficient subtree updates.
- The **sunburst chart** is rendered using SwiftUI's Canvas API for performant drawing of hundreds of segments.
- **RadixCore** has no external Swift package dependencies; the Xcode app target adds Sparkle for automatic updates.

## Contributing

Contributions are welcome. Here's how to get started:

1. Fork the repo and create a feature branch
2. Make your changes — keep them focused and well-documented
3. Run the tests: `swift test`
4. Open a pull request with a clear description of what changed and why

If you're tackling something big, consider opening an issue first to discuss the approach.

## License

MIT. See [LICENSE](LICENSE) for details.
