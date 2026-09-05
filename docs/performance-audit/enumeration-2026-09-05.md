**Native enumeration allocations and broader frontier — 5 September 2026**

Included ordinary ASCII leaves no longer retain a second NUL-terminated filename array. Their URL and decoded metadata already supply everything the leaf path consumes. Directories, symlinks, entry errors, and non-ASCII names retain exact native bytes; Unicode collision detection still spans kernel batches. Required native-name arrays reserve room for the terminator before copying, avoiding growth when appending it. Native bulk enumeration, early exclusion checks, descriptor-relative directory opens, compatibility fallback, and worker limits are preserved.

**Allocation and scan measurements**

Baseline: `dd912a6`, with the same allocation benchmark in a preserved Release bundle. Three before/after pairs per workload ran in fresh sequential processes, reversing the second pair. Hardware: Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6, local APFS. Builds, fixture creation, and instrumented scans did not overlap timing runs. Filesystem caches and machine load were uncontrolled.

The direct enumeration probe retains all one million entries from an ASCII-named flat directory of empty files, then samples malloc statistics with the result alive. It runs synchronously in XCTest to isolate enumeration; shipping scanning remains outside the main actor. The second shape has 10,000 directories of 100 empty files each. Full scans use default concurrency with automatic summarization disabled.

| Median | Before | After |
| --- | ---: | ---: |
| Retained native-name arrays, direct enumeration | 1,000,000 | 0 |
| Live malloc blocks, direct enumeration process | 7,005,899 | 6,005,903 |
| Live malloc storage, direct enumeration process | 829.571 MB | 765.571 MB |
| Direct enumeration peak RSS | 1,042.088 MB | 977.830 MB |
| Direct enumeration elapsed | 9.505 s | 8.634 s |
| Flat complete scan peak RSS | 1,336.639 MB | 1,288.749 MB |
| Flat complete scan elapsed | 14.873 s | 14.980 s |
| 10,000-directory complete scan peak RSS | 1,314.947 MB | 1,316.307 MB |
| 10,000-directory complete scan elapsed | 5.029 s | 4.951 s |

The targeted live allocation reduction is approximately one million blocks and 64 MB. Initial process heap samples are retained in the raw records (about 1.127 MB and 5,860 blocks). Live block counts are not cumulative allocation-event counts. The removed arrays account for the measured difference; other allocations and transient reallocations were not individually attributed.

Direct enumeration timing ranges overlap (8.497–10.446 s before, 8.413–10.639 after), and flat complete scan time increased by 0.7%. This checkpoint establishes lower temporary memory, not a general throughput improvement. Small per-directory listings do not materially change the completed-tree-dominated peak in the branching shape. RSS includes XCTest, results, temporary storage, and allocator retention.

**Frontier measurements**

Separate optimized builds with `DEBUG` diagnostics measured three runs of each shape, including a combined two-million-file tree containing both fixtures. The branching fixture contains 100 times as many directories as the previous frontier experiment. The combined tree is skewed: one million-child directory beside 10,000 directories with 100 children each.

| Peak pending ownership | Flat, 1m files | 10,000 × 100 files | Combined, 2m files |
| --- | ---: | ---: | ---: |
| Directory work items | 1 | 10,000 | 10,000 |
| Leaf requests | 489 | 1 | 489 |
| Leaf request slots | 1,000,000 | 100 | 1,000,000 |
| Distinct retained leaf listings | 1 | 1 | 1 |
| Entries in retained leaf listings | 1,000,000 | 100 | 1,000,000 |
| Largest directory listing | 1,000,000 | 10,000 | 1,000,000 |

These high-water counters cover pending leaf requests, counting shared parent buffers once, and the directory work stack. They exclude active enumeration/worker buffers, task-group results awaiting consumption, automatic/package summary candidates, array spare capacity, and completed nodes. Instrumentation can change scheduling. Counts establish no sustained accumulation of multiple pending leaf listings in these workloads; a new admission/backpressure mechanism remains deferred. They do not establish a universal memory bound or exclude pressure on different storage or summary-heavy workloads.

All 27 benchmark processes passed. Every scan matched its shape's tree fingerprint across variants/runs, expected file/directory/node counts, zero warnings, and zero logical/allocated bytes for the empty files. [Raw records](/Users/colin/Programming/Radix/docs/performance-audit/enumeration-results-2026-09-05.json) retain each timing, heap, and diagnostic sample. This closes prioritized finding 6 with a measured allocation fix and an evidence-based deferral of new queue policy.

**Validation and reproduction**

The full core suite passed 919 tests, with 33 skips and zero failures. The 136 focused Release scanner/descriptor tests passed, with two filesystem-dependent Unicode skips. The eight optimized diagnostic descriptor tests passed with the same two skips. The full Debug app build passed. Existing tests preserve exact Unicode descriptor opens, directory identity validation, symlink and hard-link metadata, exclusions, fallback, and descriptor cancellation/closure. The descriptor parity test now also verifies that ASCII file and hard-link entries omit the buffer while directories and symlinks retain it. This APFS volume rejects invalid UTF-8 names and folds canonically equivalent names, so those two filesystem-dependent collision scenarios remain skipped.

Use `make-fixtures.py --wide-files 1000000 --fanout-directories 10000 --files-per-directory 100 --empty`. Direct enumeration uses `RADIX_BENCH_ENUMERATION_PATH` and `PerformanceAuditBenchmarkTests.testNativeEnumerationAllocationBenchmark`; complete scans use `RADIX_BENCH_AUDIT_PATH` and the existing filesystem audit benchmark. Run each separately through `rtk proxy swift test -c release --filter`. Frontier probes additionally use `RADIX_SCAN_DIAGNOSTICS=1`, `-Xswiftc -DDEBUG`, and `--scratch-path .build/performance-audit/queue-profile`. No user files were modified.
