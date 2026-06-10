# Navigation State Refactor Plan

Last reviewed: 2026-06-10

## Purpose

Make workspace navigation updates atomic so the table, chart, breadcrumbs, inspector, and commands observe one coherent navigation snapshot per logical transition.

This plan covers the remaining audit item:

- P3: Navigation derived state is not atomic.

The current implementation works and has useful tests. This refactor is not urgent in the same way as the earlier main-actor runtime fixes, but it should happen before navigation behavior becomes more complex.

## Current Baseline

Relevant files as of 2026-06-10:

- `Radix/ViewModels/WorkspaceNavigationModel.swift`
- `Radix/ViewModels/AppModel.swift`
- `Radix/ContentView.swift`
- `Radix/Features/Workspace/WorkspaceView.swift`
- `Radix/Features/FileList/FileBrowserTableView.swift`
- `Radix/Features/Inspector/SelectionInspectorView.swift`
- `RadixCoreTests/WorkspaceNavigationModelTests.swift`

`WorkspaceNavigationModel` currently publishes several primitives:

- `selectedNodeID`
- `focusedNodeID`
- private `snapshotID`
- private `fileTreeStore`
- private `focusBackStack`
- private `focusForwardStack`

It also stores derived values separately:

- `tableNodes`
- `tableContentID`
- `selectedAncestorIDs`

The model refreshes derived values from methods such as `refreshSelectedAncestorIDs()` and `refreshTableState()`. Because these values are not grouped into one published state assignment, a future change can accidentally publish intermediate combinations such as a new focus with old table contents or a cleared selection with stale ancestors.

## Goals

- Publish one coherent navigation value per logical navigation transition.
- Preserve all existing user-facing navigation behavior.
- Keep the implementation native to SwiftUI and Combine/Observation style.
- Make navigation invariants explicit and easy to test.
- Reduce the chance of table, inspector, chart, and breadcrumb disagreement.
- Keep commands and views reading through simple properties during migration.

## Non-Goals

- Do not redesign workspace navigation UX.
- Do not introduce Redux, TCA, or another architecture framework.
- Do not combine scan state, file actions, and navigation into one mega-state.
- Do not refactor large SwiftUI files as part of this change.
- Do not change tree-store or snapshot semantics unless a test exposes a navigation bug.

## Native SwiftUI Guardrails

This refactor should remain idiomatic SwiftUI:

- Prefer one immutable Swift value published by an observable model.
- Keep views declarative: views should read state and call commands.
- Use `@ObservedObject`, `@StateObject`, or future Observation macros where they narrow invalidation naturally.
- Avoid manual invalidation flags, custom render schedulers, or controller-style presenters.
- Keep AppKit out of navigation state. AppKit should remain limited to real platform integration boundaries.

## Desired Shape

Introduce a value type such as:

```swift
struct WorkspaceNavigationState: Equatable {
    var snapshotID: UUID?
    var fileTreeStore: FileTreeStore?
    var selectedNodeID: FileNodeRecord.ID?
    var focusedNodeID: FileNodeRecord.ID?
    var focusBackStack: [FileNodeRecord.ID]
    var focusForwardStack: [FileNodeRecord.ID]
    var tableNodes: [FileNodeRecord]
    var tableContentID: String
    var selectedAncestorIDs: Set<FileNodeRecord.ID>
}
```

Possible adjustment: if `FileTreeStore` should not participate in equality, keep it in the state but implement equality around snapshot ID, focus, selection, stacks, table content ID, and derived node IDs. Another option is to keep `FileTreeStore` private and publish a smaller `WorkspaceNavigationViewState`; choose this only if it still guarantees one coherent publication.

`WorkspaceNavigationModel` should then have one main published state:

```swift
@Published private(set) var state = WorkspaceNavigationState.empty
```

Existing public properties can initially delegate to `state`:

```swift
var selectedNodeID: String? { state.selectedNodeID }
var focusedNodeID: String? { state.focusedNodeID }
var tableNodes: [FileNodeRecord] { state.tableNodes }
```

This lets callers migrate gradually without rewriting every view in the same commit.

## Required Invariants

These invariants should be enforced by state construction rather than scattered caller assumptions:

- If `selectedNodeID` is non-nil, that node exists in the current store.
- If `focusedNodeID` is nil, the root node is the effective focus when a store exists.
- If `focusedNodeID` is non-nil, it exists in the current store.
- `currentFocusNode` resolves to the focused node or root fallback.
- `tableContentID` changes when snapshot identity or effective focus changes.
- `tableNodes` matches the effective focus:
  - directory focus shows its children.
  - file focus shows its parent directory contents.
  - missing context shows an empty table.
- `selectedAncestorIDs` matches the selected node path.
- Focusing outside the selected subtree clears the selection.
- Snapshot replacement clears back/forward stacks and invalid selection/focus.
- Back/forward stacks never point to nodes missing from the current store after reconciliation.

## Implementation Plan

### Phase 1: Characterize Behavior

Add focused tests before changing implementation:

- Selection and selected ancestors publish together.
- Focus changes update `focusedNodeID`, `tableNodes`, and `tableContentID` together.
- Focusing outside the selected subtree clears selection and selected ancestors together.
- Snapshot replacement clears invalid selection/focus/history together.
- Back/forward navigation preserves current behavior.
- `resetFocusToRoot()` records history and clears selection as it does today.

Keep existing tests in `WorkspaceNavigationModelTests`. Add publish-count or state-coherence tests only if they are stable. Prefer asserting final coherent state over brittle implementation timing.

### Phase 2: Add State Type

Add `WorkspaceNavigationState` near `WorkspaceNavigationModel` or under `Radix/Models/` if it becomes reusable.

Recommended helper shape:

```swift
extension WorkspaceNavigationState {
    static let empty = WorkspaceNavigationState(...)

    func applyingScanContext(_ snapshot: ScanSnapshot?) -> WorkspaceNavigationState
    func selecting(_ nodeID: FileNodeRecord.ID?) -> WorkspaceNavigationState
    func focusing(_ nodeID: FileNodeRecord.ID?, recordHistory: Bool) -> WorkspaceNavigationState
    func navigatingBack() -> WorkspaceNavigationState
    func navigatingForward() -> WorkspaceNavigationState
}
```

Keep these helpers pure where possible. Pure helpers make navigation rules easier to test without driving the observable object.

### Phase 3: Publish Atomically

Replace scattered mutations with a local state copy and one final assignment:

```swift
func focus(nodeID: String?) {
    state = state.focusing(nodeID, recordHistory: true)
}
```

If a method needs side effects such as `onSelectionChanged`, compute whether the selection changed before assigning or after assigning from old/new state:

```swift
let oldSelection = state.selectedNodeID
let nextState = state.selecting(nodeID)
state = nextState
if oldSelection != nextState.selectedNodeID {
    onSelectionChanged?()
}
```

Avoid calling helper methods that mutate individual fields after this phase.

### Phase 4: Preserve Public Surface

Keep existing read-only computed properties during the first pass:

- `selectedNodeID`
- `focusedNodeID`
- `selectedNode`
- `selectedNodeParent`
- `breadcrumbNodes`
- `tableNodes`
- `tableContentID`
- `selectedAncestorIDs`
- `canNavigateBack`
- `canNavigateForward`
- `canClearSelection`
- `isFocusedAtRoot`

This limits call-site churn. Later, views can read `navigation.state` directly where that improves clarity.

### Phase 5: Remove Old Derived Storage

Once tests pass, remove:

- separate published primitive storage
- `refreshSelectedAncestorIDs()`
- `refreshTableState()`
- any method that only exists to keep derived values in sync

Make the state factory the only place where derived values are calculated.

## Testing Plan

Run:

```bash
rtk swift test
```

Update or add tests in `RadixCoreTests/WorkspaceNavigationModelTests.swift` for:

- selecting valid and invalid nodes
- selected ancestor updates
- focus history
- back and forward navigation
- file focus table fallback
- root reset
- focus outside selected subtree
- snapshot replacement
- AppModel routing through navigation state

Consider a new test that subscribes to navigation changes and verifies no emitted state has:

- a selected node missing from the store
- selected ancestors that do not contain the selected node
- table content IDs that disagree with effective focus

Do not overfit tests to exact Combine emission counts unless the implementation exposes a single `state` publisher intended to emit once per command.

## Manual QA

After implementation:

- Scan a folder with multiple nested directories.
- Select files and directories from the table.
- Click sunburst segments and confirm table, inspector, and breadcrumbs agree.
- Use back and forward navigation.
- Reset focus to root.
- Search entire scan, select a result, then zoom into parent directories.
- Expand an auto-summarized directory and confirm selection moves to the expanded root.
- Switch sidebar targets and confirm invalid selections clear.

## Risks

- Accidentally changing history behavior around root focus.
- Clearing selection too aggressively when focusing a file or package.
- Changing `tableContentID` semantics and causing file-browser refresh regressions.
- Holding large arrays in state and increasing copy-on-write pressure.
- Adding equality that is too expensive for large table states.

## Mitigations

- Keep the first refactor behavior-preserving.
- Keep existing property names as computed facades during migration.
- Use targeted tests before and after each phase.
- Avoid making `WorkspaceNavigationState` too clever. It should be a coherent value, not a new architecture framework.
- If state equality is needed, compare stable IDs rather than whole node arrays.

## Rollback Strategy

This refactor should be easy to revert if done in phases:

1. Keep public API compatibility during the first implementation.
2. Avoid call-site rewrites until state tests are green.
3. Commit pure state introduction separately from view cleanup.

If regressions appear, revert the state replacement commit while keeping any added characterization tests that still describe desired behavior.

## Future Re-Verification Checklist

Before starting this plan later, re-check:

- Whether `WorkspaceNavigationModel` still owns table state.
- Whether Swift Observation has replaced `ObservableObject` in the project.
- Whether `FileBrowserTableView` still keys refreshes off `tableContentID`.
- Whether expansion, sidebar scoping, or search result selection added new navigation rules.
- Whether `WorkspaceNavigationModelTests` gained coverage that should be preserved.
