# Preparing short names for scan sorting

## Decision

Prepare Foundation-backed names once when sorting a directory with at least
1,024 children, all with the same allocated size and names of at most 15 UTF-8
bytes. Short native Swift strings otherwise bridge to `NSString` repeatedly
during `localizedStandardCompare`. Sorting temporary `(key, name)` entries
avoids that repeated work. The allocated sizes are already tied, so this path
needs only the existing name comparator.

Other directories use the original size/name sort. The eligibility check stops
at the first unequal size or longer name. Preparation and writeback check
cancellation every 256 entries; the existing cancellable sort checks throughout
comparison. Record names, URLs, IDs, metadata, localized ordering and stable
ordering of equivalent names are unchanged.

## Rejected broader changes

Preparing entries for every large directory was too broad. A Release probe
using real `FileNodeRecord` values and the cancellable comparator measured
40,000 uniquely sized short-name records sorting in 21.2 → 36.8 ms, and longer
names with 16 size groups in 109.2 → 121.7 ms. The narrower implementation
avoids those costs: the corresponding measurements were 19.8 → 19.9 ms and
104.8 → 104.4 ms. Equal-size short names improved from 122.0 → 101.2 ms.
Every probe checked exact sorted-key parity. These are sorting measurements,
not whole-scan times.

Replacing the discovery parent dictionary with an array showed no meaningful
Unicode-path improvement and required more temporary memory. A last-parent
cache also showed no convincing gain. Neither was adopted.

## Whole-scan measurements

The baseline is `35608e8`. Measurements used Apple Swift 6.4 on arm64 macOS
27.0.1, separate Release processes, five measured pairs after warmup and
alternating revision order. Traversal, classification and summary workers were
fixed at four. Timing ends after snapshot publication. Both revisions used the
same unchanged inputs.

| Input | Baseline, ms | Candidate, ms | Median paired wall change |
| --- | ---: | ---: | ---: |
| 40,000 short ASCII filenames | 229.0 | 205.6 | -10.5% |
| 40,000 short Unicode filenames | 397.7 | 380.0 | -4.6% |
| 400 directories × 100 files | 137.3 | 138.5 | +0.7% |
| Same fanout under 24 Unicode path levels | 431.5 | 432.4 | -0.2% |
| 5,000 directories × 1 file | 186.9 | 195.5 | +5.0% |
| SDK, expanded | 331.6 | 332.4 | +0.4% |
| SDK, default summaries | 387.0 | 387.7 | +0.1% |
| Real project, default summaries | 203.3 | 202.7 | +0.4% |

The short-name cases improved finalization by 19.0% and 11.0%, and CPU time by
9.8% and 4.2%, respectively, using medians of adjacent pair changes. Their
median peak RSS increased by about 1.9 and 1.7 MiB. Retained live allocation
growth stayed effectively unchanged: the extra sorting storage is temporary.

Earlier broad-candidate measurements fluctuated on ordinary workloads. An
apparent SDK/default-summary slowdown did not repeat in nine additional pairs
and is absent in the final narrowed matrix. The sparse slowdown also did not
repeat: nine additional pairs measured 186.3 → 187.8 ms, with a median paired
wall change of +0.4% and CPU change of +0.7%. Small differences on ordinary
workloads should not be presented as gains or repeatable regressions.

## Validation and reproduction

All 971 core tests pass, and the complete Debug app builds. The scan benchmark
requires exact parity of node counts, allocated/logical totals, warnings and
complete result/warning fingerprints, including child ordering, in every
process. Every final matrix pair passed those checks.

Build each revision in its own Release scratch directory and run the existing
`ScanDiscoveryBenchmarkTests/testDirectScan` harness in fresh processes. For
example, against an unchanged folder of small files:

```sh
rtk proxy swift test -c release --scratch-path .build/scan-candidate \
  --filter ScanDiscoveryBenchmarkTests
RADIX_BENCH_SCAN_PATH=/path/to/files \
RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS=4 \
RADIX_SCAN_DIRECTORY_CLASSIFICATION_WORKERS=4 \
RADIX_SCAN_ATOMIC_SUMMARY_WORKERS=4 \
rtk proxy swift test -c release --skip-build --scratch-path .build/scan-candidate \
  --filter ScanDiscoveryBenchmarkTests/testDirectScan
```

Use `RADIX_BENCH_SCAN_SUMMARIZE=1` for default summaries. Alternate revision
order and discard the warmup pair. Compare adjacent-pair ratios as well as
separate medians; host activity can distort either result.

Raw probes, build logs, fixture generator and fixture paths are retained in
`.build/scan-perf-followup/`. Matrix scripts, per-process logs and
`sort-narrow-{results,summary}.json` and
`sort-narrow-sparse-confirm-{results,summary}.json` are in
`.build/selective-scan-production/`. Generated filesystem fixtures were removed;
the retained generator recreates them independently of those artifacts.

## Limits

This targets large size ties with short names. It does not reduce retained
tree memory or accelerate arbitrary directories. Eligible directories use
additional temporary storage, and eligibility adds a cancellable linear pass
over a large directory. The 1,024-child cutoff is conservative,
not a measured optimal crossover. Bridging behavior and performance may change
with the Swift/Foundation toolchain; the same comparator remains correct.
Measurements on one machine cannot prove absence of a slowdown on every input.
