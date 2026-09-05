**Comparison validation — 5 September 2026**

Comparison refreshes reuse the published significant-change projection when the comparison ID and selected change kinds still match. Search text, path filtering, and sort order no longer rebuild it or republish the unchanged projection. The reuse marker is set only after a current request completes, and cancellation clears it. No additional projection copy or multi-entry cache is retained.

Projection preparation now checks cancellation during eligibility, coverage, ranking, recursion, and remainder aggregation. It avoids redundant child filtering, the complete ranked-node array, and the hidden-node array. Impact calculation no longer creates a temporary set per aggregate. Comparison row and top-level sorts use a shared cancellable offset sorter, while move and tree-index sorts use the existing cancellable sorter. Existing cancellation and stale-request publication guarantees remain intact.

This closes finding 9 of the [audit](/Users/colin/Programming/Radix/docs/performance-audit-2026-09-04.md). Four prioritized findings remain: changed-directory/main-actor ownership work, metadata-read reuse, scanner finalization, and scanner allocations/enumeration.

**Measurements**

The baseline is production revision `5245ab7`, built separately with the same added benchmark. Tests ran in fresh sequential SwiftPM Release processes on the Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, and Xcode 26.6. The synthetic workload compares an empty snapshot to a same-root snapshot of regular files with distinct descending allocated sizes. Every file appears as an added root-level comparison row.

Three before/after pairs ran at 100,000 rows, reversing order in the second pair. One pair ran at one million rows: eight final processes. Builds did not overlap measurement; machine load and allocator state were uncontrolled. The [full records](/Users/colin/Programming/Radix/docs/performance-audit/comparison-results-2026-09-05.json) retain every phase, sample, and result fingerprint.

| Operation | 100k before median | 100k after median | 1m before, single run | 1m after, single run |
| --- | ---: | ---: | ---: | ---: |
| Service row sorting | 325.653 ms | 41.922 ms | 4,347.517 ms | 664.987 ms |
| Service top-level sorting/preparation | 36.203 ms | 32.688 ms | 456.850 ms | 396.390 ms |
| Initial browser refresh | 260.170 ms | 259.346 ms | 2,805.758 ms | 2,664.695 ms |
| Path-filter refresh, one result | 238.225 ms | 9.426 ms | 2,800.823 ms | 178.642 ms |
| Sort-order refresh, all results | 316.108 ms | 39.731 ms | 4,379.973 ms | 662.107 ms |
| Warm text-search refresh, one result | 310.025 ms | 73.413 ms | 3,172.096 ms | 899.759 ms |

The million-row path refresh fell 94%, service row sorting 85%, and warm text search 72%. Initial projection still traverses the changed tree; reuse primarily benefits subsequent requests. Cold search still constructs its text index. The million-row sequence's peak RSS fell from 6,626.5 to 6,061.0 MB (9%). These large totals include both fixtures, the comparison graph, rows, search-index state, and retained allocator memory; they do not measure isolated live projection storage or every real comparison shape.

Service timers use existing phase instrumentation. Refresh timers cover scheduling, background work, and model publication with zero debounce and 1 ms polling. Fixture construction and fingerprinting occur outside timers. Row order, projected nodes, impact totals, and hidden counts match exactly across every before/after pair. Fingerprints exclude process-dependent set iteration order. These are model measurements, not SwiftUI frame traces or cancellation-latency bounds.

**Validation**

The final complete core suite passed 905 tests, with 30 skips and zero failures. All 56 focused Release comparison tests passed, and the full Debug app build passed. Tests cover reuse across search/path/sort updates; invalidation for changed kinds, dataset, and cancellation; supplied projection reuse; cancellation during coverage/remainder work and between large sort runs; and older requests being unable to overwrite newer results. Existing tests preserve moves, hard links, opaque directories, overflow clamping, coverage, filtering, and deterministic ordering.

The service and browser still retain substantial comparison data at million-row scale. This checkpoint addresses repeated projection, avoidable temporary arrays, and sort/cancellation gaps. Buffer ownership on the main actor is the next prioritized finding. Chunk sorts still have up to 16,384 elements between checks; cancellation cannot interrupt each comparison within a chunk.

Reproduce either size with the opt-in benchmark:

```sh
rtk proxy env RADIX_BENCH_COMPARISON=1 RADIX_BENCH_COMPARISON_FILES=100000 swift test -c release --filter PerformanceAuditBenchmarkTests.testComparisonPreparationBenchmark
```

Use `1000000` for the larger fixture. The JSON also records the direct `xctest` invocation used for the preserved before/after bundles. No user files or filesystem fixtures were changed.
