# Radix Audit Fix Guide

This is the working checklist for addressing the audit findings. It is ordered
for implementation risk: small isolated fixes first, then core invariants,
performance/state work, SwiftUI architecture, and cleanup.

## Agent Rules

- Prefix shell commands with `rtk`.
- Start each task with `rtk git status --short`; do not revert unrelated user
  changes.
- Work in order by default. If you change order, add a short note under the
  task explaining why.
- Verify the finding before editing. If the code has changed and the finding no
  longer applies, check it off with a short note.
- Keep each patch focused on one checklist item or one tightly coupled group.
- Add or update focused tests when behavior, data invariants, scanner logic, or
  geometry changes.
- After finishing a task, change `[ ]` to `[x]` and add a brief completion note.
- Commit each completed task or task group. Stage only intended files, invoke
  `$caveman-commit`, then use the generated Conventional Commit message with
  `git commit`.
- If blocked, leave the task unchecked and add `Blocked:` with the exact reason.

## Baseline

- `rtk swift test` passed: 174 tests, 1 skipped benchmark, 0 failures.
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build` passed.
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -destination platform=macOS test` failed because the scheme has no test action.
- Context7 was used for current Apple SwiftUI guidance around state,
  observation, and view identity.

## Checklist

### 1. [x] Sunburst denominator overflow

Original finding: 3. Severity: Medium.

Scope:

- `Radix/Services/SunburstGeometry.swift`: `appendSegments`
- `Radix/Services/SunburstGeometry.swift`: `groupedChildren`

Audit note:

`groupedChildren` coerces child sizes to at least `1`, while `appendSegments`
uses `max(parentDenominator, children.count)`. Mixed nonzero and zero-byte
children can make effective child sizes sum beyond the denominator.

Approach:

- Verify with a focused mixed-size geometry test.
- Use an effective child total such as `sum(max(child.allocatedSize, 1))` as the
  denominator floor.
- Confirm child arcs do not exceed their parent arc.

Validate:

- `rtk swift test --filter SunburstGeometryTests`
- `rtk swift test`

Completion note: Verified mixed nonzero/zero-byte children could overflow the
parent arc; fixed the denominator floor to use effective child sizes and added a
regression test. Both validations passed.

### 2. [x] Xcode test workflow

Original finding: 19. Severity: Medium.

Scope:

- `Radix.xcodeproj/xcshareddata/xcschemes/Radix.xcscheme`
- `Package.swift`

Audit note:

SwiftPM tests pass, but `xcodebuild test` fails because the app scheme has no
test action.

Approach:

- Either configure an Xcode test target/test plan for `RadixCoreTests`, or
  document/script CI as `rtk swift test` plus Xcode build.
- Keep the chosen path explicit for future agents.

Validate:

