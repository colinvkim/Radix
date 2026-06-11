# SwiftUI File Decomposition Plan

Last reviewed: 2026-06-11

## Purpose

Reduce the maintenance cost of large SwiftUI files without changing behavior or making the app less native.

This plan covers the remaining audit item:

- P3: Large SwiftUI files remain concentrated.

This should be the last refactor in the audit follow-up set. It is valuable, but it should stay behavior-neutral and should not obscure runtime fixes.

## Current Baseline

Large files as of 2026-06-10:

- `Radix/Features/Workspace/WorkspaceView.swift`: 678 lines
- `Radix/Features/Visualization/SunburstChartView.swift`: 480 lines
- `Radix/Features/FileList/FileBrowserTableView.swift`: 435 lines
- `Radix/Features/Inspector/SelectionInspectorView.swift`: 384 lines

These files mix some combination of:

- layout
- local interaction state
- command wiring
- formatting
- table/chart/inspector row composition
- AppKit bridges where needed
- feature-specific helper views

The size is not itself a bug. The goal is to extract stable, meaningful boundaries only where it makes future behavior fixes safer.

## Goals

- Keep all UI native SwiftUI unless a real macOS bridge is required.
- Make future changes easier to review and test.
- Extract repeated or conceptually separate UI sections into small `View` structs.
- Keep behavior, layout, accessibility labels, keyboard behavior, and commands unchanged.
- Use small commits that are easy to revert.

## Non-Goals

- Do not redesign the UI.
- Do not change app architecture while decomposing files.
- Do not introduce presenters or controllers for pure SwiftUI layout.
- Do not move state to new view models unless state ownership is already part of a separate plan.
- Do not chase arbitrary file length targets.

## Native SwiftUI Guardrails

Good extractions:

- small `View` structs
- `ViewModifier` for repeated styling
- local helper types in the same feature folder
- command structs already used by the feature
- AppKit representables only for real platform integration

Avoid:

- non-SwiftUI presenter objects for simple layout
- generic abstractions that hide what the view renders
- helper names that describe implementation rather than product UI
- extracting one-off `HStack` or `VStack` blocks without a domain name
- moving local state upward just to make extraction compile

## Recommended Order

Do this after the navigation-state and feature-scoped observation plans, or at least after deciding not to do them soon. Decomposition is safest when state ownership is stable.

Recommended order:

1. `SelectionInspectorView`
2. `FileBrowserTableView`
3. `WorkspaceView`
4. `SunburstChartView`

Rationale:

- Inspector sections are usually easiest to extract without changing behavior.
- File browser has table commands and cells that can be separated carefully.
- Workspace view coordinates several major surfaces, so extraction should wait until command/state boundaries are clear.
- Sunburst chart has rendering and interaction logic where accidental behavior changes are easier to miss.

Completed slices:

- `SelectionInspectorView`: extracted stable inspector sections and empty-state composition.
- `FileBrowserTableView`: extracted the search/filter bar, table name cell, and summarized-folder expansion button. Row commands and context menu logic remain in `FileBrowserTableView`.
- `WorkspaceView`: extracted split-pane resizing, header metrics, and permission banner helpers.

## Plan For SelectionInspectorView

Likely extraction candidates:

- selection summary/header
- storage size/details section
- access/status section
- file action buttons
- warnings or special synthetic-node explanations

Suggested files:

- `Radix/Features/Inspector/InspectorSummarySection.swift`
- `Radix/Features/Inspector/InspectorStorageSection.swift`
- `Radix/Features/Inspector/InspectorActionsSection.swift`

Keep these private to the feature unless another feature truly needs them.

Testing:

- Existing tests likely cover model/action behavior rather than view layout.
- Run `rtk swift test`.
- Manually select:
  - a normal file
  - a directory
  - an inaccessible node
  - a synthetic/system node
  - an auto-summarized node

Review focus:

- no action button enables/disables differently
- no explanatory text changes unless intentionally updated
- no environment dependencies added to child sections unnecessarily

## Plan For FileBrowserTableView

Likely extraction candidates:

- search/filter bar
- table row name cell
- summarized expansion button
- context menu commands
- table column definitions, if the extraction stays readable

Possible files:

- `Radix/Features/FileList/FileBrowserSearchFilterBar.swift`
- `Radix/Features/FileList/FileBrowserNameCell.swift`
- `Radix/Features/FileList/FileBrowserRowCommands.swift`

Be careful with:

- `@StateObject` ownership of `FileBrowserModel`
- search lifecycle tied to content identity
- selection binding
- sort order binding
- active expansion state
- environment object usage for actions

Testing:

- Run `rtk swift test`.
- Verify file-browser tests still cover search lifecycle and display-state behavior.
- Manually test:
  - current contents filtering
  - entire scan search
  - sorting
  - context menu actions
  - double-click primary action
  - summarized-folder expansion from all entry points

Review focus:

- extracted command helpers should not duplicate selection validation logic
- search state should stay owned by `FileBrowserModel`
- table refresh should still be driven by content/snapshot identity

## Plan For WorkspaceView

Likely extraction candidates:

- empty/idle workspace state
- scan progress area
- workspace toolbar/control strip
- drop target overlay
- main visualization/table split composition
- resizable split behavior, if currently mixed with layout

Possible files:

- `Radix/Features/Workspace/WorkspaceEmptyStateView.swift`
- `Radix/Features/Workspace/WorkspaceScanControls.swift`
- `Radix/Features/Workspace/WorkspaceDropOverlay.swift`
- `Radix/Features/Workspace/WorkspaceMainContentView.swift`

Be careful with:

- drag/drop behavior
- scan start/stop/rescan commands
- progress observation
- split view sizing
- chart/table/inspector coordination
- window-toolbar styling

Testing:

- Run `rtk swift test`.
- Manually test:
  - initial empty workspace
  - drag/drop folder scan
  - open panel scan
  - stop scan
  - rescan
  - failed scan alert path
  - chart selection updates table and inspector

Review focus:

- command closures should remain easy to trace
- no new broad environment reads should be introduced
- layout should remain macOS-native and not become card-like or marketing-style

## Plan For SunburstChartView

Likely extraction candidates:

- chart overlay/status view
- hover tooltip
- center label
- legend or depth controls if present
- AppKit tracking representable, if separable without changing behavior

Possible files:

- `Radix/Features/Visualization/SunburstChartOverlay.swift`
- `Radix/Features/Visualization/SunburstHoverTooltip.swift`
- `Radix/Features/Visualization/SunburstTrackingView.swift`

Be careful with:

- hit testing
- hover state
- click and double-click semantics
- layout task cancellation
- selected ancestor overlays
- accessibility labels

Testing:

- Run `rtk swift test`.
- Ensure `SunburstChartModelTests` and `SunburstGeometryTests` still pass.
- Manually test:
  - hover
  - click selection
  - double-click focus/zoom if supported
  - resizing window
  - changing max rendered depth
  - selecting from table and seeing chart update

Review focus:

- do not split geometry logic into view files
- keep rendering state and layout model boundaries intact
- avoid introducing animation or visual changes during decomposition

## Commit Strategy

Use one small commit per extraction boundary.

Examples:

- `refactor(inspector): extract storage section`
- `refactor(table): extract search bar`
- `refactor(workspace): extract drop overlay`
- `refactor(chart): extract hover tooltip`

Each commit should:

- move code only
- keep names domain-specific
- run `rtk swift test`
- avoid formatting unrelated regions
- avoid mixing behavior changes with decomposition

## Testing Plan

After each commit:

```bash
rtk swift test
```

Because these are mostly view extractions, also do manual smoke tests. Automated package tests will not catch every SwiftUI layout or interaction regression.

Suggested final manual sweep:

- launch app
- scan a folder
- navigate with chart and table
- select files/directories
- open inspector actions
- run entire-scan search
- expand summarized folders
- change settings
- resize window
- toggle inspector/sidebar if applicable

## Review Checklist

For every extraction:

- Did any state owner change?
- Did any command closure change behavior?
- Did any view start observing a broader object than before?
- Did any button label, shortcut, accessibility label, or disabled state change?
- Did layout spacing, alignment, or column width change unintentionally?
- Did preview or package target membership need updating?
- Does the extracted name describe product UI rather than implementation?

## Risks

- Accidental UI behavior changes hidden in a large move.
- New child views requiring too many parameters.
- Moving local state to the wrong owner.
- Increased environment-object coupling.
- Harder code navigation if too many tiny files are created.

## Mitigations

- Extract only one clear UI section at a time.
- Keep child views private or feature-internal unless reused.
- Do not extract if the parameter list is a warning sign that state ownership should be addressed first.
- Prefer leaving a large file alone over creating unclear abstractions.
- Use manual QA for interactions after package tests pass.

## Done Criteria

This work is done when:

- Each extracted file has a clear feature/domain purpose.
- The original large files read as high-level composition.
- No behavior changes were bundled into decomposition commits.
- Tests pass after every extraction.
- Manual smoke testing shows table, chart, workspace, and inspector still coordinate correctly.

## Future Re-Verification Checklist

Before starting this later, re-check:

- Current file sizes and responsibilities.
- Whether navigation state has been made atomic.
- Whether feature-scoped observation has changed dependencies.
- Whether any of the suggested extraction files already exist.
- Whether new UI features created better extraction boundaries.
