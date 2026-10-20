# Scan engine remaining work

Updated 2026-10-19 after the follow-up to the 2026-10-18 review. PRs #78 through
#90 are merged. The table below records the delivered fixes.
Historical review line numbers refer to `b69254d`.

## Follow-up delivery

| Work | Merged PR | Result |
| --- | --- | --- |
| Bug 5. Incomplete incremental child listings | [#85](https://github.com/colinvkim/Radix/pull/85) | Recover the affected directory with the existing subtree scanner. Validate its identity before splicing. Replacement scopes preserve folder kind and the original scan behavior. Other unsafe conditions still cause a full scan. |
| Bug 4. Exclusion case on insensitive volumes | [#86](https://github.com/colinvkim/Radix/pull/86) | Resolve volume case behavior once. Preserve original paths and wildcard character boundaries, including Unicode expansions. Wildcard-only rules use the general glob matcher. Watch sessions prepare one matcher on a utility dispatch queue. |
| Bugs 6 and 7. Skipped-entry cadence and retry progress | [#87](https://github.com/colinvkim/Radix/pull/87) | Publish progress from completed work. Keep summary retry counts at their high-water mark. |
| Performance item 6. Rejected probe double walks | [#88](https://github.com/colinvkim/Radix/pull/88) | Finish eligible active listings within a 65,536-entry per-probe retention budget. Rejected results keep no descriptor. |
| Journal aliases found during manual testing | [#89](https://github.com/colinvkim/Radix/pull/89) | Subscribe in the device namespace and project events back into the existing scan namespace. `/tmp` previously returned empty history after real changes. |

The earlier combined candidate passed 1,149 core tests and the complete Debug
app build after the CI correction. The revised #86 branch also passed the shared
Xcode test plan and the unchanged strict thread-pool regressions. The exact app
refreshed from 12 KB to 20 KB while `Build` and `TRACE.LOG` stayed excluded. The earlier
manual `/tmp` rescan check also passed before these follow-ups.

The rejected-probe change reduced complete-scan median time by 10.0% on a
controlled 6,000-file fixture. Full trees, totals, and warnings matched the
baseline in all five alternating pairs. Full-disk timing remains unmeasured.
See [measurement and limits](https://github.com/colinvkim/Radix/blob/54656cc/docs/performance/rejected-probe-reuse.md) in PR #88.

[Validation receipts](performance/scan-engine-followups-validation.md) record
baseline and individual checks, worker comparisons, and journal observations.
The [decision trail](performance/scan-engine-followups-decisions.tsv) preserves
the order of decisions. Raw local logs referenced there live under
`/tmp/radix-scan-work/` or `/tmp/radix-scan-review/` and are not committed.

## History wait deadline

Production history waits now have a ten-second deadline. Missing completion
causes the existing full-scan fallback. User cancellation remains cancellation.
Collector regressions and a temporary native HistoryDone fault verified both
paths, including a fallback tree equal to a fresh scan. The deadline does not
interrupt synchronous filesystem setup or bound the fallback scan. This follow-up
passed 1,152 core tests and the complete Debug app build.

## Housekeeping completed

- Clean merged baseline `1814e31` passed 1,110 core tests and the complete Debug
  app build. The starting checkout's unrelated catalog edits were preserved.
- The listed obsolete branches and worktrees are absent. The remaining
  throwaway `probe-package-lookup` worktree was removed after saving its dirty
  instrumentation patch locally. Its instrumentation was not committed.
- The five follow-up worktrees and seven task branches were removed after the
  PRs merged. The main checkout was updated and the unrelated catalog edits
  were preserved.

## Optional performance work

The original note makes these items optional. No worker default changed.
Earlier worker measurements found no wall-time win on this SSD. Earlier,
unrelated work already narrowed sibling sorting and Unicode discovery keys in
`performance/scan-directory-sorting.md` and
`performance/selective-scan-discovery.md`.

### Item 4. sibling sort still bridges to `NSString` on many size ties

Optional; partly done.

`allocatedSize` is 4 KiB quantized, so ties are common. The existing optimization only prepares names when a directory has at least 1,024 children, *all* the same size, and names of at most 15 UTF-8 bytes. Other ties still call `localizedStandardCompare` per comparison (`ScanEngine.swift`). Measure: `testSiblingSortFieldAccessBenchmark` with `RADIX_BENCH_SCAN_SORT=1`, diagnostics op `scan.finalize.assemble`.

### Item 3. per-entry URL and name derivation

Optional.

Each bulk entry builds a URL and display name (`BulkDirectoryEnumerator`, `ScanEngine`, `ScanTarget.displayName`). Measure: `testNativeEnumerationAllocationBenchmark`, `testLeafPreparationPathBenchmark`, `testPathStorageBenchmark`.

### Item 5. serial parent work per directory and per entry

Optional; Unicode path keys already improved.

Still in the original notes: `recalculateProgress` on every directory completion; wide-directory expansion blocking `group.next`; leaf batches retaining the full child array; `ScanPathIndex` hashing full ASCII paths. Measure `scan.traverse` vs summed `directory.enumerate`.

### Item 7. leaving the bulk path is expensive

Optional.

Foundation metadata, lstat fallbacks, and probes that cannot resume (`ScanMetadataLoader`, `BulkDirectoryEnumerator`). Measure: `testMetadataReadAuditBenchmark`, diagnostics op `metadata.lstat`.

### Item 8. each rescan splice copies the whole tree

Optional; measured on warm local APFS.

A 1% rescan of a 100,001-file baseline took a median 40.1 ms (39.5 to 41.4 ms),
versus 392.0 ms (389.9 to 409.1 ms) for a full scan. An isolated replacement of
the same subtree took 32.2 ms (31.3 to 32.4 ms). A synthetic million-file tree
splice took 251.4 ms (248.9 to 253.7 ms). Each series discarded one warmup and
retained five measured samples. Real-file results matched fresh full-scan records
and topology. Their baseline fingerprints stayed unchanged and still lacked the
new path. Synthetic results and baselines matched complete independent expectations.

These backend measurements use injected history and exclude app coordination,
UI work, and cold metadata. The separate splice timer does not exactly decompose
the complete rescan. No storage rewrite is proposed from these absolute costs.
`FileTreeStore.replacingSubtrees` / `combining` remain future targets if user wait
or larger-tree measurements justify them. `testIncrementalRescanBenchmark`
provides the existing benchmark entry point.

### Item 9. non-membership directory events deep-scan the subtree

Optional. Needs a benchmark first.

`IncrementalRescanPlanner` deep-scans on those events instead of a shallow relist.

### Item 10. FSEvents history is fully materialized before the breadth check

Optional. Needs a benchmark first.

`FileSystemEventHistory` plus the planner load the whole history before deciding the event set is too wide.

### Further package-lookup trims (optional, small)

#83 left ~28 k Foundation lookups per full scan of `/`. Next candidates from that tally, each under 1% of lookups, all zero packages on this disk:

| Folders | Extension |
|---|---|
| 726 | `noindex` |
| 686 | `metalfe` |
| 632 | `axbundle` |

Any addition must keep the `Contents/PkgInfo` guard and pass a full-disk disagreement check of 0 against per-directory Foundation.

`#83` saved more CPU than the removed lookups took. That is either noise or Foundation contention slowing other workers. A profile would tell whether more trims are worth it.

## Verification still open

- **Ordinary-node completeness at 12/16 workers.** Two fresh Release scans at
  each of 5, 12, and 16 workers share package/auto-summary representation and
  warning fingerprints. The representation hash excludes `/private/var/folders`
  and does not hash ordinary nodes. Raw retained counts still vary with live
  churn. These runs establish the recorded representation consistency, not the
  absence of ordinary-node loss. An immutable full-tree comparison would close
  the broader question.
- **Full-disk rejected-probe timing.** The controlled complete-scan win does not
  establish a full-disk gain. Large over-budget listings can still incur
  read-ahead and a second walk. The entry budget is not a global byte or I/O cap.
- **In-app partial-listing display for #82.** Core tests cover kept children and
  inaccessible-folder state. Forcing its test hook in the Debug UI remains
  optional.
- **Mid-listing `getattrlistbulk` errnos on local APFS.** The tests inject these
  failures. Their natural incidence on this disk remains unmeasured.
- **Rename completeness.** Three real `/Users` trials reported both endpoints.
  That does not establish a universal guarantee for all rename histories.
- **Journal path spellings.** The `/tmp` manual check exposed a real alias bug.
  Keep physical device subscriptions separate from scan IDs. Twelve post-fix rename trials passed across `/tmp`, `/var/tmp`, `/Users`, and
  an explicit Data spelling. This does not establish every mounted-volume
  namespace. The probe deadline is documented with the validation.
- **HistoryDone availability.** Universal completion remains unverified. The
  history deadline now recovers from a missing completion signal.
- **Borderline auto-summary order.** Listing order may still move directories
  near thresholds between summarized and expanded representations.
- **Worker saturation elsewhere.** Other disks and machines remain unmeasured.
- **Bug 9. Temporary-tree churn.** `$TMPDIR` can change retained counts and scan
  time. #84 excludes it from the representation comparison only. A dedicated
  immutable fixture is needed for general tree equality.

## Immediate auto-summary classification

The immediate-file decision now averages all already-loaded child metadata.
Controlled listing permutations keep the same expanded representation, exact
paths, totals, and warnings on unchanged 200-file and 5,000-file fixtures. The
bounded descendant probe remains order-sensitive.

Five alternating Release pairs on a homogeneous 5,000-file cache produced matching
tree fingerprints and totals. Complete-scan timing was inconclusive. The baseline
median was 18.3 ms
(range 14.3 to 26.1 ms), and the candidate median was 19.4 ms (13.3 to 31.6 ms).
The complete-scan limiter was not profiled. Reading all metadata adds linear CPU
work but no filesystem reads. These measurements do not establish full-disk cost.
The summary follow-up passed 1,150 core tests and the complete Debug app build.

## Already merged

| PR | Change |
| --- | --- |
| [#78](https://github.com/colinvkim/Radix/pull/78) | Keep firmlinked children in folder scans. |
| [#79](https://github.com/colinvkim/Radix/pull/79) | Skip extensionless Foundation package lookup. |
| [#80](https://github.com/colinvkim/Radix/pull/80) | Classify packages per directory with the `.lproj` and `Contents/PkgInfo` guards. |
| [#81](https://github.com/colinvkim/Radix/pull/81) | Validate identity on path-based directory opens, including auto-summary firmlinks. |
| [#82](https://github.com/colinvkim/Radix/pull/82) | Keep entries read before a later bulk-listing failure. |
| [#83](https://github.com/colinvkim/Radix/pull/83) | Reject known non-package extensions quickly. |
| [#84](https://github.com/colinvkim/Radix/pull/84) | Add a package/summary representation fingerprint excluding temporary churn. |

## Looked at and dropped

The earlier review retained root-stat failure as an abort, the Int64 byte sum
whose overflow requires more than 8 EB, APFS canonical-name behavior, and
symlink directory-pattern differences that affect no scanned bytes.
Case-sensitive planner scope checks remain conservative full-scan fallbacks.