- `rtk swift test`
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`
- If configured: `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -destination platform=macOS test`

Completion note: Verified `xcodebuild test` still fails because the app scheme
has no test action. Chose the documented workflow path: README now states that
SwiftPM owns `RadixCoreTests` and Xcode owns the app build. `rtk swift test` and
the Xcode Debug build both passed.

### 3. [x] Scanner cancellation in wide directories

Original finding: 1. Severity: High.

Scope:

- `Radix/Services/ScanEngine.swift`: `contents(of:includeHiddenFiles:behavior:exclusionMatcher:)`
- `Radix/Services/ScanCoordinator.swift`: scan restart/cancel paths

Audit note:

`contents(of:)` materializes immediate children and maps/filter them without
cancellation checks. A canceled scan can keep doing synchronous directory work
before the actor accepts the next scan.

Approach:

- Add cancellation checks around child enumeration/filtering.
- Consider batched or streaming enumeration if the direct fix is not enough.
- Add a focused cancellation test, using injection if filesystem setup is too
  brittle.

Validate:

- `rtk swift test --filter ScanEngineTests`
- `rtk swift test --filter ScanCoordinatorTests`
- `rtk swift test`

Completion note: Verified immediate child enumeration lacked cancellation polling
and that cancellation thrown inside directory traversal could be treated as an
access warning. Added cancellation checks during child filtering/enqueueing,
rethrow cancellation before warning fallback, and covered a wide-directory
cancel/follow-up scan. All validations passed.

### 4. [x] Duplicate node ID handling

Original finding: 2. Severity: High.

Scope:

- `Radix/Services/ScanEngine.swift`: `insertNode`, tree assembly child IDs
- `Radix/Models/ScanModels.swift`: `FileTreeStore` initializers/traversal

Audit note:

The scanner warns on duplicate insert, but duplicate child records can still
affect directory totals and child ID lists. `FileTreeStore` can also overwrite
duplicate IDs while keeping duplicate child references.

Approach:

- Define one duplicate-ID policy: drop later duplicates, disambiguate, or fail.
- Apply it before directory totals and child lists are finalized.
- Harden `FileTreeStore` construction and traversal assumptions.
- Cover duplicates in scanner and model tests.

Validate:

- `rtk swift test --filter FileTreeStoreTests`
- `rtk swift test --filter ScanEngineTests`
- `rtk swift test`

Completion note: Verified scanner insertion could warn while duplicate child
references still reached parent totals, and `FileTreeStore` accepted duplicate
child IDs. Chose a first-ID-wins policy: later duplicates are dropped before
scanner assembly/traversal links, with warnings still emitted. Added scanner
and model coverage. All validations passed.

### 5. [x] Subtree replacement ID collisions

Original finding: 15. Severity: Medium.

Scope:

- `Radix/Models/ScanModels.swift`: `FileTreeStore.replacingSubtree`

Audit note:

Replacement overlays all replacement nodes after removing the old subtree. If a
replacement ID exists elsewhere in the remaining tree, unrelated nodes can be
overwritten.

Approach:

- Preflight replacement IDs against remaining IDs.
- Fail or throw on external collisions.
- Test replacement collisions and root ID changes.

Validate:

- `rtk swift test --filter ScanModelTests`
- `rtk swift test --filter FileTreeStoreTests`
- `rtk swift test`

Completion note: Verified replacement nodes could overwrite IDs outside the
removed subtree. Added a preflight that rejects replacement IDs already present
outside the old subtree, and covered both external collisions and root ID
replacement. All validations passed.

### 6. [x] Full-scan search ID allocation

Original finding: 16. Severity: Medium.

Scope:

- `Radix/Models/ScanModels.swift`: `indexedNodeIDs(excludingRoot:)`
- `Radix/Services/FileBrowserModel.swift`: `FileSearchService.makeIndex`

Audit note:

Whole-scan search filters `orderedNodeIDs` into another full array before
building search entries.

Approach:

- Add a non-allocating ordered traversal API, such as closure-based iteration.
- Build search entries directly from that traversal.

Validate:

- `rtk swift test --filter FileTreeStoreTests`
- `rtk swift test --filter FileBrowserModelTests`
- `rtk swift test`

Completion note: Verified full-scan search allocated a filtered node-ID array
before building its index. Added `forEachIndexedNodeID(excludingRoot:)` and
build search entries directly from traversal. All validations passed.

### 7. [x] File-browser task lifecycle and result formatting

Original findings: 6, 7. Severity: Medium.

Scope:

- `Radix/Services/FileBrowserModel.swift`: search/prune tasks, display state
- `Radix/Features/FileList/FileBrowserTableView.swift`

Audit note:

Search and prune tasks are unstructured and can retain large scan data after
the table disappears. Result publication also formats every returned row on the
main actor.

Approach:

- Add explicit cleanup for search/prune tasks, including model/view lifecycle.
- Evaluate structured `.task(id:)` ownership if it fits the existing design.
- Move display-state formatting off-main or make it lazy/cached for visible
  rows.

Validate:

- `rtk swift test --filter FileBrowserModelTests`
- `rtk swift test`
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Verified search/prune tasks had no explicit view lifecycle
cleanup and display-state publication eagerly formatted all rows. Added model
cleanup plus view disappearance/deinit cancellation, and changed row display
values to a visible-row lazy cache. All validations passed.

### 8. [x] Duplicate navigation publishes on scan completion

Original finding: 8. Severity: Medium.

Scope:

- `Radix/ViewModels/AppModel.swift`: scan coordinator observers
- `Radix/Services/ScanCoordinator.swift`: scan completion
- `Radix/ViewModels/WorkspaceNavigationModel.swift`: forced publishes

Audit note:

`snapshot` and `completedScanSnapshot` can cause separate forced navigation
updates for the same completed scan.

Approach:

- Verify current publish behavior with an existing or new test.
- Collapse completion handling, or limit the completed-snapshot path to cache
  bookkeeping.
- Avoid forced publishes when state is unchanged.

Validate:

- `rtk swift test --filter WorkspaceNavigationModelTests`
- `rtk swift test --filter ScanCoordinatorTests`
- `rtk swift test`

Completion note: Verified scan completion published navigation twice through
the `snapshot` and `completedScanSnapshot` observer paths. Moved completion
handling to cache bookkeeping, resolved missing scan focus during scan-context
application, and removed forced unchanged navigation publishes. All validations
passed.

### 9. [x] Action dependency scope and file action duplication

Original findings: 4, 5. Severity: Medium.

Scope:

- `Radix/Features/FileList/FileBrowserTableView.swift`
- `Radix/Features/FileList/FileBrowserNameCell.swift`
- `Radix/Features/Inspector/SelectionInspectorView.swift`
- `Radix/Features/Inspector/InspectorActionsSection.swift`
- `Radix/App/RadixCommands.swift`

Audit note:

Some views observe `AppModel` mostly to call methods, causing unrelated
invalidations. File actions are also wired separately in commands, table menus,
and inspector buttons.

Approach:

- Pass focused action structs/closures into leaf views.
- Consider a shared action descriptor for labels, icons, availability, and
  handlers.
- Preserve existing behavior unless a divergence is intentional and documented.

Validate:

- `rtk swift test`
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Verified file-list and inspector leaf views observed the whole
`AppModel` for action calls and that selected-file actions repeated labels,
icons, and availability logic across table menus, inspector buttons, and
commands. Added shared `FileNodeAction` descriptors and focused action bundles
for the table and inspector while preserving command Quick Look toggle
behavior. Both validations passed.

### 10. [x] Inspector visibility control

Original finding: 9. Severity: Medium.

Scope:

- `Radix/ContentView.swift`
- `Radix/App/RadixCommands.swift`

Audit note:

The inspector starts visible, disables interactive dismissal, and has no visible
toggle command.

Approach:

- Verify whether `.interactiveDismissDisabled()` protects a known issue.
- Add a View menu item and/or toolbar affordance if user control is desired.
- Persist scene-level visibility only if it matches expected app behavior.

Validate:

- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Verified the known inspector crash note applies to the old
`VSplitView`/`.inspector` combination, not to user-controlled inspector
dismissal. Added a scene-focused inspector visibility binding, a View-menu
toggle command with Control-Command-I, and removed the forced interactive
dismissal disable. Xcode Debug build passed.

### 11. [x] Stale sidebar active targets

Original finding: 14. Severity: Low.

Scope:

- `Radix/ViewModels/AppModel.swift`: recent target clearing
- `Radix/ViewModels/SidebarModel.swift`: target section rebuilds

Audit note:

Single recent-target removal clears active state, but clearing all recent
targets or rebuilding target sections may leave `activeTargetID` pointing at no
current row.

Approach:

- Validate `activeTargetID` after section rebuilds.
- Clear it when no matching smart/recent target remains.
- Add coverage for clearing active recent targets.

Validate:

- `rtk swift test --filter SidebarModelTests`
- `rtk swift test --filter AppModelDependencyTests`
- `rtk swift test`

Completion note: Verified section rebuilds could leave `activeTargetID`
pointing at a removed recent row. Sidebar section rebuilds now clear active
targets absent from both smart and recent rows while preserving active smart
targets. Added SidebarModel and AppModel clear-recents coverage. All
validations passed.

### 12. [x] AppModel deferral and preference persistence

Original findings: 10, 11. Severity: Low.

Scope:

- `Radix/ViewModels/AppModel.swift`: deferred actions and preference publishers
- `Radix/Services/AppPreferencesStore.swift`

Audit note:

Several paths use `Task.sleep(for: .milliseconds(1))` for SwiftUI update-cycle
deferral. Scan preferences are also published and persisted one field at a time.

Approach:

- Centralize deferral if the current pattern remains necessary.
- Prefer view-owned `.task(id:)` or run-loop yielding where appropriate.
- Consider a validated `AppScanPreferences` value or intent methods for
  settings changes.
- Batch persistence when multiple settings change together.

Validate:

- `rtk swift test --filter AppModelDependencyTests`
- `rtk swift test --filter ScanCoordinatorTests`
- `rtk swift test`

Completion note: Verified AppModel had three separate one-millisecond deferred
task bodies and six independent scan-preference persistence publishers.
Centralized view-update deferral behind one helper, collapsed scan preferences
into a single debounced `AppScanPreferences` publisher, and updated coverage to
assert multi-field changes persist as one coherent save. All validations passed.

### 13. [x] Detail `NavigationStack`

Original finding: 12. Severity: Low.

Scope:

- `Radix/ContentView.swift`: `WorkspaceDetailView`

Audit note:

The detail wraps `WorkspaceView` in `NavigationStack`, but navigation is custom
through `WorkspaceNavigationModel` and no SwiftUI destination/path is present.

Approach:

- Remove the stack if it is unnecessary.
- Or add a short comment if it is intentionally reserved for planned navigation.

Validate:

- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Verified the detail view had no SwiftUI navigation path,
links, or destinations and navigation is handled by `WorkspaceNavigationModel`.
Removed the unnecessary `NavigationStack` while keeping the existing toolbar on
the workspace detail. Xcode Debug build passed.

### 14. [x] Full Disk Access presentation mapping

Original finding: 13. Severity: Low.

Scope:

- `Radix/Features/Settings/SettingsView.swift`
- `Radix/Features/Onboarding/OnboardingView.swift`

Audit note:

Full Disk Access status text, symbols, and colors are encoded separately.

Approach:

- Move shared status display values into a small extension/helper.
- Keep surface-specific explanatory copy local.

Validate:

- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Verified settings and onboarding duplicated Full Disk Access
status title, symbol, and color mapping. Moved shared display values into the
presentation helper extension while keeping surface-specific explanatory copy
local. Xcode Debug build passed.

### 15. [x] Dead or test-only production APIs

Original finding: 20. Severity: Low.

Scope examples:

- `Radix/Services/AppSystemActions.swift`: `AppSystemActions.inert`
- `Radix/ViewModels/AppModel.swift`: `activeSidebarTargetID`, `selectSidebarTarget`
- `Radix/Services/ScanCoordinator.swift`: `replaceCurrentSnapshot`
- `Radix/ViewModels/WorkspaceNavigationModel.swift`: `setFocusedNodeID`
- `Radix/Services/FileBrowserModel.swift`: `displayedNodeLookup`, `cancelSearch`
- `Radix/Shared/PresentationHelpers.swift`: `ScanTarget.sidebarSubtitle`

Audit note:

Static scans did not find production call sites for these APIs. Some may still
be useful test seams.

Approach:

- Re-run usage searches before deleting.
- Delete obsolete APIs, make internals private, or move test-only helpers into
  tests.

Validate:

- `rtk swift test`
- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination platform=macOS build`

