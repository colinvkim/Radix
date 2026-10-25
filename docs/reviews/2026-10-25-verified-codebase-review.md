# Verified codebase findings

Updated on 2026-10-25 against commit `e320bd6a02217a454fa39796387449211ffd4c01`.

This document retains the supported findings from [the original review](/Users/colin/Programming/Radix/docs/reviews/2026-10-24-full-codebase-review.md). Original item numbers identify the source claims. Repeated findings are combined. Unsupported failure claims and observations that describe intentional policy without an established problem have been removed.

The evidence includes production caller tracing, existing tests, compiler checks, and small probes that exercise actual production functions or the relevant native API. The full core suite passed 1,131 tests in 79 suites at this commit using `swift test --scratch-path /tmp/radix-review-verification/build`.

The initial verification did not include live UI, VoiceOver, runtime locale changes, cross-display animation, multi-device event-ID checks, or performance measurements. Subsequent implementation checks are recorded below. Performance candidates identify source work to measure rather than an established user-visible stall.

## Implementation progress

Six independent pull requests target `main`. A status of "PR open" means the fix is available on its branch and has not yet landed in `main`.

| PR | Scope | Status | Validation | Link |
|---|---|---|---|---|
| 1 | Remove unused helpers and use checked Sendable conformance | Verified locally; preparing PR | 1131 core tests; full app build; independent review passed | Pending |
| 2 | Avoid redundant presentation updates, items 9 and 25 | Verified locally; preparing PR | Regression red/green; 1132 core tests; full app build; review passed | Pending |
| 3 | Skip unchanged child-buffer writes, item 68 | Fix implemented | 1131 core tests and review passed; Release comparison pending | Pending |
| 4 | Gate settings reset, item 16 | UI validation in progress | App build passed; reachable-tour regression fixture correction underway | Pending |
| 5 | Correct Sunburst aggregate bytes, item 46 | App validation pending | Geometry red/green; 1131 core tests; independent review passed | Pending |
| 6 | Retain FSEvents history callback context, item 31 | App validation pending | Native lifetime and release-balance probes; 1131 core tests; review passed | Pending |

## Behavior and correctness findings

### 31. FSEvents history callbacks have a context lifetime gap

`DarwinFileSystemEventHistoryProvider.history` passes an unretained collector into `FSEventStreamContext` with no retain or release callbacks. The awaiting operation and cancellation handler keep the collector alive through teardown. The stream has no independent ownership of that collector. See [FileSystemEventHistory.swift:67](/Users/colin/Programming/Radix/Radix/Services/FileSystemEventHistory.swift:67) and [FileSystemEventHistory.swift:102](/Users/colin/Programming/Radix/Radix/Services/FileSystemEventHistory.swift:102).

A native FSEvents probe paused an entered callback before it accessed its context. Another thread stopped, invalidated, and released the stream, then released the final strong context reference. Teardown returned while the callback was still active, and the context had deallocated. A matched probe using the watcher's retain and release callbacks kept the context alive under the same schedule.

The history callback can be preempted before `takeUnretainedValue` at [FileSystemEventHistory.swift:210](/Users/colin/Programming/Radix/Radix/Services/FileSystemEventHistory.swift:210). Concurrent timeout or cancellation can therefore expose a use-after-free window. Ordinary completion already inside `collector.receive` also has a local strong reference, so the risk depends on the callback's position and the remaining owners.

This is a supported potential crash race. No Radix crash was induced. The existing ownership pattern at [FileSystemChangeWatcher.swift:53](/Users/colin/Programming/Radix/Radix/Services/FileSystemChangeWatcher.swift:53) is a demonstrated remedy. Holding the collector only until `FSEventStreamRelease` returns is insufficient for a callback that has already entered and outlives that return.

### 46. Sunburst aggregate summaries count layout weights as bytes

Sunburst assigns at least one unit of angular weight to each child. It also adds those weights into aggregate `totalSize` at [SunburstGeometry.swift:218](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:218). Treemap keeps aggregate bytes separate from layout weights at [TreemapGeometry.swift:222](/Users/colin/Programming/Radix/Radix/Services/TreemapGeometry.swift:222).

A probe against the production geometry functions placed three empty files beside a large file. The Sunburst aggregate reported 3 B. The Treemap aggregate reported 0 B. Sunburst's aggregate hover summary uses this inflated total at [SunburstChartView.swift:109](/Users/colin/Programming/Radix/Radix/Features/Visualization/SunburstChartView.swift:109).

Individual file hover cards resolve the actual node and show its actual allocated bytes. The defect concerns aggregate accounting and aggregate summaries. Keep actual bytes separate from minimum layout weights. The corresponding Treemap contract is covered by `testAggregateSizeDoesNotCountZeroByteLayoutWeightsAsDiskUsage`.

### 54. Alternate-case paths bypass exact protected-root matching

`TrashSafetyPolicy.blockReason` compares case-preserving standardized paths against an exact string set at [TrashSafetyPolicy.swift:123](/Users/colin/Programming/Radix/Radix/Models/TrashSafetyPolicy.swift:123).

A probe of the actual policy blocked `/Applications` but accepted `/applications` and `/APPLICATIONS`. Read-only `stat` calls confirmed that all three paths referred to the same inode and device on the tested case-insensitive volume.

