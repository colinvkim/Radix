**Radix performance audit — 4 September 2026**

Follow-up: selection resolution and capability-cache path normalization are implemented; see [before/after validation](/Users/colin/Programming/Radix/docs/performance-audit/fixes-2026-09-04.md). Unchanged navigation refreshes now also skip directory materialization; see [refresh validation](/Users/colin/Programming/Radix/docs/performance-audit/refresh-2026-09-04.md). The original audit findings and measurements below remain the baseline for the other work.

Large-result browser sorting now moves compact row indices through its sort buffers; see [sorting validation](/Users/colin/Programming/Radix/docs/performance-audit/sort-2026-09-04.md).

Metadata-only whole-scan searches now skip text-index construction when no valid index exists; see [metadata-search validation](/Users/colin/Programming/Radix/docs/performance-audit/metadata-2026-09-04.md).

Million- and two-million-file scans now have pending-buffer and RSS measurements. The tested shapes did not justify adding backpressure; see [scanner queue findings](/Users/colin/Programming/Radix/docs/performance-audit/queue-2026-09-04.md).

Completed-scan lifetime probes now distinguish live allocations from residual allocator memory and quantify the cache's oversized retention and synchronous release costs; see [retention findings](/Users/colin/Programming/Radix/docs/performance-audit/retention-2026-09-04.md).

The completed-scan cache now charges full backing trees once, evicts older independent oversized scans, and releases discarded ownership through a bounded background worker. Paired million-file runs halved live cached allocations and reduced median main-actor eviction from 462 ms to 0.044 ms; see [cache validation](/Users/colin/Programming/Radix/docs/performance-audit/cache-2026-09-04.md).

**Follow-up status — 5 September 2026**

Counting the nine prioritized findings below, five retain unfinished work after the chart fix: four are partly addressed and comparison work is open. Four findings are complete. This counts whole findings, including their secondary recommendations; completing a finding's largest fix does not close its remaining follow-ups.

| Finding | Status | Remaining work |
| --- | --- | --- |
| 1. Selection resolution | Complete | Empty/single selection fast paths validated. |
| 2. Metadata reads | Partial | Capability-cache path probes removed; sharing status/identity/allocation reads within a metadata load remains. |
| 3. Large sorts | Partial | Browser index sorting and cancellation validated; scanner finalization sorting and cancellation still need focused profiling. |
| 4. Main-actor navigation/publication | Partial | Unchanged refreshes and cache releases improved; changed-directory row projection and browser-owned buffer release remain. |
| 5. Metadata-only search | Complete | Text indexing is deferred until needed. |
| 6. Scanning allocations/queues | Partial | Queue retention measured and a scheduling limit deferred; per-entry native-name allocations and other frontier shapes remain follow-ups. |
| 7. Completed-scan cache | Complete | Full backing accounting, eviction, and bounded background cleanup validated. |
| 8. Chart preparation | Complete | Shared selective color preparation, skipped unrenderable children, and cooperative cancellation implemented; see [chart validation](/Users/colin/Programming/Radix/docs/performance-audit/charts-2026-09-05.md). |
| 9. Comparison projection/sorting | Open | Measure and reduce repeated projection; improve cancellation and sorting. |

The queue-policy part of finding 6 is deferred because the measured workloads did not show sustained queue accumulation. The broader profiling opportunities under “Other investigated areas” are not included in this nine-finding count.

**Original audit baseline**

The highest-priority issue is main-actor selection resolution: even an empty selection walks every row in the focused directory's table contents. A million-row directory spent 285–332 ms resolving zero or one selected item. Large-result sorting and retained tree representations are the next substantial costs. Native APFS traversal is already effective: the 100,000-file fixture completed in 424 ms with almost no per-file metadata calls.

This audit covers revision `b4d1b5dcd554dc2516b14bf2750bc51af7134d06`. Production code was not changed. The added opt-in benchmarks and measurement tools make the findings reproducible.

**Measurements and limits**

Measurements used an Apple M5 MacBook Air, 10 CPU cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6, and local APFS. Timing runs used optimized SwiftPM Release builds, ran sequentially in fresh test processes, and were separate from instrumentation. Filesystem caches were warm/uncontrolled; these are not cold-disk measurements. MB and GB below are decimal. RSS is whole-process resident memory, including XCTest, fixture construction, live buffers, and allocator retention; it is not a count of allocations or an isolated size of `FileTreeStore`.

