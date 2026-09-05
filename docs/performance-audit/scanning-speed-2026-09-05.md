**Scanning-speed audit — 5 September 2026**

Implementation follow-up: findings 1 and 2 are applied. The scanner's ordering test now covers descending allocated size and natural-number name ties. Package-summary initialization requests only `.isReadableKey`, preserving its fresh lookup and warning handling. A pooled-summary test covers readable, unreadable, and missing roots. Final validation passed: **930 core tests, 34 skipped, zero failures**, all **138 focused Release scanner/package/sort tests**, and the full Debug app build.

Three additional Release pairs compared the readability change against `f55caa0` (which already includes the comparator fix). All six `/Applications` scans matched tree/semantic fingerprints, 355,884 files, 65 retained nodes, byte totals, and zero warnings. Median time was 1.307 s before and 1.330 s after; ranges overlap (1.307–1.378 s before, 1.301–1.385 s after). These results establish no end-to-end speedup for the readability change. It removes nine unused requested properties and unnecessary package classification from this initialization step. [Follow-up raw results](/Users/colin/Programming/Radix/docs/performance-audit/readability-results-2026-09-05.json) preserve every pair. Scanned application files were never changed.

The best first change is small: avoid copying complete `FileNodeRecord` values inside the scanner's sibling-sort comparator. An isolated prototype reduced observed finalization by **30–33%** on two 200,000-file fixtures while preserving sorting, cancellation checks, fingerprints, counts, and byte totals. Production source was unchanged during the audit. The proposed patch, an opt-in comparator benchmark, raw measurements, and profile excerpts accompany this audit.

Audit baseline: `3690fdf`. This review follows the earlier performance work and does not reopen resolved metadata-status reuse, cancellation, ASCII native-name allocation, or queue-policy findings.

**Prioritized opportunities**

1. **P1 — Read sort fields without copying entire records.** At [ScanEngine.swift:2135](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2135), each comparison loads two complete records into local values, then uses only their allocated sizes and names. The Release sample contains `initializeWithCopy for FileNodeRecord` and reference-counting work beneath this comparator. Read the two sizes directly from `nodes`, and load names only for size ties. This needs no cache, extra projection array, or different sorting algorithm. The [isolated prototype patch](/Users/colin/Programming/Radix/docs/performance-audit/scanning-sort-prototype-2026-09-05.patch) changes only this comparator. Start here before parallelizing finalization.

2. **P2 — Request only readability when initializing a package summary.** [AtomicDirectorySummaryPool.swift:683](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectorySummaryPool.swift:683) requests all ten atomic-summary resource keys, including package classification, sizes, link count, and identity, but consumes only `values.isReadable`. Narrow this fresh request to `.isReadableKey`; preserve warning handling. An interrupted sandbox run showed this exact call waiting in LaunchServices package classification while other tasks waited behind it. The same benchmark completed normally outside the sandbox. That trace demonstrates an unnecessary dependency on package classification here, not a measured shipping-app stall or an established throughput gain. Root identity validation remains a separate requirement.

3. **P2 — Remove repeated URL-to-string work for native leaves.** [makeFileNode at ScanEngine.swift:2943](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2943) reads `url.path` for the ID; [ScanTarget.displayName at line 89](/Users/colin/Programming/Radix/Radix/Models/ScanTarget.swift:89) reads it again to check for `/`, then extracts the last component. Bulk parsing already decoded that component before [constructing the URL](/Users/colin/Programming/Radix/Radix/Services/BulkDirectoryEnumerator.swift:759). The Release sample shows URL path getters in leaf preparation. First reuse the already obtained path for the root-name check; then measure whether carrying the decoded native name to node construction is worth any extra temporary storage. Preserve root-volume display names, Unicode names, and the presented firmlink namespace. This is a source-backed candidate; its end-to-end speedup was not measured.

4. **P2 — Overlap wide-directory enumeration and leaf preparation.** [directoryEntries at ScanEngine.swift:2653](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2653) drains every native batch into one array before returning. Only afterward does [directory expansion enqueue leaf batches](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:1940). Thus one huge directory has a serial discovery stage regardless of traversal-worker count. Reuse the existing cursor and bounded leaf batches in a prototype that overlaps decoding/preparation. This requires care: later native batches can force a complete Foundation fallback, Unicode collisions span batches, and progress weights currently depend on the complete listing. Keep those semantics intact before committing results. Earlier million-entry measurements already demonstrated large listing storage; this audit's worker matrix also shows that simply increasing workers does not solve the wide-directory case. This is a larger design change with an unmeasured speedup, so it ranks below the smaller fixes.

5. **P2 — Apply safe exclusions before Foundation metadata work.** The compatibility path [prefetches the full resource-key set](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2727), then [loads child metadata before checking user exclusions](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2901). For example, a `*.log` match does not require knowing whether the entry is a directory. Reject such matches before the loader and investigate selective prefetch for exclusion-heavy listings. Moving only the final predicate leaves the earlier prefetch cost intact. Preserve directory-only patterns when type is unknown and retain namespace and identity checks. Benchmark this on compatibility filesystems; the native path already filters early, and network/provider-backed storage was not measured here.

**Measured sort prototype**

Three before/after pairs per workload ran in fresh sequential Release XCTest processes, reversing order in the second round. The prototype was built from a separate copy under `.build/scanning-speed-prototype`; comparison of every production Swift file confirmed that only the comparator differed.