This establishes a protection-policy gap for path aliases. It does not establish that a native trash operation succeeds or that user data was lost. Existing protected-root tests use canonical-case strings and do not deliberately specify alternate-case acceptance.

Any normalization change must respect the filesystem's case sensitivity. Global lowercasing would also merge distinct paths on a case-sensitive volume.

### 16. Settings reset does not follow the active-operation restriction

The read-only setter rejects changes during an active tour, native drag, or trash move at [AppModel.swift:205](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:205). The reset action at [AppModel.swift:881](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:881) continues resetting other preferences after calling that setter. Its button and confirmation do not use the same eligibility rule.

Manual baseline validation confirmed that an active tour disables the read-only toggle while leaving Reset All Settings enabled. Starting a tour itself requires read-only mode to be off at [AppModel.swift:721](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:721). The earlier example of starting a tour with read-only enabled was unreachable and did not establish a failed read-only reset.

The approved change makes reset follow the existing active-operation restriction. It rejects the entire reset at the model boundary and disables initiation and confirmation while restricted. This is consistent operation gating. The reachable tour scenario has read-only already off, so it does not demonstrate a partial read-only default mismatch.

### 1. Asynchronous current-contents refreshes hide retained rows

`FileBrowserModel` keeps its previous row presentation while an asynchronous refresh runs. Its full presentation context no longer equals the requested context, so `isDisplayingCurrentResults` becomes false at [FileBrowserModel.swift:80](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:80).

`FileBrowserTableView` then selects the loading branch instead of the table at [FileBrowserTableView.swift:149](/Users/colin/Programming/Radix/Radix/Features/FileList/FileBrowserTableView.swift:149). The model's retained stale rows are therefore unavailable in the table during that refresh.

This affects the asynchronous current-contents path. Entire-scan searches have a separate loading branch. Navigation owns selection independently, so this finding does not establish selection loss. Scroll-position and column-state effects were not manually tested. Existing model tests establish stale-data retention, not a rendered SwiftUI contract.

Keeping rows visible requires distinguishing stale results for the same logical scope from results belonging to a different directory or scan.

### 9. Document opening treats sheetless archive work differently from deferred imports

When no modal destination is active, the presentation coordinator returns `startNow` at [AppPresentationCoordinator.swift:130](/Users/colin/Programming/Radix/Radix/ViewModels/AppPresentationCoordinator.swift:130). If archive work is already running, `AppModel` rejects that import with an archive-busy error at [AppModel.swift:1116](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:1116).

An import deferred behind a modal instead waits for archive idle at [AppModel.swift:850](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:850).

The same busy operation therefore produces different handling depending on whether a sheet caused the import to be deferred first. The existing tests and comment guarantee modal serialization. They do not establish a broader promise to queue every busy document-open event. Extending that queue is a behavior decision supported by this concrete asymmetry.

### 10. Split-pane proportions reset when their subtree is recreated

`WorkspaceSplitView` stores its fraction only in local `@State`, initially 0.56, at [WorkspaceSplitView.swift:20](/Users/colin/Programming/Radix/Radix/Features/Workspace/WorkspaceSplitView.swift:20).

The comparison branch replaces the workspace subtree at [ContentView.swift:644](/Users/colin/Programming/Radix/Radix/ContentView.swift:644). The tour-session identity also recreates the detail subtree at [ContentView.swift:59](/Users/colin/Programming/Radix/Radix/ContentView.swift:59). The split fraction has no owner outside those subtrees and therefore returns to its initial value after recreation.

This follows from state lifetime. The visual transitions were not manually exercised. Persisting the fraction or moving its ownership outside the recreated subtree would preserve the user's adjustment. Restored values need the existing fraction bounds.

### 22. Initial comparison state cannot distinguish an unloaded dataset from empty results

`ScanComparisonBrowserModel` starts with empty arrays and `isRefreshing == false` at [ScanComparisonBrowserModel.swift:33](/Users/colin/Programming/Radix/Radix/ViewModels/ScanComparisonBrowserModel.swift:33). The comparison view installs its dataset task at [ScanComparisonView.swift:90](/Users/colin/Programming/Radix/Radix/Features/Comparison/ScanComparisonView.swift:90).

Before that task starts, `comparisonContent` selects the empty-results branch at [ScanComparisonView.swift:100](/Users/colin/Programming/Radix/Radix/Features/Comparison/ScanComparisonView.swift:100). There is no initial dataset-pending state.

The initial branch does not describe whether the comparison contains matches. An explicit pending state would make that distinction. A visible empty-state flash was not observed and is not asserted here.

### 33. A must-scan root event receives an identity-change explanation

A history event at the scan root containing only `mustScanSubdirectories` produces `.changedScanRoot` at [IncrementalRescanPlanner.swift:33](/Users/colin/Programming/Radix/Radix/Services/IncrementalRescanPlanner.swift:33). A probe of the actual planner confirmed this result.

That fallback maps to the location-changed presentation category at [ScanIncrementalModels.swift:140](/Users/colin/Programming/Radix/Radix/Services/ScanIncrementalModels.swift:140). The flag requires broader scanning but does not itself prove that the location's identity changed.