Completion note: Re-ran usage searches and removed the stale production APIs:
`activeSidebarTargetID`, `displayedNodeLookup`, `cancelSearch`, and
`ScanTarget.sidebarSubtitle`. Updated tests to use the narrower existing
surfaces (`sidebar.activeTargetID`, `displayedNode(id:)`, and `cleanup()`).
Kept `AppSystemActions.inert`, `selectSidebarTarget`,
`replaceCurrentSnapshot`, and `setFocusedNodeID` as active test seams. Both
validations passed.

### 16. [x] Ordinary directory permission coverage

Original finding: 21. Severity: Low.

Scope:

- `Radix/Services/ScanEngine.swift`: regular directory enumeration failure path
- `RadixCoreTests/ScanEngineTests.swift`

Audit note:

Scanner tests cover many permission-adjacent cases, but not a focused unreadable
ordinary directory under a normal scan.

Approach:

- Add a test for unreadable ordinary directories.
- Assert warning category, inaccessible node state, and continued scan
  completion.
- Use injection if chmod-style setup is unreliable.

Validate:

- `rtk swift test --filter ScanEngineTests`
- `rtk swift test`

Completion note: Verified chmod-based setup is unreliable for this path because
the temp directory can be marked unreadable while enumeration still succeeds.
Added a focused directory contents provider seam and a scanner test that forces
an ordinary directory enumeration permission failure, then asserts the
permission warning, inaccessible directory node state, and continued scanning of
a readable sibling. Both validations passed.