The filesystem fixtures contain one-byte regular files with equal allocated sizes. The flat fixture has 10,000 files; the fanout fixture has 100 directories containing 1,000 files each. Automatic summarization was disabled for these fixtures. Medians use three runs with native/Foundation ordering alternated. In these measurements, “Foundation” or “fallback” means an injected `FileManager.contentsOfDirectory` backend, as used by existing comparison benchmarks. It shares production metadata classification, but shipping compatibility enumeration uses `FileManager.enumerator` through `ScanEngine.defaultDirectoryContents`; the baseline does not exactly reproduce its enumeration/error handling.

| Filesystem workload | Native elapsed | Forced Foundation elapsed | Native/Fallback peak RSS ranges |
| --- | ---: | ---: | ---: |
| 10,000 files, one directory | 57.6 ms | 232.3 ms | 63.0–63.1 / 78.2–80.7 MB |
| 100,000 files, 101 directories | 424.4 ms | 2,270.1 ms | 182.6–185.0 / 260.6–262.5 MB |
| Depth 256, one file per level | 23 ms | 61 ms | Not sampled by that benchmark |

Native throughput was approximately 174,000 files/s flat and 236,000 files/s in the fanout fixture, including final tree construction. The latter was 5.35 times faster than forced Foundation on this machine. This comparison does not establish the same ratio on network, removable, or uncached filesystems.

The read-only `/Applications` scans found 355,884 files and matching allocated/logical byte totals and semantic fingerprints. Package-collapsed runs took 1.57 and 1.34 seconds, retained 65 nodes, and peaked near 84 MB RSS. Expanding packages with automatic summarization disabled took 2.67 seconds, retained 424,432 nodes, and peaked at 717 MB. Cancellation after 250 ms completed in 3.0–4.6 ms collapsed and 13.4 ms expanded; all workers quiesced. These are two collapsed samples and one expanded sample, not a controlled statistical comparison.

| Optimized synthetic workload | Measured result |
| --- | ---: |
| Resolve empty / single selection, 100,000 rows | 28.6 / 30.2 ms, main actor |
| Resolve empty / single selection, 1,000,000 rows | 285.4 / 331.5 ms, main actor |
| Existing direct selected-node lookup, 1,000,000 rows | 2–4 microseconds |
| Install / refresh unchanged million-row navigation contents | 18.7 / 92.7 ms, main actor |
| Million-result browser sort | 2.747 seconds |
| Browser cold text-index preparation | Approximately 1.750 seconds; 121.8 MB RSS increase |
| Warm browser text search / metadata filter, million results scanned | 355 / 80 ms |
| Browser initial publication / replacement of uniquely owned old state | 0.060 / 49.9 ms, main actor |
| Browser end-to-end broad result refresh | 4.868 seconds |
| Browser fixture / complete benchmark sequence peak RSS | 905 MB / 2.097 GB |
| Flat million-child root, Sunburst / Treemap layout | 283 / 116 ms; each emits one aggregate segment |

The browser index time is the existing benchmark's estimate: cold search minus median warm no-match search. Its complete sequence retains several result sets and tests cancellation, so its 2.097 GB peak is not a claim that every million-node scan consumes that much memory. Publication probes exclude SwiftUI diffing and rendering. Direct chart benchmarks measure algorithm time; shipping layout services run off the main actor. Selection timings are medians of five calls; direct lookup, installation, unchanged refresh, and flat-root chart timings are single samples. Fresh processes apply to benchmark invocations, not phases: the navigation benchmark's two fixture sizes and successive phases share a process, with Sunburst preceding Treemap and navigation. Allocator reuse affects later RSS deltas.

**Filesystem calls**

Separate interposition runs counted six libc entry points for paths/descriptors within the generated fixtures. Counts include Radix and Foundation internals. They exclude opens, closes, `fcntl`, extended-attribute APIs, unhooked/private variants, and other filesystem work. Descriptor filtering itself adds `F_GETPATH` calls, which is why instrumented elapsed times are not used above.