This concerns the history-driven incremental planner. The live watcher's ancestor-event rewrite follows the folder-refresh path and does not establish how often this planner case occurs. A more specific uncertainty category would avoid implying an identity change without that evidence.

### 37. Archive progress resets between phases

`ScanArchiveProgress.fractionCompleted` computes progress within the current phase at [ScanArchiveService.swift:99](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveService.swift:99). Export transitions include indeterminate topology and metadata stages at [ScanArchiveService.swift:336](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveService.swift:336).

`ArchiveWorkflowCoordinator` forwards the phase fraction directly at [ArchiveWorkflowCoordinator.swift:67](/Users/colin/Programming/Radix/Radix/ViewModels/ArchiveWorkflowCoordinator.swift:67). The UI switches indicator mode when the value becomes nil at [ContentView.swift:387](/Users/colin/Programming/Radix/Radix/ContentView.swift:387).

A valid phase sequence produced fractions `1.0`, `nil`, and `0.5` through the actual progress type. The indicator can therefore change mode and display a lower fraction when a new phase begins. The newest-only stream can hide intermediate updates during small operations, so visible flicker is not inevitable.

An operation-wide fraction would need explicit phase weights and a monotonic contract. Existing tests do not assert cross-phase monotonicity.

### 38. Abrupt process exit can leave archive temporary packages

Export creates a UUID-named hidden sibling package at [ScanArchiveService.swift:821](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveService.swift:821). An in-process `defer` removes unfinished work at [ScanArchiveService.swift:299](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveService.swift:299). No archive-temp reaper was found in the repository.

A crash or force quit can bypass cleanup and leave a partial package in the destination directory. Its size depends on how much of the archive was written. Cooperative cancellation cleanup is already tested by `testCancelledExportKeepsExistingArchiveAndRemovesTemporaryPackage`.

Any stale-package cleanup needs an ownership and liveness rule. Deleting all matching siblings at export start could remove another active export's temporary package.

### 50. An identity-scale viewport reset can clear hover despite doing no movement

`ChartViewportState.perform` returns true for reset even when the animator exits because the requested transform is already current. See [ChartViewportControls.swift:41](/Users/colin/Programming/Radix/Radix/Features/Visualization/ChartViewportControls.swift:41) and [ChartViewportControls.swift:60](/Users/colin/Programming/Radix/Radix/Features/Visualization/ChartViewportControls.swift:60).

The chart uses that return value to clear hover at [SunburstChartView.swift:615](/Users/colin/Programming/Radix/Radix/Features/Visualization/SunburstChartView.swift:615). The reset popover button is disabled at identity, but the enabled Actual Size menu at [RadixCommands.swift:83](/Users/colin/Programming/Radix/Radix/App/RadixCommands.swift:83) and the accessibility action can still reach this path.

The no-op result can trigger unnecessary hover clearing. The result should distinguish an accepted command from an actual viewport change if callers use it to invalidate interaction state.

### 51. Chart accessibility values omit loading state

The chart containers ignore accessibility children at [SunburstChartView.swift:279](/Users/colin/Programming/Radix/Radix/Features/Visualization/SunburstChartView.swift:279) and [TreemapChartView.swift:203](/Users/colin/Programming/Radix/Radix/Features/Visualization/TreemapChartView.swift:203). The loading indicator is inside those containers at [ChartLayoutFailureBanner.swift:16](/Users/colin/Programming/Radix/Radix/Features/Visualization/ChartLayoutFailureBanner.swift:16).

The replacement accessibility values at [SunburstChartView.swift:454](/Users/colin/Programming/Radix/Radix/Features/Visualization/SunburstChartView.swift:454) and [TreemapChartView.swift:344](/Users/colin/Programming/Radix/Radix/Features/Visualization/TreemapChartView.swift:344) contain no loading case.

The explicit accessibility representation therefore omits the chart's loading state. Reflecting it in the chart's accessible value or a suitable announcement would make that state available. Exact VoiceOver speech and announcement timing still require a manual check.

## Conditional correctness and numerical hardening

### 5. Search-index identity omits the normalization locale

Search normalization uses the current locale at [FileBrowserSearch.swift:363](/Users/colin/Programming/Radix/Radix/Services/FileBrowserSearch.swift:363). The cached entire-scan index key contains snapshot and tree-content identities but no locale at [FileBrowserSearch.swift:617](/Users/colin/Programming/Radix/Radix/Services/FileBrowserSearch.swift:617).

If the effective locale changes while an index remains cached, normalization inputs can differ without a cache-key change. This is a cache-invalidation dependency visible in source. A runtime locale-switch failure was not reproduced.

### 26. Bulk and Foundation directory metadata follow different size policies

Bulk metadata sets directory logical, allocated, and data sizes to zero at [BulkDirectoryEnumerator.swift:732](/Users/colin/Programming/Radix/Radix/Services/BulkDirectoryEnumerator.swift:732). Foundation metadata can use URL size fields or status-block allocation for a directory at [ScanMetadataLoader.swift:502](/Users/colin/Programming/Radix/Radix/Services/ScanMetadataLoader.swift:502).