### 17. [x] `SystemIntegration` safety testability

Original finding: 22. Severity: Low.

Scope:

- `Radix/Services/SystemIntegration.swift`
- `RadixCoreTests/SystemIntegrationTests.swift`

Audit note:

Tests focus on trash preflight protected roots. Open, reveal, copy path,
capacity descriptions, and Full Disk Access probing have limited direct
testability.

Approach:

- Add small injectable wrappers only where tests or fixes need them.
- Add focused failure/safety tests without broad redesign.

Validate:

- `rtk swift test --filter SystemIntegrationTests`
- `rtk swift test --filter AppModelDependencyTests`
- `rtk swift test`

Completion note: Verified only trash preflight had direct
`SystemIntegration` tests. Added small workspace, pasteboard, capacity, and
Full Disk Access probe seams, then covered open failure, reveal selection,
copy-path success/failure, capacity-description filtering, and FDA
granted/not-granted/unknown decisions. All validations passed.

### 18. [x] Duplicated test factories and fakes

Original finding: 23. Severity: Low.

Scope examples:

- `RadixCoreTests/AppModelDependencyTests.swift`
- `RadixCoreTests/FileBrowserModelTests.swift`
- `RadixCoreTests/ScanCoordinatorTests.swift`
- `RadixCoreTests/WorkspaceNavigationModelTests.swift`