| Fixture and scanner | `getattrlistbulk` | Returned bulk entries | `getattrlist` | `lstat` | `stat` | `fstat` | `fstatat` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10k native | 28 | 10,000 | 2 | 3 | 2 | 1 | 0 |
| 10k Foundation | 149 | 10,000 | 20,006 | 20,008 | 2 | 1 | 0 |
| 100k native | 402 | 100,100 | 102 | 3 | 2 | 101 | 0 |
| 100k Foundation | 1,603 | 100,100 | 200,406 | 200,506 | 2 | 101 | 0 |

Foundation also uses bulk enumeration internally. Its additional per-entry metadata work is the main distinction here. Native records carry metadata from `getattrlistbulk` into node creation; the extra native `getattrlist` calls scale with directories, not regular files.

Two sampled fallback `lstat` stacks identified (1) Radix's dataless-status read and (2) a Foundation URL constructor called by Radix's volume-capability cache. Debug diagnostics counted only 303 `metadata.lstat` identity-provider calls for the 100k fallback fixture, confirming that the approximately 100k second per-file calls were not its identity fallback. The observed `getattrlist` count is consistent with Foundation resource-value work plus explicit clone queries; individual `getattrlist` callers were not stack-attributed.

**Prioritized findings**

1. **P1: Resolve selection by selected IDs, especially for zero or one item.** [WorkspaceNavigationModel.swift:447](/Users/colin/Programming/Radix/Radix/ViewModels/WorkspaceNavigationModel.swift:447) scans `tableNodes` regardless of selection size. [SelectionInspectorView.swift:23](/Users/colin/Programming/Radix/Radix/Features/Inspector/SelectionInspectorView.swift:23) and [RadixCommands.swift:12](/Users/colin/Programming/Radix/Radix/App/RadixCommands.swift:12) call it while evaluating their bodies. The measured 285–332 ms main-actor cost is sufficient to cause a visible pause. Return immediately for no selection and use the existing indexed tree lookup for one selected ID. Preserve table ordering for multiselection. Re-run the new selection benchmark and existing selection/navigation tests; the expected improvement should be measured after implementation.

2. **P2: Path normalization performs an unnecessary metadata read for every fallback file.** [ScanMetadataLoader.swift:17](/Users/colin/Programming/Radix/Radix/Services/ScanMetadataLoader.swift:17) obtains `url.path`, then [line 55](/Users/colin/Programming/Radix/Radix/Services/ScanMetadataLoader.swift:55) reconstructs `URL(fileURLWithPath:)` without a directory hint. The captured stack shows that constructor issuing `lstat`. This happens during clone-capability lookup even when the volume capability is cached. Preserve a normalized path/URL already available, or normalize lexically without directory detection; verify namespace and volume-boundary behavior. This can remove approximately one intercepted `lstat` per ordinary file on the measured fallback path. Separately, [nodeMetadata at line 468](/Users/colin/Programming/Radix/Radix/Services/ScanMetadataLoader.swift:468) reads status and may then read the same `stat` fields again for directory identity or missing allocation/identity values. Share one lazy status result within a metadata load. Preserve before/after enumeration identity checks, which protect against directory replacement.

3. **P2: Large sorts move full records through multiple arrays.** [FileBrowserResults.swift:127](/Users/colin/Programming/Radix/Radix/Services/FileBrowserResults.swift:127) wraps complete records in prepared sort entries; [CancellableSort.swift:18](/Users/colin/Programming/Radix/Radix/Services/CancellableSort.swift:18) creates sorted runs and a second merge buffer; the browser then materializes another record array. `FileNodeRecord` has a measured stride of 168 bytes before its referenced strings/URLs. Sorting one million results took 2.747 seconds, with process peak RSS increasing from the broad-filter phase's 1.441 GB high-water mark to 1.845 GB. These are COW/reference-sharing copies, not independent deep copies of all paths. Sort compact indices with necessary scalar keys, then materialize once. Cancellation took 116 ms in this sort benchmark despite checks between chunks; inspect the 16,384-element non-interruptible chunk sorts and release cost. Also inspect [scan finalization at ScanEngine.swift:2149](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2149): every sibling list is sorted serially, with localized name comparison on size ties and cancellation only after each sort. Debug diagnostics identified final assembly as substantial, but its timings are not Release cost estimates.