Package-leaf construction uses the maximum of directory metadata and summarized contents at [ScanEngine.swift:3083](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:3083). A nonzero directory allocation can therefore affect that path. A probe using an injected allocation fallback produced 8,192 bytes for directory metadata.

Local APFS fixtures with zero, one, and 1,000 children reported zero directory blocks and showed no resulting divergence. Existing scanner-parity coverage also includes a nonempty package. The remaining issue is a conditional metadata-policy mismatch. Reproducing different scan totals requires a real fixture with positive directory metadata allocation.

### 34. The incremental path helper differs at the slash root

The containment helper at [IncrementalScanService.swift:673](/Users/colin/Programming/Radix/Radix/Services/IncrementalScanService.swift:673) constructs `root + "/"` without a special case for `/`. It therefore tests for a double-slash prefix when root is `/`.

Normal slash targets are classified as volumes and bypass incremental recovery. A manually constructed folder target at `/` can express the inconsistent helper input, but an ordinary current UI route to it was not found.

This is a conditional helper inconsistency. Shared containment work must preserve the different contracts for absolute paths, relative paths, and tour-specific temporary roots.

### 45. Floating-point accumulation leaves a numerical Sunburst seam miss

A production-code probe with 13 equally weighted children ended at `6.2831853071795845` rather than `6.283185307179586`. `SunburstHitTestIndex` returned nil for point `(99.99999999999993, 30)` in a 200 by 200 chart. See [SunburstGeometry.swift:126](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:126) and [SunburstGeometry.swift:501](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:501).

The uncovered angle is approximately `1.78e-15` radians. The renderer uses the same endpoints, so this does not establish a visibly filled but unhittable wedge. The existing full-circle test allows a much larger tolerance.

This is numerical hardening with no demonstrated visible impact. Any endpoint adjustment must preserve intentional unallocated angle when `safeDenominator` exceeds total child weight.

### 68. Integer helpers have different signed and count-domain contracts

`ScanIntegerMath.addingClamped(Int64.min, -1)` returns `.max` because every overflow takes that branch at [ScanIntegerMath.swift:2](/Users/colin/Programming/Radix/Radix/Services/ScanIntegerMath.swift:2). The existing `saturatingAdd` at [ScanIntegerMath.swift:10](/Users/colin/Programming/Radix/Radix/Services/ScanIntegerMath.swift:10) handles negative overflow correctly.

The comparison helper clamps negative overflow to `-.max`, one integer above `.min`, at [ScanComparisonService.swift:3](/Users/colin/Programming/Radix/Radix/Services/ScanComparisonService.swift:3). The atomic pool's helper also floors ordinary negative results to zero. These helpers are not interchangeable merely because they all handle overflow.

The negative-overflow behavior is a generic-contract hazard. No current user-visible scan error from a negative `addingClamped` input was established. Consolidation requires an explicit choice between nonnegative counts, signed saturation, and comparison-delta bounds.

## Performance candidates

The following repeated work is present in source. Its end-to-end cost remains unmeasured. A change needs a relevant profile or benchmark and must preserve the listed constraints.

