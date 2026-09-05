**Scan node path reuse — 5 September 2026**

Keep this small optimization. `ScanEngine` already extracts each node's URL path for its ID. Passing that string to `ScanTarget.displayName` avoids extracting the same path again to check for `/`. Both leaf construction and directory assembly reuse their existing paths; other callers retain the default behavior. Root-volume naming, literal last-component extraction, and the presented URL namespace remain unchanged. The change adds no stored state or cache.

Baseline: `d82d6ab`, which includes the earlier comparator and package-readability changes. The baseline and candidate Release bundles contain the same opt-in node-preparation benchmark. Only the candidate contains the production path-reuse change.

| Workload, median of three pairs | Before | After | Time reduction |
| --- | ---: | ---: | ---: |
| Prepare 200,000 nodes, short ASCII paths | 0.1194 s | 0.0829 s | 30.6% |
| Prepare 200,000 nodes, long Unicode paths | 1.3997 s | 0.7745 s | 44.7% |
| Scan 200,000 empty files, ASCII | 1.4051 s | 1.2587 s | 10.4% |
| Scan 200,000 empty files, long Unicode paths | 7.5197 s | 7.1604 s | 4.8% |

The isolated preparation improvement is consistent: every pair improves, and the before/after ranges do not overlap. Complete scans are noisier: ASCII ranges are 1.285–2.909 s before and 1.241–1.376 s after; Unicode ranges are 7.493–8.066 s before and 7.147–7.542 s after. Both complete-scan comparisons include a slightly slower candidate in round two. Their medians do not establish a general end-to-end speedup. The evidence for retaining this change is the repeatable reduction in node-preparation CPU work at negligible implementation cost.

Every prepared node's ID and name matched `URL.path` and `URL.lastPathComponent`; path/name byte totals matched between versions. All twelve complete scans matched per-fixture fingerprints, 200,000 files, one directory, 200,001 nodes, zero logical/allocated bytes, and zero warnings. Peak RSS stayed approximately 185 MB for ASCII preparation and 635 MB for Unicode preparation; complete scans used approximately 305–311 MB and 808–810 MB, respectively. This is a CPU optimization, not a memory reduction.

**Method and reproduction**

Apple M5, ten cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6 (17F113), local APFS. Three before/after pairs per workload/scenario ran in fresh sequential Release XCTest processes outside the command sandbox. Round two reversed the order. Builds and fixture creation did not overlap timing. Caches were warm/uncontrolled, with no background-load isolation. No cold-cache, network/provider-volume, or live UI responsiveness measurements were taken.

The opt-in `PerformanceAuditBenchmarkTests.testLeafPreparationPathBenchmark` constructs all URLs before timing and retains the resulting records. The timer covers only `makeFileNode` calls and the output array; correctness checks and byte counting occur afterward. ASCII URLs use `/audit/file-{index}.dat`. Unicode URLs use `/audit/`, 24 repetitions of `层级-é-😀-路径/`, and names `文件-cafe\u{301}-{index}-100% #?.dat` (the escape denotes a combining acute accent). This deliberately amplifies path decoding cost and is not a typical-path estimate.

Run the focused benchmark with:

```sh
rtk proxy env RADIX_BENCH_LEAF_PATH=1 RADIX_BENCH_LEAF_PATH_SCENARIO=ascii swift test -c release --disable-automatic-resolution --filter PerformanceAuditBenchmarkTests.testLeafPreparationPathBenchmark
rtk proxy env RADIX_BENCH_LEAF_PATH=1 RADIX_BENCH_LEAF_PATH_SCENARIO=unicode swift test -c release --disable-automatic-resolution --filter PerformanceAuditBenchmarkTests.testLeafPreparationPathBenchmark
```

For an equivalent full-scan fixture, create a fresh temporary root with an `ascii` directory containing 200,000 empty files named `file-{index:08}.dat`. Under a sibling `unicode` directory, create 24 nested components named `层级-é-😀-路径-{index:02}` for indices 00–23. Put 200,000 empty files named `文件-cafe\u0301-{index:08}-100% #?.dat` in the deepest directory. Scan that deepest directory directly so both scenarios contain one scanned directory. The retained results include the original absolute fixture paths; fingerprints depend on those paths.

Run `PerformanceAuditBenchmarkTests.testFilesystemAuditBenchmark` with `RADIX_BENCH_AUDIT_PATH` pointing to each fixture. Use the default native scan policy (five workers on this machine), with no forced compatibility or traversal-worker override. For paired reproduction, add only the opt-in preparation benchmark to a separate copy of `d82d6ab`, build both Release test bundles, and invoke Xcode's `xctest -XCTest` through `rtk proxy` against each bundle. Keep the bundle basename `RadixCorePackageTests.xctest` when preserving the baseline. Reverse before/after order in the second round and compare all semantic metrics before interpreting timings.

[Raw results](/Users/colin/Programming/Radix/docs/performance-audit/path-reuse-results-2026-09-05.json) retain all 24 processes and calculated medians/ranges. Process logs and the preserved baseline bundle remain under `.build/path-reuse-audit`. The generated filesystem fixtures were removed after measurement.

Validation passed: all 157 focused Release scanner/model tests; the complete core suite with 932 tests, 35 skipped, and zero failures; and the full Debug app build at `.build/xcode-derived-data`. The new regression test covers root-volume names, trailing directories, literal punctuation, and combining Unicode. A later [decoded-name reuse experiment](/Users/colin/Programming/Radix/docs/performance-audit/decoded-name-reuse-2026-09-05.md) measured that separate opportunity and rejected its prototype; this path-reuse change remains applied.
