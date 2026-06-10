# Feature-Scoped Observation Plan

Last reviewed: 2026-06-10

## Purpose

Reduce broad workspace invalidation by narrowing what each SwiftUI feature observes.

This plan covers the remaining audit item:

- P2: Broad observable state causes avoidable workspace redraws.

This is a maintainability and performance refactor. It should be done deliberately, one feature boundary at a time, after the runtime fixes from the audit have settled.

## Current Baseline

Relevant files as of 2026-06-10:

- `Radix/ViewModels/AppModel.swift`
- `Radix/Services/ScanCoordinator.swift`
- `Radix/ViewModels/WorkspaceNavigationModel.swift`
- `Radix/ContentView.swift`
- `Radix/Features/Sidebar/SidebarView.swift`
- `Radix/Features/Workspace/WorkspaceView.swift`
- `Radix/Features/FileList/FileBrowserTableView.swift`
- `Radix/Features/Inspector/SelectionInspectorView.swift`
- `Radix/Features/Settings/SettingsView.swift`
- `Radix/Features/Onboarding/OnboardingView.swift`
- `RadixCoreTests/AppModelDependencyTests.swift`
- `RadixCoreTests/ScanCoordinatorTests.swift`
- `RadixCoreTests/WorkspaceNavigationModelTests.swift`

`AppModel` is currently the composition root and central action surface. It publishes or exposes:

- scan preferences
- sidebar targets and active sidebar target
- onboarding state
- full disk access state
- alert state
- pending trash state
- target capacity descriptions
- scan state through `ScanCoordinator`
- navigation state through `WorkspaceNavigationModel`
- app actions for scan, navigation, file actions, recent targets, Quick Look, and settings

Some narrowing already exists:

- `ScanCoordinator` owns scan phase, snapshot, file tree store, and progress.
- `ScanProgressState` narrows progress publishes.
- `WorkspaceNavigationModel` owns navigation behavior.
- Sidebar target sections are cached instead of recomputed in body.

The remaining issue is that many views still read `AppModel` through `@EnvironmentObject`, so unrelated publishes can invalidate views that only need a small subset of state.

## Goals

- Keep SwiftUI views observing the smallest state owner they need.
- Keep `AppModel` as the composition root until there is a clear reason to remove it.
- Preserve native SwiftUI data flow and view composition.
- Avoid introducing a heavy external architecture.
- Improve test boundaries around sidebar, settings, alerts/actions, and file actions.
- Keep commands injectable without forcing broad view reads.

## Non-Goals

- Do not rewrite Radix around Redux, TCA, MVVM ceremony, or custom event buses.
- Do not split every property just because it is possible.
- Do not change user-facing behavior during state ownership moves.
- Do not combine this with navigation-state atomicity or large file decomposition unless a small extraction is required.
- Do not remove `AppModel` in the first pass.

## Native SwiftUI Guardrails

This work should make Radix more native, not less:

- Use feature-scoped `ObservableObject` or Observation models.
- Let views own local UI state with `@State` when the state is view-local.
- Pass command structs or closures into feature views when that avoids broad environment reads.
- Keep `@EnvironmentObject` only for truly app-wide concerns or stable composition-root access.
- Keep AppKit bridges at actual macOS integration points such as Quick Look, Finder, windows, and permissions.

## Candidate State Owners

These are candidates, not a mandate to create all of them.

### Keep Existing Owners

- `ScanCoordinator`
  - scan lifecycle, phase, snapshot, file tree store, completed snapshot, scan errors, expansion state
- `ScanProgressState`
  - scan progress metrics
- `WorkspaceNavigationModel`
  - selection, focus, history, table content identity

### Possible New Owners

#### `SidebarModel`

Owns:

- smart targets
- recent scan targets
- active sidebar target ID
- target capacity descriptions
- recent target removal/clear actions, or delegates those actions to `AppModel`

Reasons:

- Sidebar rendering should not observe alert state, pending trash, settings sheets, or file actions.
- Sidebar target tests can move out of broad `AppModelDependencyTests`.

#### `PreferencesModel`

Owns:

- `showHiddenFiles`
- `treatPackagesAsDirectories`
- `maxRenderedDepth`
- `autoSummarizeDirectories`
- restore defaults
- persistence to `AppPreferencesPersisting`

Reasons:

- Settings UI should not observe scan snapshot changes.
- Scan option changes can publish through a narrow preferences owner.

#### `AppAlertModel` or `ActionPresentationModel`

Owns:

- current error alert message/title
- rescan availability for scan errors
- pending trash node
- confirmation-dialog state

Reasons:

- Alerts and dialogs are presentation state.
- Workspace/table/chart should not redraw because an alert title changes.

#### `FileActionCoordinator`

Owns or coordinates:

- selected-node file actions
- Quick Look
- reveal/open/copy/trash
- validation errors

Reasons:

- File actions use navigation state and system actions.
- This can keep platform integration testable without expanding view dependencies.

## Recommended Order

### Phase 1: Map View Dependencies

Create a simple dependency table before editing:

- `ContentView`
- `SidebarView`
- `WorkspaceDetailView`
- `WorkspaceView`
- `FileBrowserTableView`
- `SelectionInspectorView`
- `SettingsView`
- `OnboardingView`
- `RadixCommands`

For each view, list:

- state read for rendering
- commands invoked
- bindings required
- environment objects currently used

This prevents creating unnecessary models.

### Phase 2: Split Sidebar State First

Sidebar is the safest first split because recent/smart target state was already cached in `AppModel`.

Possible path:

1. Add `SidebarModel`.
2. Move smart/recent target section building into `SidebarModel`.
3. Keep `AppModel` responsible for starting scans, cache reuse, and scan option decisions.
4. Pass sidebar commands as closures or a small `SidebarActions` struct.
5. Update `SidebarView` to observe `SidebarModel` instead of broad `AppModel`.
6. Keep forwarding properties on `AppModel` temporarily if call sites need them.

Tests:

- Move `testSidebarTargetReadsUseCachedRecentAvailability`.
- Keep tests for mounted volume ordering.
- Keep tests for recent target filtering and removal.

### Phase 3: Split Preferences State

Preferences affect scan options and settings UI.

Possible path:

1. Add `PreferencesModel`.
2. Move preference properties and persistence into it.
3. Keep `AppModel.scanOptions(for:)` reading preferences through the model.
4. Update `SettingsView` to observe `PreferencesModel`.
5. Ensure preference changes still persist and affect rescans.

Tests:

- Existing preference persistence tests should move or be duplicated temporarily.
- Add a scan-options test showing `AppModel` reads the preferences model.

### Phase 4: Split Alert and Dialog Presentation

Alert/dialog state currently lives on `AppModel`.

Possible path:

1. Add a small presentation owner:
   - error title
   - error message
   - pending trash node
   - can rescan from alert
2. Keep action methods in `AppModel` initially.
3. Have actions set presentation state through the narrow owner.
4. Update `ContentView` to bind to this owner.

Tests:

- action failure presents expected error
- pending trash confirm/cancel behavior
- scan failure still offers rescan

### Phase 5: Revisit File Actions

Only do this if the earlier phases are successful and file-action coupling remains painful.

Possible path:

1. Define `FileActionCoordinator` with dependencies:
   - navigation model
   - scan coordinator or selected target
   - system actions
   - alert/presentation model
2. Move validation helpers from `AppModel` if they only serve file actions.
3. Keep public command closures stable for views.

Tests:

- reveal/open/copy/trash/Quick Look behavior
- unavailable selection behavior
- package contents hint behavior
- cleanup of Quick Look monitors

## Test Strategy

Run after each phase:

```bash
rtk swift test
```

Prefer moving existing tests with the state owner they validate. Do not delete broad integration tests until narrow tests cover the moved behavior.

Recommended test groups:

- Sidebar model tests
- Preferences model tests
- Alert/action presentation tests
- AppModel integration tests for command routing
- Existing scan/navigation tests unchanged unless ownership changes require it

## Manual QA

After each state-owner split:

- Launch the app.
- Start scans from sidebar, recent targets, open panel, and drag/drop.
- Change scan preferences and rescan.
- Trigger Full Disk Access flow.
- Trigger errors and dismiss alerts.
- Move an item to trash through the confirmation dialog if safe in a test folder.
- Use Quick Look, reveal, open, and copy path.
- Verify sidebar target availability and subtitles still update.

If available, use SwiftUI redraw diagnostics or Instruments before and after to confirm the split reduces invalidation.

## Risks

- Over-splitting state and making command flow harder to understand.
- Accidentally creating two sources of truth.
- Breaking preference persistence by moving property observers.
- Making previews or tests more complex.
- Passing too many closures into views.

## Mitigations

- Keep `AppModel` as composition root during the refactor.
- Move one feature boundary per commit.
- Keep forwarding APIs during migration.
- Name owners by product feature, not implementation pattern.
- Avoid adding owners that do not reduce a real observation or testing problem.

## Done Criteria

This work is done when:

- High-traffic workspace views no longer observe broad alert/settings/sidebar state.
- Settings does not observe scan snapshots or navigation.
- Sidebar does not observe file-action or alert state.
- Tests for moved behavior live near the new owner.
- `AppModel` reads as composition and command coordination rather than a bag of unrelated published state.

## Future Re-Verification Checklist

Before starting this later, re-check:

- Which views still use `@EnvironmentObject AppModel`.
- Whether Swift Observation has been adopted.
- Whether new features added state to `AppModel`.
- Whether existing tests already narrowed ownership.
- Whether redraw performance is still a measured problem or mostly a maintainability concern.
