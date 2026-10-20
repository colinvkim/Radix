# Independent review of PR 85 and PR 86 follow-ups

This is a read-only functional and Comment Sicko review from an independent inherited-model lens. It does not claim a different model. I inspected source, diffs, and recorded runs. I ran no tests, builds, benchmarks, or Git/PR mutations. Parent validation is separate.

## PR 85

**PASS. No actionable finding.** The frozen review scope is the diff from `7dbc504` in `/Users/colin/.codex/worktrees/scan-progress-counts/Radix`.

Both incremental replacement routes now pass an explicit folder scope and the original scan behavior. The deep replacement route is at `Radix/Services/IncrementalScanService.swift:341`. The shared incomplete-listing/new-child replacement helper is at line 638. They reuse the existing engine overload rather than introducing another recovery mechanism.

The distinction matters. `ScanEngine.performScan` takes startup-volume exclusions from the preserved scan target at `Radix/Services/ScanEngine.swift:1087`. Capacity accounting takes the replacement scope's kind at line 1202. Passing only the preserved target would still leave an inferred volume scope. Passing only `.folder` would still discard the original behavior. The new calls express both existing contracts.

The review comment's ordinary startup-volume route remains unreachable. `incrementalRescanEligibility` rejects volume targets at `Radix/Services/IncrementalScanService.swift:716` and checks baseline/requested kind equality at line 719. Both rescan entry points use this eligibility owner before requesting history. Direct folder refresh already forwards the original target through `scanSubtree` at line 51.

The actual recovered-folder defect is covered at `RadixCoreTests/IncrementalScanServiceTests.swift:98`. It uses actual root/System/Volumes directory metadata with a bounded injected listing. It forces incomplete metadata on the second root visit and requires exactly three root visits, `.incremental`, no capacity, zero allocated bytes, and literal retained paths `[/, /System, /System/Volumes]`. The added volume test at line 149 covers ordinary and forced-parent requests, requires `.fullFallback(.volumeTarget)`, zero history requests, the retained System directory, and absent Volumes directory. These checks would fail with an empty result or full-scan substitution in the recovery regression.

Recorded evidence supports the defect and correction. `review85-red.log` loses `/System/Volumes` before the fix. `review85-parent-repro.log` independently observes that loss and confirms the volume fallback. `review85-green.log` passes the narrow cases. `review85-affected-final.log` passes 34 tests in three suites. I inspected these receipts rather than rerunning them.

## PR 86

**PASS. No actionable finding.** The frozen review scope is the diff from `3aa1652` in `/Users/colin/.codex/worktrees/scan-exclusion-case/Radix`.

`Radix/Services/ScanExclusionMatcher.swift:302` routes every all-star basename pattern into the existing general compiler. It fixes the empty suffix for `*` and the empty contains string for `**`. Directory-only normalization remains in `CompiledPattern`. The compiler itself is unchanged. Its wildcard tokens consume original Characters at lines 424 and 429. Path stars retain their existing slash policy at lines 366 to 372. No pre-folding or new Unicode comparison path was added.

`RadixCoreTests/ScanExclusionMatcherTests.swift:7` covers `*`, `**`, `*/`, and `**/` across both explicit case policies, both entrypoints, nested parents, files, and directories. It includes an original Unicode name. `RadixCoreTests/ScanExclusionVolumeTests.swift:8` checks literal complete retained-tree membership through both native and forced Foundation scans. The existing Unicode expansion, question-mark, root-boundary, and slash tests remain in scope of the recorded focused run. The wildcard baseline receipt prints false matches. `wildcard-red.log` records 44 failed assertions. `wildcard-fixed.log` prints the corrected file/directory behavior.

