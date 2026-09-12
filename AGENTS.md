# AGENTS.md

## Radix

Radix is a native macOS 14+ disk-space analyzer built with Swift 6.2,
SwiftUI, and Xcode 26+.

## Architecture and task routing

- Scanning and rescans: `Radix/Services/ScanEngine.swift`,
  `ScanCoordinator.swift`, and `IncrementalScanService.swift`
- Tree and indexing: `Radix/Models/FileTreeStore.swift`
- App coordination: `Radix/ViewModels/AppModel.swift`; keep feature state and
  behavior in the dedicated owners below
- Navigation, focus, and selection: `Radix/ViewModels/WorkspaceNavigationModel.swift`
- Sidebar targets: `Radix/ViewModels/SidebarModel.swift`; scan caching and
  target restoration: `Radix/ViewModels/SidebarScanCacheController.swift`
- Modal presentation: `Radix/ViewModels/AppPresentationCoordinator.swift`
- Archive I/O: `Radix/Services/ScanArchiveService.swift`; operation progress
  and cancellation: `Radix/ViewModels/ArchiveWorkflowCoordinator.swift`
- Comparison calculations: `Radix/Services/ScanComparisonService.swift`;
  setup and preview state: `Radix/ViewModels/ComparisonFlowController.swift`;
  results browsing: `Radix/ViewModels/ScanComparisonBrowserModel.swift`
- Trash and discard-pile workflow: `Radix/ViewModels/TrashFlowController.swift`;
  safety rules: `Radix/Models/TrashSafetyPolicy.swift`
- File-browser search and sorting: `Radix/Services/FileBrowserModel.swift`
  and the adjacent `FileBrowser*` services
- Sunburst or treemap layout: the corresponding geometry/chart model in
  `Radix/Services/`; layout requests: `ChartLayoutRequestCoordinator.swift`
- Quick Look coordination: `Radix/ViewModels/AppQuickLookController.swift`;
  native integration: `Radix/Services/QuickLookIntegration.swift`
- Feature UI: `Radix/Features/`; reusable UI: `Radix/Shared/`;
  menu commands: `Radix/App/RadixCommands.swift`
- Swift Testing core and integration tests: `RadixCoreTests/`; commands and
  conventions: `docs/testing.md`

`Package.swift` defines the non-UI `RadixCore` target. When adding or moving a
non-UI Swift file, update its explicit source list. The Xcode project builds
the complete app.

## Change guidelines

- Add new user-facing text to the appropriate `.xcstrings` catalog for every
  supported locale: `en`, `de`, `es`, `fr`, `it`, and `zh-Hans`.
- Avoid new dependencies unless clearly justified. `RadixCore` has none.
- Sparkle is managed through Xcode Swift Package Manager; never vendor it.
- Use current documentation for version-sensitive Apple or external APIs.
- Prefer SwiftUI for UI. Use AppKit when it provides a simpler or more reliable implementation of required macOS behavior, or when measurements justify it for performance.
- Scanning must remain safe and responsive. Modifying or removing scanned files requires explicit user action.

## Validation

Choose validation based on the change:

- Production code, app resources, or build configuration: run the core
  tests and build the complete app.
- Test-only changes: run the affected tests. Run the full core suite
  when changing shared fixtures or test infrastructure.
- UI behavior changes: also manually exercise the affected interaction
  using this checkout's exact Debug bundle.
- Documentation-only changes: verify changed paths and commands and
  check the diff for formatting errors. Builds and tests are not required.
- Performance changes: run relevant benchmarks when practical.

Core test command:

    swift test

App build command:

    xcodebuild -project Radix.xcodeproj -scheme Radix \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath .build/xcode-derived-data build

For routine manual testing with Computer Use:

- Stop any other running Radix instances, then launch this checkout's exact
  Debug bundle:

      open -n .build/xcode-derived-data/Build/Products/Debug/Radix.app

- Use the full absolute path to that bundle for every Computer Use `app`
  argument. Require exactly one running Radix instance before testing; the
  `open -n` command deliberately starts a new instance.
- Never target the app as `Radix` or `com.colinkim.Radix`. Installed, archived,
  release, and DerivedData builds share that identity, so generic lookup can
  launch the wrong copy, including `/Applications/Radix.app`.

When the test specifically requires LLDB, scheme launch arguments, sanitizers,
or other Xcode diagnostics, start the shared scheme from the command line:

    xed -b Radix.xcodeproj
    xcrun xcdebug -s Radix -B -b

`xcdebug -B` performs the scheme's Build and Run action and attaches Xcode's
debugger; the `-b` options leave Xcode in the background.

## Simplicity and Code Economy

- Prefer the smallest coherent implementation that preserves correctness, clarity, and performance.
- Consolidate mechanisms that enforce the same invariant, not those with merely similar shapes.
- Before finishing, review the diff and touched code for redundant state, branches, abstractions, repeated work, duplicate tests, and opportunities to simplify data flow.
- In performance-sensitive paths, look for repeated traversal, allocation, I/O, or main-actor work. Measure meaningful performance changes when practical.
