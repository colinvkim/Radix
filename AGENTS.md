# AGENTS.md

This file tells coding agents how to work effectively in this repository.

## Purpose

Radix is a native macOS disk space analyzer built in Swift and SwiftUI. When developing Radix, prioritize Swift/SwiftUI best practices and modern code.

## Commit Guidelines

- Make small, focused commits
- Each commit should represent a single logical change
- Avoid mixing refactors with behavior changes
- Use Conventional Commits:
  - `fix: correct size totals for nested directories`
  - `feat: remember last opened scan location`
  - `perf: cache formatted file sizes in file list rows`
  - `refactor: remove unused scan coordination code`

## Environment Facts

- Repository root: `Radix/`
- Swift 6
- macOS target: macOS Tahoe 26.0+
- App UI framework: SwiftUI (always preferred over UIKit/AppKit)
- Tests: `RadixCoreTests/`

## Project Structure

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

## Project Layout

Important paths:

- `README.md`: product intent, feature summary, high-level architecture
- `Package.swift`: exact package target membership
- `Radix/RadixApp.swift`: app entry
- `Radix/ContentView.swift`: root content composition
- `Radix/ViewModels/AppModel.swift`: central `@MainActor` app state and UI coordination
- `Radix/Models/ScanModels.swift`: core scan data types and indexing
- `Radix/Services/ScanEngine.swift`: actor-based filesystem scanner
- `Radix/Services/SunburstGeometry.swift`: sunburst layout math
- `Radix/Services/SystemIntegration.swift`: Finder/open/trash/system-facing actions
- `Radix/Shared/`: shared UI helpers
- `RadixCoreTests/`: package-level unit and benchmark-style tests
- `releases/`: release/update assets
- `Sparkle-2.9.1/`: Sparkle vendored artifacts

## Product Constraints

Radix makes several user-facing promises. Do not casually violate them:

- Scans should feel fast and responsive.
- The app should not mutate files unless the user explicitly requests an action.
- The sunburst and file browser are primary navigation surfaces, not secondary embellishments.

## Working Agreement For Changes

When making changes:

- Keep edits consistent with the existing architecture unless existing architecture is problematic.
- Prefer fixing behavior in the core model/service layer when the bug is data-related.
- Prefer fixing behavior in `AppModel` when the issue is coordination, selection, focus, navigation, or settings persistence.
- Prefer adding or updating tests when changing scanner behavior, path normalization, indexing, geometry, or formatting logic.
- Avoid introducing new dependencies unless explicitly justified. The project is intentionally light on external packages.

Use Context7 when working with external libraries, frameworks, or APIs and you need current, version-aware documentation.

Prefer Context7 for:

- SwiftUI or Apple framework usage where exact modern APIs matter
- Cases where examples from memory may be outdated

Do not use Context7 for:

- Understanding this repository’s internal architecture
- Answering questions already resolved by local code, tests, or README
- Simple edits that can be completed by following existing patterns in the codebase

## If You Need A Starting Point

- Scanner bug or data bug: start with `Radix/Services/ScanEngine.swift` and the matching tests in `RadixCoreTests/`
- Selection/navigation/UI state bug: start with `Radix/ViewModels/AppModel.swift`
- Tree/index/search behavior bug: start with `Radix/Models/ScanModels.swift`
- Size or display formatting bug: start with `Radix/Services/FileSizeFormatter.swift`
- Visualization/layout bug: start with `Radix/Services/SunburstGeometry.swift`