| Original item | Source-supported work | Constraints on an optimization |
|---|---|---|
| 3 | Asynchronous browser refreshes choose the 180 ms debounce from text presence at [FileBrowserModel.swift:262](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:262) and [FileBrowserModel.swift:318](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:318). Sort, scope, and content changes can pay the same delay while a text query is active. | Small current-contents queries use the synchronous path. Structured-only queries have no debounce. Cancelled work does not imply a completed full pass for every keystroke. Trigger-specific debounce would be a UX change. |
| 4 | Each `FileBrowserTableAdapter.updateNSView` schedules a main-queue attachment check at [FileBrowserTableAdapter.swift:20](/Users/colin/Programming/Radix/Radix/Shared/FileBrowserTableAdapter.swift:20). | Row-height invalidation is already context-gated. Data-source repair also handles a SwiftUI table data-source replacement without a new presentation context. A context-only guard must not suppress that repair. |
| 5 | Current-contents text matching rebuilds normalized row haystacks at [FileBrowserResults.swift:79](/Users/colin/Programming/Radix/Radix/Services/FileBrowserResults.swift:79) and [FileBrowserSearch.swift:380](/Users/colin/Programming/Radix/Radix/Services/FileBrowserSearch.swift:380). Entire-scan indexing caches them. | Metadata-only queries avoid text normalization. No allocation count was measured. A cache needs content and locale invalidation. |
| 14 | Exclusion-editor text changes publish preferences per keystroke at [ExclusionPatternsEditor.swift:102](/Users/colin/Programming/Radix/Radix/Features/Settings/ExclusionPatternsEditor.swift:102). Publishing normalizes all editor rows at [ExclusionPatternsEditor.swift:267](/Users/colin/Programming/Radix/Radix/Features/Settings/ExclusionPatternsEditor.swift:267). | Running scans retain captured options. Preferences affect future option construction. Cleanup has a persistence flush. Commit-only publication changes editing behavior, and removing normalization can change trimming and deduplication. |
| 18 | The undo-focus observer receives window updates without an object filter at [DiscardPileUndoFocusObserver.swift:50](/Users/colin/Programming/Radix/Radix/Shared/DiscardPileUndoFocusObserver.swift:50). | Work is coalesced and notifications stop when the representable is dismantled. Key-window and sheet transitions can require notifications from outside the workspace window. |
| 20 | Same-root comparison discovers shared-allocation references with two tree traversals before the empty-reference guard, then performs two collection traversals if references exist at [ScanComparisonService.swift:1465](/Users/colin/Programming/Radix/Radix/Services/ScanComparisonService.swift:1465). Ancestor sets are also computed for overlapping but different inputs. | Reference discovery is how emptiness is determined. A combined pass must retain candidates from the other snapshot that did not advertise sharing themselves. Memory and traversal tradeoffs need measurement. |
| 21 | Selected-row resolution uses `rows.first` at [ScanComparisonView.swift:713](/Users/colin/Programming/Radix/Radix/Features/Comparison/ScanComparisonView.swift:713). | A selected row can require an O(n) lookup during view evaluation. Exactly two lookups per keystroke was not established. A dictionary adds memory and invalidation work. |
| 27 | Shared-allocation correction resolution runs after the initial finalizing update and before assembly progress begins at [ScanEngine.swift:2091](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2091). The accumulator has cancellation checks but no progress callback. | This supports a possible progress pause near the finalization boundary. Its duration was not measured, and the worker remains cancellable. It does not establish a main-thread stall. |
| 28 | General `GlobPattern.matches` calls build a character array, optional character boundaries, a boundary-offset dictionary, and matching-state arrays at [ScanExclusionMatcher.swift:395](/Users/colin/Programming/Radix/Radix/Services/ScanExclusionMatcher.swift:395). | Exact and optimized simple basename patterns bypass this general path. Actual allocation frequency and user-visible cost remain unmeasured. Reuse must preserve case-fold expansion and wildcard character-boundary semantics. |
| 30 | Descriptor eviction chooses the first eligible dictionary lease at [ScanDirectoryDescriptorPool.swift:299](/Users/colin/Programming/Radix/Radix/Services/ScanDirectoryDescriptorPool.swift:299). Pool fallback can use temporary unpooled cursors through [ScanEngine.swift:2713](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2713). | The pool correctly caps its retained descriptors. That cap does not cover every temporary descriptor in a scan. Reopen frequency, the benefit of LRU eviction, and any process-wide exhaustion were not measured. |
| 32 | The history collector retains all accepted events in its checkpoint interval at [FileSystemEventHistory.swift:229](/Users/colin/Programming/Radix/Radix/Services/FileSystemEventHistory.swift:229) and [FileSystemEventHistory.swift:306](/Users/colin/Programming/Radix/Radix/Services/FileSystemEventHistory.swift:306). A production collector probe retained 5,000 events. | The interval and timeout do not impose an event-count bound. FullHistory does not mean the entire journal. A cap needs an uncertainty marker and conservative full-scan fallback. The live watcher already has a bounded-buffer precedent. |
| 34 | Each shallow relist filters warnings against preserved subtree roots at [IncrementalScanService.swift:583](/Users/colin/Programming/Radix/Radix/Services/IncrementalScanService.swift:583). | The nested work can grow with both warnings and preserved roots. A partition must handle nested roots and warning paths outside the scope. First-component grouping is not automatically equivalent. |
| 36 | Folder refresh builds parent URLs on MainActor at [FolderRefreshController.swift:254](/Users/colin/Programming/Radix/Radix/ViewModels/FolderRefreshController.swift:254) and during ancestor recording at [FolderRefreshController.swift:301](/Users/colin/Programming/Radix/Radix/ViewModels/FolderRefreshController.swift:301). | Batches are bounded. A string implementation must preserve slash-root and path-namespace behavior. No measured allocation or UI cost is available. |
| 40 | Archive export constructs per-node path envelopes using URL components at [ScanArchiveModels.swift:467](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveModels.swift:467) and [ScanArchiveNodeIO.swift:146](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveNodeIO.swift:146). | Plain concatenation must preserve path-component encoding and root behavior. URL operations have not been shown to dominate export. The existing archive benchmark is the measurement target. |
| 41 | Legacy v3 import materializes the full archive-node array before the node dictionary and ordered IDs at [ScanArchiveNodeIO.swift:258](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveNodeIO.swift:258). | An out-of-order compact topology also has a deliberate full-record fallback. Extra representations exist, but no memory multiplier or per-import budget violation was measured. Streaming must preserve legacy order and validation. |
| 47 | Sunburst publishes indexes and render state on MainActor at [SunburstChartModel.swift:176](/Users/colin/Programming/Radix/Radix/Services/SunburstChartModel.swift:176), and maps colors at [SunburstChartModel.swift:239](/Users/colin/Programming/Radix/Radix/Services/SunburstChartModel.swift:239). Treemap prepares its payload in its layout service. | The ownership difference is real. No 10 to 100 ms stall was measured. Moving preparation must preserve generation, cancellation, and publication semantics. |
| 49 | Treemap redraws resolve visible label text and estimate truncation using 6.1 pixels per character at [TreemapChartCanvases.swift:88](/Users/colin/Programming/Radix/Radix/Features/Visualization/TreemapChartCanvases.swift:88). Hover content is rebuilt in both chart views. Role lookup precedes culling at [TreemapChartCanvases.swift:193](/Users/colin/Programming/Radix/Radix/Features/Visualization/TreemapChartCanvases.swift:193). | SwiftUI and Canvas internal caching was not measured. Fixed-width truncation is approximate for wide names. The spatial-selection comparator is a linear-min comparator, not a sort. Geometric zoom area is not a measurement of raster work. |
| 56 | Each native trash operation revalidates policy through the static `blockReason`, which rebuilds live policy at [SystemIntegration.swift:497](/Users/colin/Programming/Radix/Radix/Services/SystemIntegration.swift:497) and [TrashSafetyPolicy.swift:119](/Users/colin/Programming/Radix/Radix/Models/TrashSafetyPolicy.swift:119). | Inspector and ordinary presentation checks use an injected cached policy. Firmlink file parsing is static-once. Caching the destructive boundary would change freshness guarantees and needs justification. |
| 59, 60 | Trash-request staging performs live filesystem checks on MainActor through [AppModel.swift:2789](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:2789). Native drag identity verification runs at [FileDragController.swift:69](/Users/colin/Programming/Radix/Radix/Services/FileDragController.swift:69). Terminal opening reads resource values at [SystemIntegration.swift:371](/Users/colin/Programming/Radix/Radix/Services/SystemIntegration.swift:371). | Merely adding items to the Discard Pile defers live-path validation and has an explicit test for zero existence checks. Any background work or memoization must preserve identity freshness at the external action boundary. |
| 62 | Multi-selection inspector evaluation builds a summary and two availability values at [SelectionInspectorView.swift:37](/Users/colin/Programming/Radix/Radix/Features/Inspector/SelectionInspectorView.swift:37). Warning matching can compare every warning against every selected root at [SelectionInspectorView.swift:228](/Users/colin/Programming/Radix/Radix/Features/Inspector/SelectionInspectorView.swift:228). | Policy checks here are cached Set lookups. Any summary cache must follow tree-content changes and metadata changes, not just snapshot ID and selected IDs. No expensive-render measurement was collected. |
| 67 | Post-trash statistics walk the moved subtree at [AppUsageStatsStore.swift:125](/Users/colin/Programming/Radix/Radix/Services/AppUsageStatsStore.swift:125), called on MainActor through [AppModel.swift:3258](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:3258). Initialization also rebuilds sidebar sections through observed property assignments and an explicit refresh. | The traversal and repeated filtering are real. Their latency depends on the tree and target list. Recording folder counts or moving work off-main requires preserving statistics and store lifetime. |
| 68 | Allocated-size repair writes child buffers back unconditionally at [FileTreeStore.swift:1574](/Users/colin/Programming/Radix/Radix/Models/FileTreeStore.swift:1574), even when `didReorderChildren` is false. | The copied elements can be identical. Skipping the write must preserve actual reorder cases. No runtime improvement was measured. |
| Atomic probe | Foundation probe loops at [AtomicDirectorySummaryProbe.swift:177](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectorySummaryProbe.swift:177) lack an explicit per-iteration autorelease pool. | No autoreleased-object accumulation was measured. The heuristic has visit bounds, and replay entries intentionally retain values. A pool must encompass all relevant bridging without dropping retained replay data. This is a profiling target. |
| Atomic probe | At 64 active cursors the bulk probe changes a frame to eager enumeration at [AtomicDirectorySummaryProbe.swift:352](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectorySummaryProbe.swift:352). An unsupported eager result can abandon accumulated probe state and select a fresh Foundation heuristic traversal. | Reaching the cursor cap alone does not discard the DFS. The repeated-work case requires the unsupported fallback result. Its frequency and cost are unmeasured. |

