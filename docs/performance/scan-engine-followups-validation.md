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
| Combined #85 through #89 | 1,141 | Built |

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

The final combined Debug bundle at integration commit `b981ab0` repeated the
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
and evidence lenses. It does not claim model diversity. The [final evidence audit](scan-engine-followups-audit.md)
checks saved receipts and the draft delivery. It does not rerun every
measurement. Optional performance work, full-disk timing, ordinary-node
completeness, external-disk live history, arbitrary symlink-retarget race
safety, and a production HistoryDone timeout remain outside the verified
claims.
