**Large-directory loading — 5 September 2026**

Navigation now projects directories with more than 512 children on a background actor. Focus and selection update immediately, and the file browser uses its existing loading presentation until the matching rows arrive. Small directories remain synchronous. The existing table-source identity identifies pending as well as loaded contents; selection changes and unchanged refreshes do not restart work. Cancelled or superseded results cannot publish into a new context. Explicitly deferred loading still waits for `refreshTableNodesForCurrentContext`.

This is the first part of audit finding 4. Large buffer destruction remains measurable when leaving a directory or clearing browser results and is the next checkpoint. The audit still has four partly addressed prioritized findings.

**Paired measurements**

Production revision `b5bc3b0` is the baseline, using the same added benchmark in a preserved Release bundle. Three before/after pairs ran in fresh, sequential processes, reversing order in the second pair. Builds did not overlap measurements. The machine was the Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6. Machine load and allocator state were uncontrolled.

The fixture contains one million synthetic regular files inside one directory beneath the navigation root. Both original and combined fixture trees remain alive. Each process enters and leaves that directory three times, then exercises filtering and clearing through the real `FileBrowserModel`. A 1 ms main-actor heartbeat records the longest scheduling gap during each operation; it is not a SwiftUI frame trace or an isolated deallocation timer.

| Operation, median | Before | After |
| --- | ---: | ---: |
| Enter directory: synchronous main-actor call | 27.751 ms | 0.043 ms |
| Enter directory: elapsed until rows are available | 27.753 ms | 30.621 ms |
| Enter directory: longest main-actor heartbeat gap | 28.209 ms | 2.098 ms |
| Leave directory: synchronous main-actor call | 20.491 ms | 18.898 ms |
| Clear filtered browser results: longest heartbeat gap | 31.458 ms | 30.694 ms |
| Clear browser contents: synchronous main-actor call | 48.260 ms | 47.792 ms |

The table pools nine enter/exit/filter samples and three complete content-clear samples per variant. Background directory projection adds scheduling and cancellation overhead, increasing median time to rows by about 3 ms, while removing that projection from the main-actor call. One after entry observed a 12.325 ms heartbeat gap; these observations are not latency guarantees. The unchanged exit and browser-clear costs establish the baseline for the buffer-release follow-up.

Full [records and reproduction details](/Users/colin/Programming/Radix/docs/performance-audit/directory-loading-results-2026-09-05.json) retain all six processes. Peak RSS includes XCTest, the retained synthetic fixtures, source and displayed arrays, dictionaries, and allocator retention. This checkpoint makes no claim of lower live-memory usage.

**Validation**

The complete core suite passed 908 tests, with 31 skips and zero failures. All 23 focused Release navigation tests passed, and the full Debug app build passed. Added tests cover deferred large-directory loading, selection changes during a pending load, cancellation/reset with a superseded result, and completion revision changes. Existing tests preserve small-directory behavior, selection, focus history, metadata changes under the same snapshot ID, and explicit loading deferral.

The benchmark validates expected row counts and boundary IDs after navigation, and empty/full browser results after each filter cycle. The older navigation audit benchmark now awaits row availability after timing the synchronous installation call, so its subsequent selection measurements continue to use loaded contents.

```sh
rtk proxy env RADIX_BENCH_DIRECTORY_PUBLICATION=1 swift test -c release --filter PerformanceAuditBenchmarkTests.testLargeDirectoryPublicationBenchmark
```

No new user-facing strings or dependencies were added. No user files were changed.