## Maintenance and API simplification

These are supported code-economy candidates. They are not additional runtime bugs. A cleanup must preserve callers, protocol requirements, intentional policy, and existing observable behavior.

### 9 and 25. Equal presentation assignments cause redundant notifications

`AppPresentationCoordinator.present` reassigns an equal published destination at [AppPresentationCoordinator.swift:98](/Users/colin/Programming/Radix/Radix/ViewModels/AppPresentationCoordinator.swift:98).

Comparison setup's change callback synchronizes that destination and explicitly publishes an AppModel change at [AppModel.swift:434](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:434). The coordinator's notification is also forwarded at [AppModel.swift:408](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:408).

This produces redundant raw notification paths. The controller's local copy-mutate-reassign pattern still assigns setup once per successful action. A mutation helper would not fix the notification cause. SwiftUI can coalesce notifications, so this finding does not establish duplicate render passes.

### 6. Browser sorting repeats comparison semantics and index-sort structure

Prepared sort keys compare fields at [FileBrowserResults.swift:177](/Users/colin/Programming/Radix/Radix/Services/FileBrowserResults.swift:177). `FileNodeTableComparator` has overlapping comparisons at [FileBrowserSorting.swift:19](/Users/colin/Programming/Radix/Radix/Services/FileBrowserSorting.swift:19). Index allocation and reconstruction also resemble `CancellableSort.sortedByIndex`.

The two-argument `compare` method is required by `SortComparator`, whose value is used by the production table. It is not safe to delete that requirement implementation based on direct-call searches. Any consolidation must retain prepared expensive keys, secondary descriptors, deterministic fallback, and cancellation.

