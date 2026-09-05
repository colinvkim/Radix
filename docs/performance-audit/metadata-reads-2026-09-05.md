**Metadata read reuse — 5 September 2026**

The dataless-status `lstat` result now supplies identity, link count, and missing allocated-size fields within the same metadata load. Resource values retain precedence for allocation sizes, including resource-fork totals. Explicit provider overrides remain authoritative, including failures. Missing/incomplete status results retain the previous fresh-read fallback. Identity checks before and after path-based directory enumeration remain fresh; there is no cross-load metadata cache.

This completes prioritized finding 2. Scanner finalization and scanning allocations/queues remain.

**Measurements**

Baseline: `e87bebe`, with the same new metadata benchmark in a preserved Release bundle. Runs used fresh, sequential processes on the Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6, local APFS. Builds and instrumentation did not overlap timing runs; filesystem caches and machine load were uncontrolled.

The direct probe repeatedly loads metadata 10,000 times per scenario from prefetched resource values. It covers an empty directory, a symlink, a 4 KiB regular file, and that file with allocation/identity/link-count resource keys omitted. Six before/after pairs were measured, with alternating order. The additional three pairs checked variation in the ordinary-file result; all samples are retained.

| Probe, median for 10,000 loads | Before | After |
| --- | ---: | ---: |
| Empty directory | 41.563 ms | 24.441 ms |
| Symlink | 41.267 ms | 29.754 ms |
| Regular file, complete resource values | 78.683 ms | 82.843 ms |
| Missing allocation/identity/link-count values | 129.619 ms | 114.267 ms |

The common regular-file case has no eliminated read. Its median is 5.3% slower in this probe (before range 77.201–79.478 ms, after 78.681–91.583 ms); the broader status result and measurement variability limit claims about throughput. The targeted fallback cases improve substantially.

The filesystem fixture has 1,000 directories, each containing ten one-byte files and one symlink: 10,000 files and 12,001 retained nodes. Three pairs per backend measured native scans at 144.206 → 145.064 ms and forced Foundation scans at 1,142.651 → 1,143.112 ms. These results establish no overall scan-speed improvement. The Foundation backend is the existing injected `contentsOfDirectory` benchmark, not shipping fallback's enumerator/error handling.

Separate interposer runs counted the same six libc entry points as the original audit:

| Workload | `lstat` before | `lstat` after |
| --- | ---: | ---: |
| Four direct probes, 40,000 total loads | 90,000 | 40,000 |
| Native filesystem scan | 3 | 1 |
| Forced Foundation filesystem scan | 17,005 | 14,003 |

Other intercepted calls were unchanged: direct probes made 20,004 `getattrlist` and 30,002 `stat` calls; native scans made 2,004 bulk calls, 1,002 `getattrlist`, two `stat`, and 1,001 `fstat`; Foundation made 2,014 bulk calls, 25,007 `getattrlist`, two `stat`, and 1,001 `fstat`. Both scan backends returned 12,000 bulk entries. No `fstatat` calls were counted. Counts include setup and Foundation internals and exclude unhooked/private APIs. The wrapper process emitted an additional all-zero count record, retained in the raw data. Instrumented elapsed times are excluded from timing medians.

All probe identity counts/allocation sums and scan file/folder/node/warning counts matched. A separate native before/after completed-scan pair also matched full tree and semantic fingerprints, allocated bytes, and logical bytes. Cancellation was disabled for this parity-only run: this small scan finishes before the benchmark's default 250 ms cancellation delay.

**Validation and reproduction**

The complete core suite passed 915 tests, with 32 opt-in skips and zero failures. All 22 Release metadata tests passed; the full Debug app build passed. Added tests cover single-status reuse, authoritative failing overrides, and replacement of a directory between metadata loading and identity validation. Existing scanner tests cover hard links, clones, resource forks, symlinks, dataless entries, and enumeration replacement handling.

[Raw results](/Users/colin/Programming/Radix/docs/performance-audit/metadata-reads-results-2026-09-05.json) retain all 32 processes. Reproduce the direct probe by creating a temporary fixture with `directory`, `file`, and `symlink` entries and running `rtk proxy env RADIX_BENCH_METADATA_PATH=/absolute/fixture swift test -c release --filter PerformanceAuditBenchmarkTests.testMetadataReadAuditBenchmark`. Use the existing filesystem audit benchmark and interposer instructions for the scan/count workloads. No user files were modified.
