# Radix

A fast, native macOS disk space analyzer that helps you find where your storage is going. Scan any folder or volume, explore results with an interactive sunburst chart and file browser, and clean up — all without leaving the app.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

---

## Why Radix?

Storage fills up quietly. Radix makes it obvious where it went — no Terminal commands, no waiting through recursive scans that crawl forever. Point it at a folder, sit back, and explore a visual breakdown of every directory and file.

It's built from scratch in Swift and SwiftUI, designed to feel like a natural part of macOS.

## Features

### Fast, Respectful Scanning

- **Iterative file system traversal** — no recursion, no stack overflows, no hanging on deep `node_modules`
- **Real-time progress** with smooth, blended metrics so you actually know how far along things are
- **Auto-summarization** — directories with thousands of tiny files get collapsed into a single node, keeping scans fast and the UI clean
- **Read-only by default** — Radix scans and reports. It won't touch your files unless you explicitly ask it to.
- **Respects permissions** — works on ordinary folders without special privileges; warns you when protected paths (Mail, Safari, Messages) are skipped

### Visual Exploration

- **Sunburst chart** — a radial treemap that shows your disk usage at a glance. Hover any segment to see what it is, double-click to drill down.
- **File browser** — a sortable table with Name, Size, Kind, File Count, and Modified Date columns.
- **Smart search** — filter just the current folder, or search the entire scan tree.
- **Breadcrumb navigation** with back/forward history so you don't lose your place.

### Built for macOS

- **Native SwiftUI app** — no web views, no Electron, no churning your fans
- **Sidebar** with Smart Locations (Home, Desktop, Documents, Downloads, Library, Applications), mounted volumes, and recent scans
- **Inspector panel** showing detailed metadata: allocated vs. logical size, parent directory, access level, largest children
- **File actions** — Reveal in Finder, Open, Copy Path, Move to Trash, all from context menus or the inspector
- **Drag & drop** any folder into the window to scan it
- **Automatic updates** powered by [Sparkle](https://sparkle-project.org/)

### Privacy & Permissions

Radix works out of the box on any folder you can already access. For folders like `~/Library` or Mail data, macOS may require **Full Disk Access**. Radix detects when files are skipped due to permissions and guides you through enabling it in System Settings — one click, no guesswork.

## Requirements

- **macOS 26.0 (Tahoe)** or later
- **Xcode 26+** with Swift 6.0 toolchain (for building from source)

## Installation

### Download the Latest Release

Grab the latest release from the [Releases](https://github.com/colinvkim/radix/releases) page. Drag Radix into your Applications folder and you're done.

## Settings

Open **Radix > Settings** (or press `Cmd + ,`) to adjust:

| Setting                           | What It Does                                                                  |
| --------------------------------- | ----------------------------------------------------------------------------- |
| **Show hidden files**             | Include dotfiles and hidden folders in scans                                  |
| **Treat packages as directories** | Show `.app` bundles and other packages as expandable folders                  |
| **Auto-summarize directories**    | Collapse directories with many small files into a single node for performance |
| **Sunburst depth**                | How many rings to show in the sunburst chart (3–10, default 6)                |

## Building from Source

```bash
# Clone the repository
git clone https://github.com/colinvkim/radix.git
cd radix

# Build and run tests
swift test

# Open in Xcode for the full app
open Radix.xcodeproj
```

The `Package.swift` file contains the **RadixCore** library (scan engine, models, geometry, formatters). The full SwiftUI app is built through the Xcode project.

### Project Structure

```
Radix/
├── App/                  # App entry point, commands, window management
├── Models/               # Core data types (FileNode, ScanSnapshot, etc.)
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
- **ScanSnapshot** and **FileTreeIndex** provide immutable scan results with O(1) path lookups, structural sharing, and efficient tree updates.
- The **sunburst chart** is rendered using SwiftUI's Canvas API for performant drawing of hundreds of segments.
- No external Swift package dependencies — everything is built with Apple's frameworks.

## Contributing

Contributions are welcome. Here's how to get started:

1. Fork the repo and create a feature branch
2. Make your changes — keep them focused and well-documented
3. Run the tests: `swift test`
4. Open a pull request with a clear description of what changed and why

If you're tackling something big, consider opening an issue first to discuss the approach.

## License

MIT. See [LICENSE](LICENSE) for details.
