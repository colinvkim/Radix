**Enumeration overlap profile — 5 September 2026**

Defer changes to scanner scheduling. Enumeration is substantial for a wide directory, but the bounded overlap prototype saved only about **12 ms** in an isolated enumeration/preparation stage, with overlapping timing ranges. Even a direct translation would be less than 1% of the measured complete wide scan; an actual complete-scanner improvement is unmeasured. Keep the opt-in feasibility benchmark and the new Debug-only `leaf.prepare` diagnostic to support future work.

Production baseline: `fa4308a`, the current `main` scanner after the accepted comparator and path-reuse changes. The previously rejected decoded-name prototype is absent. No enumeration, preparation scheduling, fallback, accounting, or cancellation behavior was changed for this profile.

**Current Release behavior**

Six blocks per shape ran in fresh sequential processes. Each block included a first scan and an immediate repeat; the table uses the six repeats. A first scan here is not a cold-cache measurement.

| 200,000-file shape | Complete scan | Peak RSS | Cancel requested after 50 ms | Cancel during finalization |
| --- | ---: | ---: | ---: | ---: |
| One wide directory | 1.273 s | 305.9 MB | 4.0 ms | 27.7 ms |
| 2,000 directories × 100 files | 0.584 s | 310.9 MB | 4.0 ms | 35.5 ms |

Cancellation columns are medians of three probes each. Early-request ranges were 2.0–4.1 ms on both shapes. Finalization ranges were 26.4–29.4 ms wide and 34.1–36.0 ms branching. Finalization probes waited until progress reached at least 10% of finalization, then requested cancellation after 1 ms. Probes run as a second, warm scan after the complete-scan measurement. Every probe observed stream termination, summary-pool shutdown and quiescence, no finished snapshot, and no unexpected error. These are scanner cancellation measurements, not live UI latency measurements.

First-in-block medians were 1.247 s wide and 0.582 s branching. All 24 complete scans matched per-shape tree/semantic fingerprints, counts, logical/allocated bytes, and zero warnings. The wide fixture retained 200,001 nodes; branching retained 202,001. Peak RSS includes XCTest, temporary state, the completed result, and allocator retention.

**Where the time goes**

A separate optimized diagnostic build used `-c release -Xswiftc -DDEBUG`; these are phase profiles, not shipping Release throughput numbers. Each of three profiles per shape followed a diagnostics-disabled warm-up. The added timer measures preparation inside existing leaf workers, after a request is scheduled. It excludes queue wait and coordinator commit work.

| Median diagnostic interval | Wide | Branching |
| --- | ---: | ---: |
| Complete diagnostic scan | 1.351 s | 0.758 s |
| Traversal wall time | 0.635 s | 0.283 s |
| Enumeration, summed worker intervals | 0.517 s | 0.686 s |
| Leaf preparation, summed worker intervals | 0.125 s | 0.247 s |
| Finalization wall time | 0.709 s | 0.466 s |

Worker intervals overlap and must not be added together or interpreted as percentages of branching wall time. Branching already overlaps directory enumeration and leaf work across directories. The wide fixture has one enumerated directory, so its enumeration interval is directly on the critical path: roughly 38% of its diagnostic total. Finalization accounts for about 52% wide and 61% branching; nearly all of that timer is assembly, which includes sibling sorting.

On the wide fixture, traversal minus enumeration and batch classification leaves approximately 107 ms for all remaining traversal work. That includes preparation, child weighting, scheduling, and committing prepared results. Hiding only leaf preparation can recover a portion of that interval. It cannot remove the 0.517 s enumeration stage or the 0.709 s finalization stage. All six diagnostic scans matched the uninstrumented Release tree fingerprints and counts.

**Bounded feasibility prototype**

`ScanLeafOverlapBenchmarkTests` compares draining a native cursor before node preparation with preparing each native batch while enumeration continues. Both variants use up to five preparation tasks and retain immutable source batches until successful completion. This avoids mutating an array that worker slices retain and keeps provisional results available for discard. Forced native unavailability after one successful batch and cancellation both throw without returning partial results.

