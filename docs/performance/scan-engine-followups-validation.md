# Scan-engine follow-up validation

This run started from merged commit `1814e31` on 2026-10-19. The starting
checkout had unrelated localization edits. Isolated worktrees kept those edits
out of the scan fixes. No proposed PR was merged during this run.

## Build and test receipts

Each production branch passed the full core suite and complete Debug app build.
The combined branch cherry-picked the independent changes for integration.

| Tree | Core tests passed | Debug app |
| --- | --- | --- |
| Clean merged baseline | 1,110 | Built |
| #85 incremental recovery | 1,114 | Built |
| #86 volume case exclusions | 1,116 | Built |
| #87 progress accounting | 1,114 | Built |
| #88 rejected-probe reuse | 1,122 | Built |
| Combined #85 through #88 | 1,136 | Built |
| #89 journal alias fix | 1,115 | Built |
| Combined #85 through #89, initial | 1,141 | Built |
| #85 after review follow-up | 1,116 | Built |
| #86 after review follow-up | 1,122 | Built |
| Combined after review follow-ups | 1,149 | Built |

The original dirty checkout's suite failed on an existing stale localization
catalog entry. Its catalog was preserved. The clean baseline passed. Debug
builds emitted the existing AppIntents metadata warning and completed.

Focused regressions reproduce truncated native and Foundation relists, missing
child metadata, cancellation, Unicode case matching, skipped-entry progress,
and local/root summary retries. Probe tests cover late errors, cancellation,
identity replacement, firmlinks, bounded retention, and descriptor ownership.
Each branch received an independent functional and comment review. Reviews used
separate lenses with the inherited parent model, rather than different models.

Commands for production validation:

```sh
swift test
xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data build
```

## Review follow-ups

GitHub review found issues after the first independent reviews passed. The
original audit below is a historical checkpoint. The subsequent fixes and their
[functional and comment review](scan-engine-review-followups.md) supersede its
code-readiness conclusion for #85 and #86.

