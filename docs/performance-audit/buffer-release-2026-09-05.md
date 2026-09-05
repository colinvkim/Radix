**Background buffer release — 5 September 2026**

Navigation and the file browser now transfer retired large row arrays, display indexes, formatting caches, and backing trees to a serial background release queue. The existing completed-scan cache release mechanism supplies this shared implementation and preserves its separate admission policy. UI producers wait for pending cleanup before preparing another large projection. Cancelled refresh tasks also own their inputs and results outside the main actor. Small scopes are charged by their retained backing tree, not their visible node count.

This completes prioritized finding 4 together with background directory loading. Three prioritized findings remain partly open: metadata reads, scanner finalization, and scanner allocations/queues.

**Paired measurements**

The baseline is `53d68aa`. Three before/after pairs ran in fresh, sequential Release processes, reversing order in the second pair, using the existing million-child directory publication benchmark. Builds did not overlap measurement. Hardware: Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6. Machine load and allocator state were uncontrolled.

| Operation, median | Before | After |
| --- | ---: | ---: |
| Enter directory: time until rows available | 29.971 ms | 41.972 ms |
| Enter directory: longest main-actor heartbeat gap | 2.083 ms | 2.083 ms |
| Leave directory: synchronous main-actor call | 18.940 ms | 0.054 ms |
| Leave directory: longest heartbeat gap | 19.381 ms | 2.072 ms |
| Clear filtered browser results: time until empty | 59.654 ms | 30.163 ms |
| Clear filtered browser results: longest heartbeat gap | 30.705 ms | 2.086 ms |
| Clear browser contents: synchronous main-actor call | 48.474 ms | 0.067 ms |
| Clear browser contents: longest heartbeat gap | 48.516 ms | 2.079 ms |

Entry/exit/filter medians pool nine samples per variant; content clear has three. After entry readiness ranges from 36.949 to 50.403 ms: waiting for prior cleanup adds latency before preparing the next rows. After heartbeat gaps range from 2.048 to 2.153 ms across all operations. These model probes are not SwiftUI frame traces or latency guarantees. Timed clears finish before background destruction; this measures responsiveness, not reduced total deallocation work. Framework or other owners may retain data longer.

One additional fresh-process cache-retention pair verifies the extracted implementation. Each process cycles three million-file snapshots, awaiting cleanup between cycles. Both variants retain approximately 807.14 MB of live malloc storage with one cached tree, then settle near 1.175 MB after clearing. Peak RSS was 1,663.16 MB before and 1,663.25 MB after; this includes fixtures and allocator retention, and does not establish a memory reduction. The cache retains its admission bound. The generic release batch has no independent byte cap; UI preparation gates limit the normal producer pipeline.

All eight processes passed their assertions. [Raw records](/Users/colin/Programming/Radix/docs/performance-audit/buffer-release-results-2026-09-05.json) retain every phase. Reproduce the directory workload with `RADIX_BENCH_DIRECTORY_PUBLICATION=1` and `PerformanceAuditBenchmarkTests.testLargeDirectoryPublicationBenchmark`; the cache workload uses `RADIX_BENCH_RETENTION=1`, `RADIX_BENCH_RETENTION_SCENARIO=cache`, and `PerformanceAuditBenchmarkTests.testSnapshotRetentionBenchmark`, each invoked separately through `rtk proxy swift test -c release --filter`.

**Validation**

The full core suite passed 911 tests, with 31 opt-in skips and zero failures. All 92 focused Release release-queue, navigation, browser, and cache tests passed. The full Debug app build passed. New tests verify off-main-thread final ownership release after the mutation stack unwinds, gated navigation/browser preparation with supersession, and a small scope retaining a large backing tree. Existing tests cover cache admission, eviction, selection, search generations, and cancelled navigation.