| Workload, median of three | Baseline | Prototype | Reduction |
| --- | ---: | ---: | ---: |
| 200,000 files in one directory, observed finalization | 0.894 s | 0.600 s | 32.8% |
| 2,000 directories × 100 files, observed finalization | 0.488 s | 0.341 s | 30.1% |
| One wide directory, complete scan | 1.809 s | 1.203 s | 33.5% |
| 2,000 × 100 files, complete scan | 0.736 s | 0.654 s | 11.1% |
| `/Applications`, packages collapsed, complete scan | 1.398 s | 1.380 s | 1.3% |

The finalization improvement is more consistent than wide-directory total time. Wide totals ranged from **1.495–2.560 s baseline** and **1.202–2.264 s prototype**, with considerable variation before finalization. The 33.5% median total reduction is therefore not a reliable general speedup estimate. `/Applications` ranges also overlap; its small difference establishes no benefit. That workload scanned 355,884 files but retained only 65 nodes, including 49 package summaries, so sibling sorting has little opportunity to help.

The generated fixtures contain empty files, exercising allocated-size ties and natural-name collation without file-content reads. All 18 completed comparison processes matched per-workload fingerprints, file/folder/node counts, zero warnings, and logical/allocated byte totals. Peak RSS remained around 308 MB for the wide fixture and 310–313 MB for the branching fixture. This change targets CPU work, not memory capacity.

The isolated [comparator benchmark](/Users/colin/Programming/Radix/RadixCoreTests/ScanSortSpeedAuditBenchmarkTests.swift) also covers ordered equal sizes, shuffled equal sizes, and shuffled varied sizes. In one exploratory Release process, direct field access reduced those sort times by 25%, 33%, and 41%, respectively. Every output index array matched. Those single-process microbenchmarks support the mechanism; the complete-scan pairs provide the stronger validation.

**Worker tuning**

The current policy selects five traversal workers on this ten-core M5. The same setting also controls ordinary-leaf preparation workers, so these are not isolated traversal-only comparisons. Each cell is the median of three fresh Release processes; second-round order was reversed.

| 200,000-file shape | 1 worker | 5 workers | 8 workers |
| --- | ---: | ---: | ---: |
| One wide directory | 1.806 s | 1.596 s | 1.662 s |
| 2,000 × 100 files | 1.091 s | 0.886 s | 0.832 s |

Eight workers improved branching throughput by about 6% versus five, while the wide case was about 4% slower. These results do not justify raising the global default. Keep existing thermal/low-power limits. The previous broader frontier measurements also did not justify adding a queue-admission policy; a new cache or backpressure mechanism should require new evidence.

**Method, limits, and reproduction**

Hardware: Apple M5, ten cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6 (17F113), local APFS. Caches were warm/uncontrolled; no cache flushing or controlled background-load isolation was performed. Builds, fixture creation, and instrumentation did not overlap timed comparisons. Finalization is timed from the consumer's first finalization progress event, not with an internal stopwatch. RSS includes XCTest, temporary scan state, and allocator retention.

The worker matrix ran inside the Codex command sandbox. The complete paired matrix ran outside it after an initial `/Applications` run stalled in a synchronous LaunchServices request. The interrupted run has no completed timing; its four preceding fixture results are retained separately and excluded from the main comparison. Two sampled fixture runs are likewise excluded from timing statistics. The package scan completed in roughly 1.3–1.5 seconds outside the sandbox. This distinction prevents treating an environment artifact as production performance.

Cold-cache disks, network/removable volumes, cloud providers, and live SwiftUI interaction latency remain unmeasured. Findings 3–5 remain unimplemented and unbenchmarked. Incremental rescans already localize disk reads, but their sequential deep-subtree rescans and whole-store splice remain separate follow-up profiling targets; this audit did not measure those paths.

Create equivalent fixtures with:

```sh
rtk proxy python3 docs/performance-audit/make-fixtures.py --wide-files 200000 --fanout-directories 2000 --files-per-directory 100 --empty
rtk proxy env RADIX_BENCH_SCAN_SORT=1 swift test -c release --filter ScanSortSpeedAuditBenchmarkTests
```

For each printed fixture path, run `PerformanceAuditBenchmarkTests.testFilesystemAuditBenchmark` with `RADIX_BENCH_AUDIT_PATH` set to that path. Set `RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS` to 1, 5, or 8 for the worker matrix. For prototype comparisons, apply the saved patch only in a separate copy, build both Release test bundles, and invoke Xcode's `xctest -XCTest RadixCoreTests.PerformanceAuditBenchmarkTests/testFilesystemAuditBenchmark` through `rtk proxy` separately against each bundle. The application workload uses `FullDiskScanScalingBenchmarkTests.testFullDiskScanScalingBenchmark`, `RADIX_BENCH_FULL_SCAN_SCALING=1`, `RADIX_BENCH_FULL_SCAN_PATH=/Applications`, `RADIX_BENCH_FULL_SCAN_SCENARIO=collapsed-auto-none`, and `RADIX_BENCH_FULL_SCAN_CANCELLATION=0`.

[Raw results](/Users/colin/Programming/Radix/docs/performance-audit/scanning-speed-results-2026-09-05.json) preserve all timing records and parity checks. [Profile excerpts](/Users/colin/Programming/Radix/docs/performance-audit/scanning-speed-profile-excerpts-2026-09-05.txt) preserve the relevant call chains; full samples and process logs remain under `.build/scanning-speed-audit`.

Audit validation passed: 169 focused Release scanner tests on the baseline, 127 focused Release scanner/sort tests on the isolated prototype, and the comparator experiment. The complete core suite at audit completion executed **929 tests, 34 skipped, zero failures**. The full Debug app build passed at `.build/xcode-derived-data`. No production source was changed or committed during the audit. The temporary generated filesystem fixtures were removed after measurement; scanned application files were never changed.