The benchmark deliberately stops at node construction: it does not build the tree, assign global scan keys, deduplicate shared allocation, manage summaries, compute progress weights, or restart through Foundation after native failure. Its control also uses native batch boundaries rather than the complete scanner's 2,048-entry preparation requests. It tests whether overlap is promising enough to justify integration; it is not an integration patch.

Six pairs alternated which variant ran first. Each measured variant had its own immediately preceding warm-up in a fresh process. Correctness checks and a stable path fingerprint ran after timing.

| Enumeration/preparation stage | Staged | Overlapped |
| --- | ---: | ---: |
| Median time | 0.5376 s | 0.5261 s |
| Range | 0.5326–0.5595 s | 0.5089–0.5524 s |
| Median peak RSS | 311.5 MB | 308.5 MB |

The difference is 11.5 ms, or 2.1% of this simplified stage. Overlap won four pairs and lost two. Its small memory difference also belongs to this harness; no complete-scanner memory saving is established. All 25 prototype processes (12 measured, 12 warm-ups, one validation process) produced 200,000 unique nodes, matching path fingerprints, IDs consistent with their URLs, and matching URL display names. The validation process additionally passed both provisional-result failure checks.

The measured benefit is too small to justify adding rollback storage, global worker-budget coordination, or new progress/accounting state to the scanner. The more substantial remaining profile interval is finalization. These empty-file fixtures force allocated-size ties and natural-name comparisons, so a representative mixed-size profile should precede any further sorting or assembly change.

**Reproduction and limits**

Apple M5, ten cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6 (17F113), local APFS. All measurements ran outside the command sandbox. Builds and fixture creation did not overlap timing. Caches and background load were uncontrolled; cold-cache storage, network/provider volumes, and live SwiftUI latency remain unmeasured.

Create equivalent fixtures with:

```sh
rtk proxy python3 docs/performance-audit/make-fixtures.py --wide-files 200000 --fanout-directories 2000 --files-per-directory 100 --empty
```

Complete scans use `FullDiskScanScalingBenchmarkTests.testFullDiskScanScalingBenchmark`, `RADIX_BENCH_FULL_SCAN_SCALING=1`, the returned path in `RADIX_BENCH_FULL_SCAN_PATH`, and `RADIX_BENCH_FULL_SCAN_SCENARIO=expanded-manual-none`. First scans set `RADIX_BENCH_FULL_SCAN_CANCELLATION=0`. Repeats use cancellation with either `RADIX_BENCH_FULL_SCAN_CANCEL_AFTER_MS=50`, or `RADIX_BENCH_FULL_SCAN_CANCEL_FINALIZATION_FRACTION=0.1` and a delay of 1 ms.

Diagnostic profiles use `PerformanceAuditBenchmarkTests.testFilesystemAuditBenchmark`, `RADIX_BENCH_AUDIT_PATH`, `RADIX_SCAN_DIAGNOSTICS=1`, and a separate Release scratch build with `-Xswiftc -DDEBUG`. For the prototype, use `ScanLeafOverlapBenchmarkTests.testNativeLeafOverlapBenchmark`, the wide path in `RADIX_BENCH_OVERLAP_PATH`, `RADIX_BENCH_OVERLAP_MODE=staged` or `overlap`, and `RADIX_BENCH_OVERLAP_WORKERS=5`. Set `RADIX_BENCH_OVERLAP_VALIDATE=1` for the separate failure/cancellation checks. Invoke each compiled XCTest separately through `rtk proxy`; do not overlap builds or measurements.

[Raw results](/Users/colin/Programming/Radix/docs/performance-audit/scan-overlap-results-2026-09-05.json) retain all Release records, diagnostic reports, prototype records, and calculated summaries. Logs, the uninstrumented Release bundle, diagnostic build, and runners remain under `.build/overlap-audit`. Generated fixtures were removed after measurement; no user files were modified.

Validation passed: 128 scanner/diagnostics tests in the optimized diagnostic build; the complete core suite with 933 tests, 36 skipped, and zero failures; and the full Debug app build at `.build/xcode-derived-data`. The opt-in benchmark's normal skip is included in the complete-suite skip count; its measured runs and failure/cancellation checks were executed separately as described above.