Audit note:

Several tests repeat `FileNodeRecord` builders, persistence fakes, and action
fakes.

Approach:

- Extract small shared fixtures/fakes under `RadixCoreTests`.
- Keep helpers explicit enough that test intent stays clear.

Validate:

- `rtk swift test`

Completion note: Extracted shared test target, node, directory, and snapshot
fixtures into `RadixCoreTests/TestFixtures.swift`, then migrated the duplicated
builders in AppModel, file browser, scan coordinator, and workspace navigation
tests while leaving scenario-specific fakes local. Validation passed.

### 19. [x] README dependency wording

Original finding: 24. Severity: Low.

Scope:

- `README.md`
- `Radix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Radix/RadixApp.swift`

Audit note:

The README says there are no external Swift package dependencies, while the
Xcode app uses Sparkle through Swift Package Manager.

Approach:

- Clarify that `Package.swift` has no external dependencies for `RadixCore`.
- Note that the Xcode app integrates Sparkle through Xcode SPM.

Validate:

- Documentation-only if not paired with code changes.

Completion note: Verified `RadixApp.swift` imports Sparkle and Xcode
`Package.resolved` pins Sparkle, while `Package.swift` has no external
dependencies for `RadixCore`. Updated README wording to distinguish the core
SwiftPM package from the Xcode app's Sparkle integration. Documentation-only.

### 20. [ ] Stable table/search sorting tie-breakers

Original finding: 17. Severity: Low.

Scope:

- `Radix/Services/FileBrowserModel.swift`: `FileNodeTableComparator.compare`

Audit note:

The comparator returns `.orderedSame` for equal size, kind, or name. Equal sizes
are common and can produce unstable-looking row order.

Approach:

- Add deterministic fallback ordering, such as localized name then ID/path.

Validate:

- `rtk swift test --filter FileBrowserModelTests`
- `rtk swift test`

### 21. [ ] Trash safety policy construction in availability checks

Original finding: 18. Severity: Low.

Scope:

- `Radix/Models/ScanModels.swift`: `TrashSafetyPolicy.live`
- `Radix/Models/ScanModels.swift`: `FileNodeRecord.supportsMoveToTrash`

Audit note:

`supportsMoveToTrash` constructs a live `TrashSafetyPolicy` for each
availability check.

Approach:

- Consider caching/injecting a policy snapshot through app/system dependencies.
- Refresh on mounted-volume or relevant system changes.
- Coordinate with action dependency narrowing if that task has not landed.

Validate:

- `rtk swift test --filter ScanModelTests`
- `rtk swift test --filter AppModelDependencyTests`
- `rtk swift test`
