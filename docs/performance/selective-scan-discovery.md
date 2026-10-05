# Selective scan discovery keys

## Decision

Use parent namespace + basename keys for duplicate discovery under Unicode
directory prefixes. Keep the existing full-path dictionary for ASCII prefixes,
and retain every record's original URL and external path ID. This extracts the
scan-speed benefit independently of the compact-tree memory experiments.

`ScanPathIndex` interns directory prefixes using Swift String equality and
checks a known parent's UTF-8 prefix before copying only the basename. Parent
indices are hints: unexpected entries resolve their actual path namespace.
Canonical equivalence remains global, including composed/decomposed spellings
and the Kelvin sign's equivalence to ASCII K. ASCII-equivalent prefixes always
keep full-path keys. A first Unicode directory activates the alternate route;
previous unexpected Unicode discoveries migrate once. Parent prefix buffers
are created only when that route first needs them.

Discovery-only state is released before tree assembly. Final lookup indexing
reuses the ASCII dictionary and inserts retained full IDs for Unicode entries.
Progress now covers both assembly and lookup indexing, with cancellation checks
throughout. Stored URLs, metadata, tree layout and traversal options are retained.

## Validation

The extracted production implementation passes all 971 normal core tests and
builds the complete Debug app. Tests cover duplicate equality with incorrect
parent hints, late Unicode activation, final offsets, progress through both
finalization passes and cancellation during indexing. Release comparisons check
node counts, allocated/logical totals, warnings and complete result/warning
fingerprints in every process.

The synthetic fixtures cover 100,000 files in one directory; 1,000 directories
with 100 files each; the same fanout under 24 Unicode directory levels; 20,000
directories with one file each; and 100 packages with Unicode/reserved names
and a symlink. Real inputs are the active macOS SDK, expanded and with default
summaries, and `/Users/colin/Programming/Recount` with default summaries.

The app was exercised using this checkout's exact Debug bundle: completed scan,
rescan, cancellation, and reuse of a recent scan. The fixture scan finished with
340,004 files, 22,130 folders and zero warnings.

## Measured scan speed

Five measured rounds plus warmup used separate Release processes, alternating
revision order. Both revisions used four traversal, classification and summary
workers in the final controlled matrix. Times measure through snapshot publication.

| Fixture | Baseline, ms | Candidate, ms | Median wall change | Median paired wall change |
| --- | ---: | ---: | ---: | ---: |
| 100,000-file directory | 560.0 | 508.3 | -9.2% | +1.2% |
| 1,000 × 100 fanout | 303.9 | 299.4 | -1.5% | -2.1% |
| Deep Unicode fanout | 3175.3 | 1466.2 | -53.8% | -49.2% |
| 20,000 one-file directories | 1025.1 | 969.0 | -5.5% | -5.5% |
| SDK, expanded | 509.3 | 459.4 | -9.8% | +2.5% |
| SDK, default summaries | 601.1 | 508.7 | -15.4% | -9.2% |
| 100 package summaries | 27.9 | 27.6 | -1.3% | +2.2% |
| Real project, default summaries | 274.0 | 323.4 | +18.0% | +4.9% |

The deep Unicode case consistently improves by about half across the extraction
runs. Ordinary-case measurements fluctuate with host activity: the last
default-worker matrix included severalfold baseline drift, and even fixed
workers do not remove that noise. Differences between ratios of separate
medians and medians of adjacent pair ratios show this instability. Neither
the apparent ordinary-case gains nor isolated regressions should be presented
as reliable effects of the implementation. A separate nine-pair real-project
confirmation measured 203.5 → 204.5 ms (+0.5% wall,
+0.2% CPU); the median adjacent-pair wall change was
+0.3%. The earlier apparent regression did not repeat.

The final matrices and their individual measurements are retained as
`shipping-results.json`, `shipping-summary.json`, `controlled-results.json`
`controlled-summary.json`, and the `project-confirm-*.json` files in
`.build/selective-scan-production/`.

## Reproduction

Build both revisions separately in Release, using the same benchmark test source
and unchanged input folder. Run fresh processes, alternate revision order, and
discard a warmup pair. For example:

```sh
rtk proxy swift test -c release --scratch-path .build/scan-candidate \
  --filter ScanDiscoveryBenchmarkTests
RADIX_BENCH_SCAN_PATH="$(xcrun --show-sdk-path)" \
rtk proxy swift test -c release --skip-build --scratch-path .build/scan-candidate \
  --filter ScanDiscoveryBenchmarkTests/testDirectScan
```

`RADIX_BENCH_SCAN_SUMMARIZE=1` enables default package and directory summaries.
For controlled concurrency, set `RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS`,
`RADIX_SCAN_DIRECTORY_CLASSIFICATION_WORKERS` and
`RADIX_SCAN_ATOMIC_SUMMARY_WORKERS` to the same value for both revisions.
The benchmark measures through snapshot publication, records CPU time, reads
peak RSS before fingerprinting and reports retained live allocation growth.

Raw logs, fixture generators, matrix scripts and preserved test builds live in
`.build/selective-scan-production/`. Generated filesystem fixtures can be
removed independently of those artifacts.

## Limits

The demonstrated gain comes from avoiding repeated hashing/normalization of
long Unicode prefixes. Short paths and ASCII trees should not be assumed faster;
this change does not provide the compact-tree memory reduction. The first
Unicode directory can trigger one pass over already discovered paths. The final
Unicode ID index still hashes full paths once. Benchmark medians on one machine
cannot prove absence of a slowdown on every workload.
