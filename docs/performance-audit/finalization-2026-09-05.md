**Scanner finalization — 5 September 2026**

Scanner sibling sorting now checks cancellation every 256 comparisons, including size-tied localized-name comparisons. The final ID-index conversion checks every 256 values while retaining `Dictionary.mapValues`, which reuses the source keys/hash layout. Sorting continues to move integer child keys through the standard library's adaptive in-place algorithm. The existing chunk/merge sorter remains appropriate for the other measured query paths; this owned-buffer variant avoids forcing extra merge passes on already ordered scanner inputs.

Finalization already aggregates directory sizes, accessibility, and file counts once from children to parents, then includes each completed node in aggregate statistics once. Shared-allocation corrections are resolved before corrected children are aggregated. No additional cache, repeated aggregate traversal, scheduling policy, or tree representation was introduced.

**Measurements**

Baseline: `3e568ae`, with identical benchmark additions. The machine was the Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6, local APFS. Three pairs per shape ran sequentially in fresh Release processes, reversing order in the second pair. Builds and fixture creation did not overlap measurements. Filesystem caches and machine load were uncontrolled. Both fixtures use one million empty files, exercising localized-name ties: one flat directory, or 10,000 directories containing 100 files each. Automatic summarization is disabled.

| Median | Before | After |
| --- | ---: | ---: |
| Flat scan, total | 15.500 s | 14.813 s |
| Flat scan, observed finalization | 5.676 s | 5.727 s |
| 10,000-directory scan, total | 5.138 s | 5.022 s |
| 10,000-directory scan, observed finalization | 2.487 s | 2.487 s |

These measurements support a responsiveness fix, not faster finalization. Flat finalization increased by 0.9%; flat total times varied from 14.753 to 16.799 seconds before and 14.779 to 16.655 after. Finalization timing begins when the consumer observes its first finalization progress event, so it is not an isolated sort timer. Peak RSS stayed near 1.337 GB flat and 1.317 GB branching. All twelve processes passed and matched full tree fingerprints, file/folder/node counts, zero warning counts, and logical/allocated byte totals.

For cancellation, the benchmark waits until it observes at least 99% assembly progress, then waits 100 ms before cancelling. On the flat fixture it observed 99.4999%; the remaining root sort is the intended stress point. The baseline consumer terminated but the summary pool had not shut down at the five-second deadline, failing the benchmark's shutdown assertion. This gives a lower bound, not an exact baseline latency. Three after runs passed, reached pool shutdown with quiescent workers in 171.886, 164.531, and 159.682 ms, and emitted no finished snapshot or unexpected error. Shutdown follows traversal task-group exit; it does not measure the final release of every allocation or establish a worst-case latency guarantee.

[Raw records](/Users/colin/Programming/Radix/docs/performance-audit/finalization-results-2026-09-05.json) retain all twelve timing runs, the expected baseline cancellation failure, and all three successful after cancellation probes. Prioritized finding 3 is complete; native enumeration allocations and the remaining frontier measurements are the final finding.

**Validation**

The full core suite passed 918 tests, with 32 opt-in skips and zero failures. All 125 Release sorting/scanner tests passed; the complete Debug app build passed. Added tests compare stable tie ordering with the standard library, interrupt an active large sort, and cancel an empty input. Existing scanner tests cover aggregation, shared allocation, progress monotonicity, and scan cancellation.

Reproduce timing with the existing filesystem audit benchmark and `make-fixtures.py --wide-files 1000000 --fanout-directories 10000 --files-per-directory 100 --empty`. Cancellation probes use `FullDiskScanScalingBenchmarkTests.testFullDiskScanScalingBenchmark` with `RADIX_BENCH_FULL_SCAN_SCALING=1`, `RADIX_BENCH_FULL_SCAN_SCENARIO=expanded-manual-none`, `RADIX_BENCH_FULL_SCAN_CANCEL_FINALIZATION_FRACTION=0.99`, `RADIX_BENCH_FULL_SCAN_CANCEL_AFTER_MS=100`, and `RADIX_BENCH_FULL_SCAN_PATH` pointing to the flat fixture. Run each through `rtk proxy swift test -c release --filter` separately. No user files were modified.
