# Review follow-up evidence audit

PASS for the saved follow-up evidence and draft documentation. No actionable factual or scope finding was found. PR 86 CI is still pending in the latest saved status receipt. That remains a handoff condition, not a completed check.

This audit uses an independent evidence lens with the inherited parent model. It does not claim a different model. It reads saved logs, local source and commit history, review replies/status snapshots, draft documents, and the parent-provided run context. It does not have the complete preceding parent tool transcript. No tests, builds, scans, benchmarks, app interactions, source changes, git/PR mutations, or subagents ran. The only written artifact is this report.

## Escaped cases and historical claims

The draft correctly acknowledges that the earlier independent reviews and evidence audit missed cases subsequently exposed by GitHub review. It preserves the original audit as a historical checkpoint and explicitly supersedes its code-readiness conclusion for PRs 85 and 86. The appended trail does not rewrite the earlier PASS into a stronger guarantee or conceal the subsequent failures.

The PR 85 account distinguishes the review's guarded startup-volume route from the real folder-root recovery defect. `review85-parent-repro.log` records volume targets taking `fullFallback(volumeTarget)` without history, including the forced-parent case. It separately records `/System/Volumes` disappearing during recovery of an explicit folder target at `/`. `review85-red.log` shows the literal missing node and node-set mismatch. The latest integration source passes explicit `.folder` scope and the original target's behavior to both replacement routes. The documentation and reply describe that narrower defect accurately.

The wildcard defect has direct baseline and corrected executable receipts. `wildcard-baseline.log` records false matches for `*`, `*/`, and `**`. `wildcard-fixed.log` records the intended file/directory distinctions after the change. `wildcard-red.log` ends with 44 failed assertions, including literal retained-tree mismatches. The latest source routes all-star patterns through the existing glob compiler. The documents accurately describe one invariant covering the empty-suffix and preexisting empty-contains cases.

`refresh-red.log` records MainActor construction and three matcher constructions for three batches. The final focused receipt passes 53 tests. The documents correctly treat the bounded blocking gate as a responsiveness boundary check rather than a measured latency improvement. The earlier red gate and final gate use different watchdog durations, as the functional review discloses. No benchmark comparison is inferred from them.

The latest source starts one detached watch task, opens its stream before building the immutable matcher, reuses that matcher, and checks cancellation again inside actor delivery. The docs preserve the relevant limits. Queued actor-hop cancellation is source reasoning rather than a forced runtime interleaving. A synchronous native filesystem call can remain blocked until it returns. The live app test does not simulate an unresponsive mounted volume.

## Completed validation receipts

These are observed saved results, not reviewer reruns.

| Tree | Full core suite | Complete Debug app build |
| --- | --- | --- |
| PR 85 follow-up | 1,116 tests passed | Succeeded |
| PR 86 follow-up | 1,122 tests passed | Succeeded |
| Combined integration `02c5634` | 1,149 tests in 78 suites passed | Succeeded |

The receipts are `review85-full-tests.log`, `review85-debug-build.log`, `review86-full-tests.log`, `review86-debug-build.log`, `integration-tests.log`, and `integration-debug-build.log` under `/tmp/radix-scan-review/`. The draft's updated table and latest combined count match them. The independent functional/comment report records PASS and clearly leaves full-suite and app verification to these later parent receipts.

`manual-instance.log` records one process, PID 21890, running the integration checkout's exact absolute Debug executable. Its process-only launch arguments enabled `*.log`, `build/`, and automatic refresh. `manual.log` summarizes actual Computer Use observations. The initial scan showed 12 KB, two files, three folders, and zero warnings. After file growth, automatic refresh showed 20 KB with Changed at 16 KB and Untouched at 4 KB. Build and TRACE.LOG remained absent. No Rescan button was clicked. The before/after preference JSONs contain identical selected saved values. The parent receipt states that the test app was stopped. This is an owner-written accessibility-output summary, not an exported screenshot or an independent reviewer UI run. The draft does not claim otherwise.

## Review delivery and CI

The saved reply-response JSONs contain actual GitHub reply IDs, timestamps, and fix descriptions for all three original threads. The later status snapshots show no unresolved threads on PRs 85 or 86. The separate resolve JSON files contain mutation requests and are not, by themselves, completion receipts. The status snapshots supply the later observed unresolved-thread state.