Size ties perform a localized name comparison. A second localized comparison of IDs happens only when the names tie as well.

### 12. Several owners repeat a 512-item threshold for different purposes

The literal occurs in navigation materialization and release decisions at [WorkspaceNavigationModel.swift:435](/Users/colin/Programming/Radix/Radix/ViewModels/WorkspaceNavigationModel.swift:435) and [WorkspaceNavigationModel.swift:660](/Users/colin/Programming/Radix/Radix/ViewModels/WorkspaceNavigationModel.swift:660), and in browser projection and release decisions at [FileBrowserModel.swift:49](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:49) and [FileBrowserModel.swift:388](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:388).

Some uses compare strictly greater than the threshold and others include equality. Naming shared release policy can improve clarity. A single universal constant would also couple materialization, query projection, and background destruction policies that currently have different roles.

### 19. Some localized output limits translators' control over composition

Stats append a fixed `/s` suffix at [StatsSettingsPane.swift:113](/Users/colin/Programming/Radix/Radix/Features/Settings/StatsSettingsPane.swift:113). Warning text joins separately translated sentences with an ASCII space at [ScanWarningsPopover.swift:47](/Users/colin/Programming/Radix/Radix/Shared/ScanWarningsPopover.swift:47) and [ScanWarningsPopover.swift:72](/Users/colin/Programming/Radix/Radix/Shared/ScanWarningsPopover.swift:72).

The components are localized. The composition fixes the suffix and spacing independently of locale. A combined catalog entry or separate text layout would give translators more control. The SI seconds symbol is not inherently invalid in another script, and no incorrect Russian output was observed.

### 23. Comparison preview cleanup depends on how cancellation is routed

Preview `loadingSlot` cleanup uses the generation-gated `onFinish` hook at [AppModel.swift:1440](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:1440) and [ArchiveWorkflowCoordinator.swift:77](/Users/colin/Programming/Radix/Radix/ViewModels/ArchiveWorkflowCoordinator.swift:77).

A bare workflow cancellation can leave that slot set if the setup survives. The current sheet Cancel path also removes setup, and preview failure explicitly clears the slot. Preview work has no progress-banner operation kind, so a generic banner-cancel route is not currently exposed for it.

An idempotent cleanup hook would reduce lifecycle coupling. It must distinguish the preview or generation it owns so an old cleanup cannot clear a replacement preview. This is resilience work, not a reproduced permanent-spinner defect.

### 24 and 42. Several fields and optional API routes have no production reader

The following are removal or simplification candidates, subject to synthesized equality and the tests that currently exercise them.

- Comparison summary `sourceURL` and `rootPath` are per-summary fields at [ScanComparisonService.swift:14](/Users/colin/Programming/Radix/Radix/Services/ScanComparisonService.swift:14). Other comparison outputs retain logical sizes, descendant counts, modification dates, and aggregate parent paths without explicit output consumers. `logicalDelta` is computed, not stored.
- The no-index comparison text matcher at [ScanComparisonQuery.swift:168](/Users/colin/Programming/Radix/Radix/Services/ScanComparisonQuery.swift:168) is bypassed by the default browser processor when text is active. Direct query tests still exercise it. Some comparator fields have no production selection site, while `compare` remains a protocol requirement.
- No caller supplies the `swiftSchema` override at [ScanArchiveModels.swift:35](/Users/colin/Programming/Radix/Radix/Services/ScanArchiveModels.swift:35). The stored schema metadata itself remains part of compatibility behavior.
- `ScanArchiveExportResult.nodeChecksum` has no production reader, but existing archive tests read it. Removing the return value changes that API and its proof.

`attributedAllocatedDelta` also has deliberate coverage semantics and numerous tests. Its absence from the default UI does not make it an unused value throughout the codebase.

### 34 and the containment inventory. Snapshot construction and path checks repeat

Snapshot reconstruction appears in the incremental service, scan coordinator, and snapshot methods. Several services also repeat equal-or-descendant path predicates.

The original containment count included `ScanArchiveNodeIO` calling the validator's helper as if it were another implementation. Some predicates accept only absolute child paths, while others treat `/` as a prefix boundary. The tour predicate has a narrower temporary-directory contract.

A shared helper or snapshot-copy operation needs those contracts stated first. Repeated syntax alone does not justify merging different invariants.

### 52 and 65. Chart and inspector implementations repeat equivalent presentation logic

Chart geometry has repeated grouping and color-role logic. Both charts construct `colorID` equal to `id`, and their canvases repeat discard-pile stroke constants. See [SunburstGeometry.swift:200](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:200), [TreemapGeometry.swift:440](/Users/colin/Programming/Radix/Radix/Services/TreemapGeometry.swift:440), and [TreemapChartCanvases.swift:205](/Users/colin/Programming/Radix/Radix/Features/Visualization/TreemapChartCanvases.swift:205).

Both aggregate labels already use the same localized key. Their translations do not require separate synchronization. A generic lifecycle or overlay is an optional design, not a requirement established by this duplication.