`Radix/ViewModels/FolderRefreshController.swift:186` gives one detached task ownership of synchronous watcher startup, one matcher construction, and the stream. Startup precedes construction at lines 188 to 192. That keeps a nil-checkpoint observer from starting after a slow lookup and lets the actual watcher mailbox buffer the initial changes. The real watcher implementation starts FSEvents synchronously before returning its stream at `Radix/Services/FileSystemChangeWatcher.swift:88`. Its producer closure owns the cancellation lifetime at line 98, so returning early drops that ownership. This lifecycle was checked in source. The narrow fixture is not proof of actual FSEvents shutdown.

The session captures immutable options instead of the snapshot tree. `WatchIdentity` is a nonisolated Sendable value at `FolderRefreshController.swift:12`; its fields already have Sendable types. The only new stored dependency is a synchronous Sendable matcher factory. The matcher stays local to the task rather than adding a mutable cache, session generation, or second task handle. Both watcher startup and matcher construction leave MainActor. Filtering and scheduling remain on MainActor.

The old task cannot deliver stale events after reset. Cancellation checks run before startup, after startup, after construction, before the actor hop, and inside `receive` at `FolderRefreshController.swift:212`. The last check uses the same calling task after actor scheduling. It rejects an old queued delivery even if the identity changes from A to nil and back to A before that delivery runs. This queued-hop result is source reasoning, not a forced runtime interleaving. Weak self is only promoted during each delivery at line 197. It is not held across stream iteration, so the task cannot permanently retain its controller.

The off-main regression at `RadixCoreTests/FolderRefreshControllerTests.swift:9` blocks the synchronous factory and observes a MainActor pulse before releasing it. It also checks stream-before-build with a nil checkpoint and a subsequent literal Downloads refresh. The reuse regression at line 50 requires case-insensitive exclusions to suppress two events, then requires an included event to refresh Downloads. It verifies one construction across batches, focus navigation, and same-ID tree replacement. These downstream checks reject an implementation that simply drops all events.

The cancellation regression at line 82 cancels blocked preparation and starts a replacement session. It covers different identities and A/nil/A, waits for the old stream's cancellation receipt, then requires a current event to refresh. It does not force cancellation after an actor delivery is queued. The release regression at line 123 requires a weak controller to clear and its fixture stream to cancel. Its factory-completed receipt does not guarantee that the task has already suspended in `next`; weak-self lifetime correctness is also verified directly in the source.

The private factory at `FolderRefreshControllerTests.swift:721` protects mutable state with NSCondition. Its first-build wait has a fixed 15-second failure deadline and guaranteed defer releases in callers. It does not leave an unbounded gate on MainActor. The private buffered watcher at line 778 protects receipts and continuation access with NSLock. Its cancellation closure captures it weakly. The shared test fixture was not changed. Its next-batch acknowledgement still follows the awaited synchronous actor receiver, so existing processing receipts keep their meaning.

`refresh-red.log` shows the old code constructed matchers and started watchers on MainActor, hit the bounded gate, and built three matchers for three batches. The final `focused-green-final.log` records 53 passing tests in four suites. The final watchdog is 15 seconds while the earlier red run used 3 seconds. Both expose the same synchronous block, but they are not identical gate configurations. No responsiveness latency claim is made from either run. I also inspected `git diff --check`, which returned clean.

Synchronous native metadata lookup remains cooperatively cancellable. A cancellation can wait for the filesystem call to return before releasing its stream. MainActor is still available. This is a platform limit of the chosen synchronous API, not evidence of immediate lookup interruption. Full suites, app builds, and the exact Debug app check belong to the parent and are not claimed by this review.

## Comment Sicko

The reviewed production additions and test additions introduce no source comments, suppression directives, or constraint comments. Deletions are zero. Restores are zero. `MUST KILL` flags are zero. Existing comments outside the added or changed lines were not treated as new review scope. No encoding offer is needed.

## Principles applied

Test Behavior, Not Implementation made the exact retained paths and downstream refresh requests the acceptance evidence. Construction/thread receipts are relevant boundary checks alongside those user-visible effects. Minimize Reader Load favored the existing scope/behavior API and a matcher local to the single watch task. Both leaf skills were read during this review.