The [#85 comment](https://github.com/colinvkim/Radix/pull/85#discussion_r4318612080)
described a startup-volume route that already takes `fullFallback(volumeTarget)`
before event history. A bounded executable probe then exposed a related valid
API case. An explicit folder target at `/` could recover as an inferred volume
and lose `/System/Volumes`. Commit `a10025c` gives both replacement scans folder
scope and preserves the original scan behavior. Its regression failed with the
literal lost path before the fix and passed afterward. Startup-volume fallback
coverage also passes with and without forced `/System` relisting.

The [wildcard finding](https://github.com/colinvkim/Radix/pull/86#discussion_r4318615886)
was confirmed. The actual matcher printed `pattern=* file=false directory=false`
before the fix and `pattern=* file=true directory=true` afterward. Commit
`1fa7061` routes wildcard-only patterns through the existing glob implementation.
This also fixes the preexisting empty-contains case for `**` and `**/` through the
same invariant. Tests check both case policies, both matcher entry points, and
literal retained paths using native and Foundation scans.

The [refresh finding](https://github.com/colinvkim/Radix/pull/86#discussion_r4318615897)
was also confirmed. The baseline factory ran on MainActor once per batch and
blocked the test's UI pulse until its failure watchdog expired. The first fix
at `d0ac3cf` passed local checks but failed the shared Xcode CI plan. The same
controller suite failed locally under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
with 36 issues in 28 tests. Its blocking factory gates depended on later Swift
task progress. This demonstrates cooperative-pool starvation in that test; it
does not prove a real filesystem lookup deadlocked.

Commit `0611a2c` moves synchronous watcher and matcher preparation onto a utility
dispatch queue. The existing MainActor watch task awaits the immutable stream
and matcher, then consumes batches in order. Opening the stream before matcher
construction preserves initial nil-checkpoint events. No mutable cache or
second task handle was added. Already queued or blocked readonly setup may
finish after cancellation. The post-await guard discards that result before
delivery. MainActor batch delivery is synchronous, removing the actor hop.

The existing tests and their 15-second failure watchdog are unchanged. All 28
controller tests now pass under the strict pool, and the focused 53-test run
passes. Coverage includes matcher reuse during navigation and same-ID tree
replacement, buffered initial events, cancellation during preparation,
equal-identity resets, and controller release. All 1,122 core tests, the shared
Xcode test plan, and the complete Debug build passed on the revised branch.
The [CI correction review](scan-engine-ci-review.md) records an independent
functional and comment review of the exact source hash. It found no issue.

Combined integration `42a03c6` passed 1,149 tests in 78 suites and the complete
Debug build. Computer Use then drove its exact Debug bundle with one running
instance. Process-only arguments enabled exclusions `*.log` and `build/` plus
automatic refresh. The fixture initially showed 12 KB, two files, three folders,
and zero warnings. After the visible payload grew to 16 KB and excluded content
grew to 32 KB, automatic refresh showed 20 KB. `Changed` showed 16 KB and
`Untouched` stayed at 4 KB. `Build` and `TRACE.LOG` stayed absent. No Rescan button
was clicked. The test app was stopped and saved exclusion/refresh preferences
were compared before and after; they were unchanged. This live check does not
simulate an unresponsive mounted volume. The blocking factory checks that
execution boundary separately.

All three original review threads were replied to with the fix commits and
resolved. Raw follow-up logs live under `/tmp/radix-scan-review/`. No PR was
merged during the follow-up. The [follow-up evidence audit](scan-engine-review-evidence-audit.md)
preserves the earlier pending-CI checkpoint and the subsequent correction.

## Worker representation

The initial series was inconclusive because setup created new worktrees and
changed package membership during measurement. A fresh series after setup ran
two complete Release scans of `/` at each worker count. All six shared
representation fingerprint `9662a1d72f04ef0b`, warning fingerprint
`01f28c515d62b2e9`, and 956 warning events.

| Round | Workers | Retained nodes |
| --- | --- | --- |
| 1 | 5 | 3,070,401 |
| 1 | 12 | 3,076,426 |
| 1 | 16 | 3,082,693 |
| 2 | 5 | 3,082,791 |
| 2 | 12 | 3,013,114 |
| 2 | 16 | 3,082,998 |

The [selected records](scan-worker-representation-samples.json) retain the
actual comparison fields. `representationFingerprint` hashes package and
summary paths outside `/private/var/folders`. It does not hash ordinary nodes.
Live churn still affects raw totals. These results establish the recorded
representation and warning consistency. They do not prove ordinary-node
completeness or a worker speedup. No worker default changed.

Build a Release binary from the checkout under comparison:

```sh
swift test -c release \
  --filter FullDiskScanScalingBenchmarkTests/testScenarioMatrixCoversCartesianProduct
python3 tools/check-scan-worker-representation.py \
  --checkout "$PWD" --path / --allow-root \
  --output /tmp/radix-worker-comparison
```

The output directory must be new. The tool defaults to `/Applications` and
requires explicit `--allow-root` for `/`. It checks completed scans, all worker
pairs, package/summary fingerprints, and warnings. Recheck the committed records
without scanning:

```sh
python3 tools/check-scan-worker-representation.py \
  --verify-records docs/performance/scan-worker-representation-samples.json
```

The script also drove six completed scans of a small immutable fixture. Offline
checks reject changed warnings, duplicate runs, and missing worker pairs.

## Journal observations

Three baseline rename trials under `/Users` reported both endpoints in the
`/Users` namespace. Every request reached `HistoryDone`. Three equivalent trials
under `/private/tmp` reached `HistoryDone` with empty history. The latter
subscribed to `tmp/...`, although the journal uses `private/tmp/...`.

The combined Debug app reproduced the impact. A `/tmp` fixture initially showed
12 KB. After its `Changed/payload.bin` grew from 8 KB to 16 KB, two rescans
reported no changes and kept 12 KB. This triggered [the separate namespace fix](https://github.com/colinvkim/Radix/pull/89).

The first combined Debug bundle at integration commit `b981ab0` repeated the
operation on a fresh `/tmp` fixture. Exactly one running Radix process matched
that checkout's absolute Debug bundle path. The initial scan showed 12 KB, two
files, three folders, and zero warnings. After file growth, Rescan Entire Scan
reported an update and showed 20 KB. `Changed` showed 16 KB and `Untouched`
remained 4 KB. An unchanged rescan then reported no changes and kept 20 KB.
The UI check used Computer Use. No forced partial-listing hook was exercised.

The fixed provider passed twelve standalone rename trials. Three trials each
under `/tmp`, `/var/tmp`, `/Users`, and explicit Data/private/tmp reported both
endpoints in the caller namespace and reached HistoryDone. The affected suite
also tests `/private/tmp` and an arbitrary symlink root. Its real incremental
rescan changed 12,288 to 20,480 bytes and matched a fresh full tree.

Native descriptor probes confirmed that `F_GETPATH_NOFIRMLINK` supplies a
physical path. Resolving both target and mountpoint is necessary. For example,
`/Volumes/Recovery` and its physical `/System/Volumes/Data/Volumes/Recovery`
spelling differ. Subscription and callback projection belong at the Darwin
provider boundary. The scan's existing paths and IDs remain unchanged. The
[public XNU header](https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-10002.1.13/bsd/sys/fcntl.h)
defines the no-firmlink descriptor operation.

PR #89 includes `tools/FSEventProbe.swift`. Compile and run it from that
checkout with a writable parent directory. It creates and removes only its own
fixture.

```sh
swiftc -parse-as-library Radix/Services/ScanIncrementalModels.swift \
  Radix/Services/FileSystemEventHistory.swift tools/FSEventProbe.swift \
  -o /tmp/radix-fsevents-probe
/tmp/radix-fsevents-probe /tmp
```

The diagnostic probe has a deadline. Production history still has no timeout.
These trial results do not establish universal rename-pair completeness or
HistoryDone availability. Baseline identity checks remain separate from
namespace projection. No claim is made that descriptor capture closes the
pre-existing race between baseline eligibility and later provider setup.

## Performance scope and evidence trail

PR #88 includes its complete-scan script, raw measured samples, resource limits,
and host conditions in `docs/performance/rejected-probe-reuse.md`. Its 10.0%
median improvement applies to one immutable 6,000-file fixture. Full trees,
totals, and warnings matched. Full-disk timing remains unmeasured. The separate
micro timings overlap and are inconclusive by themselves.

The [decision trail](scan-engine-followups-decisions.tsv) is append-only. Its
raw test, build, benchmark, design, and review log references are local artifacts
under `/tmp/radix-scan-work/`. The selected worker and controlled performance
records are committed for durable inspection. Optional optimization work stays
listed in [the remaining work note](../scan-engine-remaining.md).

## Design choices and final attention

Model the Domain separated captured journal prefixes from scan paths. Boundary
Discipline kept their translation inside the Darwin provider. Laziness Protocol
reused the subtree scanner and left planner and live-watcher policies in their
existing owners. Sequence Verifiable Units split regressions, fixes, and larger
changes into independently reviewable commits and PRs. Separate Before
Serializing Shared State put writers in isolated worktrees. Build the Lever
produced rerunnable probes and comparison scripts. Prove It Works required
actual scan results, full-tree fixture equality, and the exact Debug app.

Independent review used the inherited model with separate functional, comment,
and evidence lenses. It does not claim model diversity. The [initial evidence audit](scan-engine-followups-audit.md)
checks the first delivery. The later review follow-ups above record the issues
that escaped those checks and the subsequent verification. It does not rerun every
measurement. Optional performance work, full-disk timing, ordinary-node
completeness, external-disk live history, arbitrary symlink-retarget race
safety, and a production HistoryDone timeout remain outside the verified
claims.