The PR 85 snapshot at `2026-10-20T02:17:14.127Z` identifies head `a10025c`, an open mergeable PR, passing tests, completed CodeRabbit review, and CI clean. The PR 86 snapshot at `2026-10-20T02:17:16.194Z` identifies head `d0ac3cf`, an open mergeable PR, completed CodeRabbit review, and tests still IN_PROGRESS. Neither receipt records a merge. The draft does not claim PR 86 CI has finished.

The draft documentation adds the three confirmed review issues, new validation counts, exact automatic-refresh result, and explicit verification limits. Its append-only trail records the renewed triage, chosen watcher ownership, fixes, integration, and manual check. The copied functional review preserves its evidence provenance and source-versus-runtime distinctions. The original optional performance and completeness limits remain intact.

## Attention

Reviewed by the inherited parent model with an independent evidence lens.

- PR 86 tests were still running in the latest saved CI snapshot. Do not report CI complete without a later receipt.
- The first reviews missed the recovered-folder edge, wildcard-only rules, and MainActor matcher preparation. The new drafts acknowledge those escapes. Passing review and test receipts remain scoped evidence, not a guarantee that all cases are covered.
- Native synchronous lookup interruption and the queued actor-hop cancellation interleaving remain bounded by the source/test limits documented above.

## CI correction checkpoint, 2026-10-19

PASS for the local correction evidence at PR 86 source `0611a2c` and combined
integration `42a03c6`. This dated checkpoint supersedes the detached-task
execution description above. The earlier audit remains a historical record of
the locally passing implementation that later failed CI.

The shared Xcode CI failure is saved in `pr86-ci-failure.log`. The local strict
cooperative-pool reproduction failed with 36 issues across 28 controller tests.
Those tests demonstrated a blocking dependency on future Swift task progress.
They do not establish that an actual native metadata lookup deadlocked.

The correction changes only `FolderRefreshController.swift`. Tests, assertions,
and their 15-second watchdog remain unchanged. The existing MainActor watch
task now awaits synchronous watcher and matcher preparation dispatched to the
utility queue, then consumes and delivers batches synchronously on MainActor.
Stream creation still precedes matcher construction. The actor delivery hop is
removed. Queued or blocked readonly setup can finish after cancellation, and
the post-await guard discards that result before any delivery.

Saved receipts under `/tmp/radix-scan-review/` show 28 unchanged strict-pool
controller tests passing, 1,122 core tests passing, and the full shared Xcode
plan passing 1,122 tests with `TEST SUCCEEDED`. The revised branch's complete
Debug build also passed. Combined integration `42a03c6` passed 1,149 tests and
its complete Debug build. The independent frozen-source review records PASS
for source blob `467dcb9`. This evidence audit inspected those saved results
and the one-file commit. It did not rerun tests or builds.

The repeated Computer Use receipt identifies one exact integration Debug
process, PID 25133. The UI automatically updated from 12 KB to 20 KB after file
growth, with Changed at 16 KB, Untouched at 4 KB, and zero warnings. Build and
TRACE.LOG remained excluded. No Rescan button was clicked. Selected saved
preference keys compared equal before and after, and the test app was stopped.
The manual receipt summarizes actual accessibility output rather than an
exported screenshot or a reviewer rerun. It does not simulate an unresponsive
mounted volume.

The minor PR 90 bookkeeping correction is valid. The earlier publication
instruction is now marked as a historical delivery checkpoint and points to
the already published documentation PR. The original review history remains.

The latest saved remote status, observed at `2026-10-20T02:32:42.217Z`, identifies
head `0611a2c` with no unresolved threads. Tests were IN_PROGRESS and CodeRabbit
was PENDING. Local shared-plan success does not establish remote CI clean.
Later status checks remain with the root owner.

### Attention at this checkpoint

Reviewed by the inherited parent model with an independent evidence lens.

- No actionable factual or scope finding in the correction draft. Remote tests
  and CodeRabbit remained pending at the saved checkpoint.
- Native synchronous setup can outlive cancellation until it returns. The
  post-await guard covers queued cancellation by source reasoning. The live UI
  check does not prove behavior on an unresponsive mounted volume.
- Earlier passing reviews missed real cases and a scheduler constraint. They
  remain scoped historical evidence, not a guarantee of complete coverage.
