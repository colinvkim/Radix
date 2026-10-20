# PR 86 CI correction review

**PASS. No actionable finding.** This is an independent inherited-model functional and Comment Sicko review. It does not claim a distinct model. Scope is the frozen diff from `d0ac3cf` in `/Users/colin/.codex/worktrees/scan-exclusion-case/Radix`. Only `Radix/ViewModels/FolderRefreshController.swift` changed.

The reviewed file's SHA-256 is `d71c35419c699178cad2a8b101aec282e878bab2040cb76887d557c27a1f9c07`. Its Git diff blob is `467dcb9`. I inspected the source, diff, design/investigation/implementation notes, and recorded test receipts. I ran no builds, tests, benchmarks, source edits, or Git/PR mutations.

## Functional reasoning

The single MainActor watch task now awaits a preparation result at `FolderRefreshController.swift:188`. Its nonisolated static helper at line 209 hides a real execution boundary. The helper schedules both synchronous calls on the global utility dispatch queue at line 218. Stream creation still precedes matcher construction at lines 219 and 220. The checked continuation resumes exactly once at line 221. There is no throwing operation or alternative completion path inside the closure.

The dispatch closure captures a Sendable watcher, URL, checkpoint, strings, and a Sendable synchronous factory. Its returned stream and matcher are Sendable. The watcher protocol, checkpoint model, and matcher declare those contracts in their source. It captures neither the controller nor the scan tree nor WatchIdentity. The identity can therefore return to an ordinary private nested value type at line 12. This does not hide an actor crossing or use an unchecked production conformance.

Package.swift enables MainActor default isolation and NonisolatedNonsendingByDefault. That means the nonisolated async helper itself need not leave the caller's executor. It performs only continuation registration and dispatch scheduling there. The synchronous watcher startup and matcher creation execute inside the explicitly dispatched closure. No claim depends on a plain nonisolated async function changing executors.

The stream-first order preserves initial buffering while matcher preparation blocks. The actual Darwin watcher starts FSEvents synchronously before returning its stream at `Radix/Services/FileSystemChangeWatcher.swift:88`. Its unfolding producer owns the lifetime and cancellation cleanup at line 98. Dropping a prepared stream releases that producer ownership. Native lifecycle was checked from source. The narrow test watcher receipt is not proof of actual FSEvents teardown.

Cancellation remains cooperative across the synchronous preparation boundary. The task checks cancellation before queueing at `FolderRefreshController.swift:187`, after preparation at line 196, and before each batch delivery at line 199. Reset and deinit cancel that same handle at lines 169 and 94. A cancelled queued or running GCD block can still create a readonly watcher and matcher. The continuation then returns them to the cancelled task, which discards them before any delivery. This is an explicit limit, not a claim that DispatchWorkItem or Task cancellation interrupts filesystem calls. The code correctly does not call Task.isCancelled from the dispatch closure to inspect an unrelated Swift task.

MainActor owns stream consumption and receive again at lines 198 to 200. Async iteration suspends while awaiting events. Delivery is synchronous and has no actor hop or suspension between its cancellation guard and receive. Reset cannot interleave within that segment. The earlier queued actor-hop race is therefore removed. The receiver still checks cancellation, identity, and snapshot at line 232.

The outer task captures self weakly at line 186 and promotes it only for one synchronous receive call at line 200. Neither preparation nor a suspended stream iteration retains the controller through a strong local self. If the controller releases during preparation, its deinit can cancel the handle. The task can outlive that controller only until queued or blocked readonly preparation returns. No second Swift task, extra task handle, mutable matcher cache, cancellation token, or generation state was added.

## Evidence and limits

`strict-pool-baseline.log` records 28 controller tests with 36 issues against the detached implementation. The synchronous factory gates and other sessions timed out together. That supports starvation caused by the demonstrated test dependency on future Swift task progress. It does not prove that a real native metadata lookup deadlocked or caused the original CI stall by itself.

`ci86-strict-green.log` records the unchanged controller tests passing under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, with 28 tests in one suite. `ci86-focused-green.log` records 53 tests passing in four suites. The diff contains no test or timeout changes. These receipts directly cover the factory gate/MainActor pulse, stream-before-build buffering, one matcher per session, replacement and same-identity cancellation during blocked preparation, and weak controller release.

The cancellation test forces cancellation during preparation, not while a dispatch block is queued behind another block. The same post-await cancellation guard covers either state by source reasoning. Native watcher shutdown, indefinitely blocked filesystem APIs, full core suites, the shared Xcode test plan, complete app build, and manual Debug app behavior are outside this review's executed evidence. The parent owns those checks. This review makes no latency or speedup claim.

## Comment Sicko

No source comment, suppression directive, constraint comment, or workaround explanation was added. Deletions are zero. Restores are zero. MUST KILL flags are zero. Existing unchanged comments were kept outside this diff's review scope. No encoding offer is needed.

## Principles applied

Test Behavior, Not Implementation made the unchanged strict-pool regression and literal downstream refresh requests the evidence instead of a compile result. Minimize Reader Load favored one helper that explains the blocking execution boundary and a tuple consumed at its only caller. Both leaf skills were read during this review.