4. **P2: Main-actor navigation copies complete directories, and publication can destroy large old buffers synchronously.** [WorkspaceNavigationModel.swift:357](/Users/colin/Programming/Radix/Radix/ViewModels/WorkspaceNavigationModel.swift:357) materializes all focused children before checking whether contents changed. This costs 18.7 ms on million-row installation and 92.7 ms for an unchanged refresh. The browser's later 512-row background-work threshold cannot protect this earlier step. Use existing content identity/revision to skip unchanged work and prepare large projections off the main actor. [FileBrowserModel.swift:374](/Users/colin/Programming/Radix/Radix/Services/FileBrowserModel.swift:374) replaces display state synchronously; the same replacement operation took 49.9 ms with uniquely owned old million-row containers, versus 0.060 ms for initial publication. Synchronous release is the likely explanation, but deallocation was not timed separately. Actual SwiftUI retention can move the final release elsewhere, so this is a demonstrated risk rather than a measured frame duration for every update. Consider controlling where obsolete large storage is released after profiling ownership.

5. **P2: Metadata-only whole-scan queries build an unused text index.** [FileBrowserSearch.swift:93](/Users/colin/Programming/Radix/Radix/Services/FileBrowserSearch.swift:93) always constructs the index for a new snapshot, including URL paths, normalized name/kind text, and parent groups, even when the query is only “Files” or a size filter. Text is then bypassed at line 132. The million-node text-index benchmark estimates 1.750 seconds and 121.8 MB additional RSS for this preparation. A metadata-only path can filter existing records before any text index is needed; retain the current cache for actual text searches. Measure that new path separately rather than assuming the full index estimate becomes its exact speedup.

6. **P2: Bounded workers do not bound pending metadata memory.** [ScanEngine.swift:2665](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2665) drains native batches into a whole-directory array. Leaf requests at [line 2005](/Users/colin/Programming/Radix/Radix/Services/ScanEngine.swift:2005) retain that array plus their ranges; unfinished requests keep its URLs, metadata, and names alive. The pending list has no entry/byte budget, so an accumulating directory frontier can coexist with completed nodes. Requests share COW backing storage, rather than copying the whole listing per request. Introduce backpressure based on pending entries before redesigning enumeration, and measure peak live entry counts. [BulkDirectoryEnumerator.swift:585](/Users/colin/Programming/Radix/Radix/Services/BulkDirectoryEnumerator.swift:585) also allocates a native-name byte buffer for each accepted entry; ordinary file preparation does not consume it. Avoid that buffer for eligible regular files while retaining descriptor-relative directory names and Unicode collision checks. Allocation counts and attributable savings have not been measured with Allocations.

7. **P2: The completed-scan cache's memory budget is intentionally soft.** [AppModel.swift:301](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:301) configures a 250,000-node budget but at least two retained snapshots. [SidebarScanCacheController.swift:78](/Users/colin/Programming/Radix/Radix/ViewModels/SidebarScanCacheController.swift:78) stops eviction at that minimum regardless of size. Two independently scanned huge trees can remain while another scan is built. Small logical scopes also retain their full backing store. This is retention policy, not a leak. Allow memory pressure or a hard size ceiling to override the minimum, accounting for shared backing stores so logical scopes are not charged as independent copies.

8. **P2: Chart preparation retains work that cannot affect rendered output.** [SunburstGeometry.swift:301](/Users/colin/Programming/Radix/Radix/Services/SunburstGeometry.swift:301) materializes global-root children again and constructs a color dictionary for every child, even when a million children collapse into one aggregate segment. Those extra loops lack cancellation checks. Flat-root layout took 283 ms versus Treemap's 116 ms on the same fixture; the difference is not an isolated measurement of the dictionary cost. Reuse children and keep color positions only for needed branches, following Treemap's existing approach. [TreemapGeometry.swift:147](/Users/colin/Programming/Radix/Radix/Services/TreemapGeometry.swift:147) loads children before checking whether the tile has enough room to display them. Check bounds first to avoid potentially large discarded arrays.

9. **P2: Comparison projection and sorting have avoidable repeated work and cancellation gaps.** [ScanComparisonBrowserModel.swift:161](/Users/colin/Programming/Radix/Radix/ViewModels/ScanComparisonBrowserModel.swift:161) rebuilds significant-change projection on text/path/sort updates although it depends only on the comparison and selected change kinds. Reuse that projection when its actual inputs are unchanged. Its traversal has only surrounding cancellation checks, so superseded requests can keep retaining trees and consuming CPU. [ScanComparisonService.swift:790](/Users/colin/Programming/Radix/Radix/Services/ScanComparisonService.swift:790) also uses monolithic row sorting. Use cancellable sorting and checks inside large traversals. These are source-confirmed costs; large comparison timing was not measured in this audit.