The inspector duplicates `selectionTitle` and several row, menu, and notice patterns at [InspectorMultiSelectionView.swift:118](/Users/colin/Programming/Radix/Radix/Features/Inspector/InspectorMultiSelectionView.swift:118) and [InspectorMultiSelectionView.swift:284](/Users/colin/Programming/Radix/Radix/Features/Inspector/InspectorMultiSelectionView.swift:284).

The selected-ID array allocated by `onChange` at [InspectorMultiSelectionView.swift:244](/Users/colin/Programming/Radix/Radix/Features/Inspector/InspectorMultiSelectionView.swift:244) expresses selection identity. Replacing that key with the entire summary would also close the popover after metadata-only changes, so it is not an equivalent cleanup.

### 53. Two Sunburst fallbacks are unreachable under current construction rules

The aggregate-opacity subtraction at [SunburstChartStyler.swift:94](/Users/colin/Programming/Radix/Radix/Features/Visualization/SunburstChartStyler.swift:94) is bypassed by earlier aggregate returns. The UUID fallback in the aggregate ID at [SunburstGeometry.swift:246](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:246) occurs inside an arm requiring multiple grouped children, so a first child is always available.

These are concrete simplification candidates. The Treemap `cachedFill == nil` fallback is live in SettingsDiskMapPreview. The color-context `contains(where: { _ in true })` checks a generic sequence for an element and is also live behavior.

### 67 and 68. Some convenience wrappers have no production use

Current caller searches support the following candidates.

- `AppModel.revealAfterViewUpdate`, its `NavigationAction.reveal` case, and the corresponding switch arm are transitively unreachable. The direct, nondeferred `addPrimarySelectionToDiscardPile` method and private one-argument stats wrapper also have no callers. See [AppModel.swift:1960](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:1960), [AppModel.swift:2315](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:2315), and [AppModel.swift:3254](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:3254).
- FileTreeStore's Set-based `hasAncestor` convenience method has no external caller. Its Set-based `isNodeOrDescendant` route has test-only callers. See [FileTreeStore.swift:1792](/Users/colin/Programming/Radix/Radix/Models/FileTreeStore.swift:1792) and [FileTreeStore.swift:1824](/Users/colin/Programming/Radix/Radix/Models/FileTreeStore.swift:1824).
- The FileNodeActions convenience `actionAvailability` route has test-only callers and omits read-only state. Production callers supply policy and read-only state through the dedicated availability values.

`SharedAllocationDeduplicator.rebalancedStore` is a live function with a default cancellation argument, not a separate test-only one-argument overload. FileTreeStore calls it at [FileTreeStore.swift:2149](/Users/colin/Programming/Radix/Radix/Models/FileTreeStore.swift:2149). Preserve the function.

The sidebar's explicit post-removal clearing call at [AppModel.swift:912](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:912) is redundant after the preceding observed recents assignment has rebuilt sections and cleared missing targets. The method still has production and test callers, so describe this as redundant sequencing rather than a zero-caller function.

### Atomic summarizer. The lock and accumulator can be simpler

The pool's `NSCondition` at [AtomicDirectorySummaryPool.swift:477](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectorySummaryPool.swift:477) is used only for locking. Worker suspension and wake-up use checked continuations. An `NSLock` would express the implemented mechanism.

The pool's `run(operation:)` convenience method at [AtomicDirectorySummaryPool.swift:570](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectorySummaryPool.swift:570) has no production or test caller. `ScanDirectoryDescriptorPool.cancel` is an alias of `invalidate`, but it has a production caller that must migrate if the alias is removed.

`AtomicSummaryAccumulator` repeats result fields and some merging rules from `AtomicDirectorySummaryPartial`. The types perform different accumulation roles, so they are not byte-for-byte duplicates. A locked partial value could reduce shared field ownership without merging those responsibilities indiscriminately.

### Checked Sendable conformance is available for three declarations

Copied declarations for `IncrementalScanService`, `ScanArchiveProgressReporter`, and `AtomicDirectoryProbeOutcome` passed Swift 6.4 strict-concurrency typechecking after removing only `@unchecked`.

The classes have immutable Sendable fields. The probe outcome is a value type with mutable Sendable fields. Checked conformance would restore compiler checking of future stored-property changes.

This result covers the tested compiler. A production change still needs the project's full build and supported-toolchain validation. It does not justify removing unchecked conformance from lock-protected mutable classes such as `DirectoryNamespaceResolver`.

### Finalization shimmer depends on a localized message as well as phase state

`ScanCurrentPathText.shouldShimmer` tests both `isFinalizing` and equality with a localized summary string at [WorkspaceStateViews.swift:411](/Users/colin/Programming/Radix/Radix/Features/Workspace/WorkspaceStateViews.swift:411).

The flag is already present. The additional string comparison couples presentation behavior to a specific message. An explicit progress-message role could remove that dependency while preserving the distinction between a summary message and other paths shown during finalization.

## Validation for follow-up changes

The findings above are evidence-based candidates, not blanket approval of the original proposed fixes. Existing tests protect behaviors that several discarded recommendations would have changed.

Changes to production code, app resources, or build configuration require the core suite and complete app build from AGENTS.md. Interaction or accessibility changes also require manual validation using this checkout's exact Debug bundle. Performance claims require a relevant measurement. This documentation update changes no app behavior.
