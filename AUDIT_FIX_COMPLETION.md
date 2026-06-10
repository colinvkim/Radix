# Audit Fix Completion

## Fixed

- P1 entire-scan search: matching, materializing, and sorting now complete off the main actor.
- P1 scan finalization: phase 2 now emits finalization progress, checks cancellation, and avoids an extra aggregate-stats pass where practical.
- P1 subtree extraction/replacement: scan snapshot transforms now run through a background actor, and subtree scoping builds from targeted traversal.
- P2 table display values: file-browser rows now precompute display values instead of mutating an LRU cache from cell rendering.
- P2 sidebar sections: smart/recent targets are cached in `AppModel`, keeping filesystem availability checks out of SwiftUI body evaluation.
- P2 file-browser lifecycle: table content refresh/search cancellation is driven by content identity instead of `onAppear`/`onDisappear`.
- P2 cache lifetime: search indexes are pruned when snapshots are replaced, and display state avoids a persistent node lookup dictionary.
- P3 expansion feedback: the active summarized-node expansion ID is published and shared by inline, context-menu, and double-click entry points.
- P3 window observer: duplicate SwiftUI update reports are suppressed unless the observed window identity changes.
- P3 deferred scan start: scan deferral now uses an explicit main-actor task yield while preserving cancellation tokens.

## Remaining

- P2 broad observable state still remains. Fixing it should be a separate feature-boundary/state-ownership pass.
- P3 navigation derived state is still not atomic. It needs a deliberate `NavigationState` refactor with focused navigation tests.
- P3 large SwiftUI file decomposition remains. This should stay behavior-neutral and happen after runtime fixes settle.

## Verification

- Ran `rtk swift test` after every logical fix. Final runs passed with 137 tests, 1 benchmark skipped, and 0 failures.
- Manual large-scan, Instruments, mounted-volume, and window interaction smoke tests were not run in this environment.

## Tradeoffs

- The cache and transform fixes prioritize reducing main-actor and duplicate-memory pressure without changing snapshot cache size policy.
- UI-private window observer behavior is covered by build/test regression only; direct unit coverage would require exposing the private observer.