**Other investigated areas**

| Area | Finding and next action |
| --- | --- |
| Concurrency and scheduling | Scanning is explicitly outside actor isolation; traversal, classification, leaf preparation, and summaries have bounded workers. On the 10k flat fixture, default scheduling averaged 55 ms, serial 62 ms, and four classification workers with one traversal worker 64 ms. More tasks did not reliably improve this workload. Preserve the existing shared worker budget. |
| Locks and actor serialization | [AtomicDirectoryParallelSummary.swift:503](/Users/colin/Programming/Radix/Radix/Services/AtomicDirectoryParallelSummary.swift:503) checks a shared generation token through `NSLock` for every entry. This establishes lock frequency, not measured contention. Profile before changing it; bounded-interval token checks may reduce traffic while preserving cancellation. Chart/search actors serialize requests, making cancellation gaps more relevant. |
| SwiftUI updates during scanning | Metrics use a separate observable object and [100 ms coordinator throttle](/Users/colin/Programming/Radix/Radix/Services/ScanCoordinator.swift:64). Full scans publish the tree at completion; folder-rescan progress is scoped to its banner. No code path was found that republishes the tree or recomputes its charts for every scanned file. Engine progress-event counts are not SwiftUI update counts. Actual body evaluations/frame timing were not traced. |
| Formatting | Browser display values are cached lazily; byte/date formatter instances are reused behind a lock. No formatter use was found in the scanner hot path. Treemap labels/tooltips can repeat size/date/path formatting during redraws; profile visible costs before introducing another cache. Formatter-lock contention was not demonstrated. |
| Aggregation | Tree aggregate statistics are precomputed, and native metadata/probe results are reused. Incremental subtree replacement still reconstructs the contiguous store and rebalances shared allocation; this is a whole-tree CPU/memory cost even when disk rereads are localized. Comparison projection is the clearest avoidable repeated traversal. |
| Persistence and archives | Preferences debounce/deduplicate writes; usage statistics persist on discrete actions, not each progress event. Modern archive node and topology export streams data. The 64,065-node archive exported in 258 ms and imported in 147 ms; sampled import RSS increase was 54.7 MB. Export child-index copies and wholesale topology decoding during import remain large-archive memory candidates. These archive timings are single samples. |
| Compatibility enumeration | A consistently unsupported bulk filesystem is retried per directory before fallback. Cache only stable volume-level capability failures, not malformed entry or Unicode-collision failures. Fallback namespace preservation also derives every child's parent URL/path; optimize only with firmlink/namespace parity tests. No network/removable filesystem was measured. |
| String work | Besides the confirmed URL-constructor `lstat`, search checks each haystack's `String.count` before substring matching, and inspector warning filtering repeatedly normalizes warning paths. Unicode-heavy and warning-heavy workloads should be measured before ranking these smaller candidates. |

The existing packed `UInt32` topology, iterative traversal, 64 KiB native batches, early exclusion filtering, descriptor-relative opens, resumed summary probes, cached text index, and separated chart canvases should be preserved. They already address many common disk-analyzer bottlenecks. Native collapsed `/Applications` CPU time exceeded wall time substantially, consistent with useful parallel summary work; it does not establish a lock-contention percentage.

**Recommended implementation order**

Start with selection fast paths and the capability-cache URL reconstruction, which have direct measurements and narrow fixes. Next address unchanged navigation refreshes, compact sorting, and unnecessary text indexing. Then measure pending-entry high-water marks and cache retention on multi-million-node scans before changing memory policy. Chart/comparison cancellation and projection reuse can follow as focused changes. Preserve hard-link/clone accounting, dataless-file handling, namespace correctness, cancellation, and explicit file-action guarantees throughout.

**Validation and reproduction**

The final core test run passed: 885 tests, 26 opt-in tests skipped, zero failures. All selected benchmarks passed, including the new navigation/filesystem probes. The complete Debug app build succeeded at the required `.build/xcode-derived-data` location. No app source was changed, and no files in scanned targets were modified. Generated filesystem fixtures were separate temporary data.

The [opt-in tests](/Users/colin/Programming/Radix/RadixCoreTests/PerformanceAuditBenchmarkTests.swift), [raw result records](/Users/colin/Programming/Radix/docs/performance-audit/results-2026-09-04.json), [interposition source](/Users/colin/Programming/Radix/docs/performance-audit/syscall-counts.c), and [sampled call chains](/Users/colin/Programming/Radix/docs/performance-audit/lstat-call-stacks.txt) are retained with the audit.

From this checkout, run each benchmark separately to avoid overlapping workloads:

```sh
rtk proxy env RADIX_BENCH_AUDIT=1 swift test -c release --filter PerformanceAuditBenchmarkTests.testNavigationAuditBenchmark
rtk proxy env RADIX_BENCH_FILE_BROWSER=1 swift test -c release --filter FileBrowserBenchmarkTests.testMillionNodeFileBrowserBenchmark
rtk proxy env RADIX_BENCH_AUDIT_PATH=/absolute/path/to/fixture swift test -c release --filter PerformanceAuditBenchmarkTests.testFilesystemAuditBenchmark
rtk proxy env RADIX_BENCH_AUDIT_PATH=/absolute/path/to/fixture RADIX_BENCH_AUDIT_FOUNDATION=1 swift test -c release --filter PerformanceAuditBenchmarkTests.testFilesystemAuditBenchmark
```

Create the same file shapes with `rtk proxy python3 docs/performance-audit/make-fixtures.py` using [make-fixtures.py](/Users/colin/Programming/Radix/docs/performance-audit/make-fixtures.py); it writes only a newly created temporary directory and prints its paths. The existing `RADIX_BENCH_DEEP_DIRECTORY`, `RADIX_BENCH_WIDE_DIRECTORY`, `RADIX_BENCH_ARCHIVE`, `RADIX_BENCH_SUNBURST`, and `RADIX_BENCH_TREEMAP` flags enable the other benchmark classes recorded in the results file. `/Applications` used `FullDiskScanScalingBenchmarkTests.testFullDiskScanScalingBenchmark` with `RADIX_BENCH_FULL_SCAN_SCALING=1`, `RADIX_BENCH_FULL_SCAN_PATH=/Applications`, and `RADIX_BENCH_FULL_SCAN_SCENARIO=collapsed-auto-none` or `RADIX_BENCH_FULL_SCAN_SCENARIO=expanded-manual-none`.

For call counts, first build the test bundle, compile the interposer, and invoke Xcode's `xctest` runner with `DYLD_INSERT_LIBRARIES`, `RADIX_AUDIT_COUNT_PATH`, and `RADIX_BENCH_AUDIT_PATH` set. The test bundle itself is not a standalone executable:

```sh
rtk proxy mkdir -p .build/performance-audit
rtk proxy clang -dynamiclib -O2 docs/performance-audit/syscall-counts.c -o .build/performance-audit/syscall-counts.dylib
rtk proxy env RADIX_AUDIT_COUNT_PATH=/absolute/path/to/fixture RADIX_BENCH_AUDIT_PATH=/absolute/path/to/fixture DYLD_INSERT_LIBRARIES=/Users/colin/Programming/Radix/.build/performance-audit/syscall-counts.dylib /Applications/Xcode.app/Contents/Developer/usr/bin/xctest -XCTest RadixCoreTests.PerformanceAuditBenchmarkTests/testFilesystemAuditBenchmark .build/arm64-apple-macosx/release/RadixCorePackageTests.xctest
```

Add `RADIX_BENCH_AUDIT_FOUNDATION=1` for the injected Foundation baseline counts. `RADIX_AUDIT_STACKS=1` captures the first two `lstat` call stacks for fixture filenames containing `file-00000000.dat`; use the flat fixture and a Debug test bundle for readable internal symbols. Fanout directories repeat this filename, so concurrent workers could otherwise capture two status reads. Debug `RADIX_SCAN_DIAGNOSTICS=1` provides operation-level attribution, but totals overlap across concurrent/nested operations and cannot be summed into elapsed time or treated as complete syscall counts.

Unmeasured boundaries remain: cold-cache storage latency, network/removable and cloud-provider behavior, allocation-event totals, live SwiftUI frame/body traces, lock wait time, and full startup-volume memory at multi-million-node scale. The findings above distinguish those follow-up measurements from confirmed code paths and observed timings.
