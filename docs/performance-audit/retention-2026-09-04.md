**Completed-scan retention — 4 September 2026**

Live malloc usage returns close to baseline after the last tested snapshot owner drops it. The completed-scan cache deliberately keeps multiple independent trees alive, and a small logical scope retains its complete backing tree. Those ownership rules, together with synchronous destruction on the main actor, are the clearest next implementation targets.

This pass adds a reproducible retention benchmark and records attribution; application behavior remains unchanged from `4b0da38`. It separates the high RSS observed in the [queue audit](/Users/colin/Programming/Radix/docs/performance-audit/queue-2026-09-04.md) into live allocations and residual allocator storage. These probes do not establish that every application feature is leak-free.

Three fresh-process Release runs covered each of five scenarios: one snapshot, three scans released individually, three scans stored in the completed-scan cache, a cached folder scope, and parent-to-folder navigation sharing storage with the cache. The 15 processes performed 27 completed native scans. A separate process supplied the VM-map capture. Builds, scans, and captures ran sequentially without overlapping workloads.

Measurements used the same Apple M5 MacBook Air, 10 cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6, and local APFS. The generated fixture has 100 directories containing 10,000 empty regular files each: 1,000,000 files and 101 directories including the root. Filesystem caches were warm/uncontrolled. Automatic summaries were disabled. Repeated scans used three distinct combinations of hidden-file and package options so their cache keys differed; the fixture has no hidden files or packages, and all three scans returned identical counts. These are independently built trees of the same filesystem target.

The benchmark records process RSS, `task_vm_info.phys_footprint`, reusable VM bytes, and all-zone malloc statistics. MB below is decimal. Malloc bytes in use describe outstanding heap allocations, not total process memory or an exact retained-object graph. RSS, footprint, reusable pages, and allocator-reserved bytes have different accounting rules and must not be added together. The `vmmap` artifact preserves the tool's own displayed units. Native enumeration runs off the main actor; cache and navigation checkpoints and the measured synchronous operations run on it.

| Ownership state, median of three | Malloc bytes in use | RSS | Physical footprint |
| --- | ---: | ---: | ---: |
| One completed million-file snapshot retained | 914.3 MB | 1,318.6 MB | 1,279.7 MB |
| Last owner released, then 100 ms allowed to settle | 1.5 MB | 1,001.2 MB | 412.5 MB |
| Two independent completed snapshots cached | 1,827.1 MB | 2,241.0 MB | 2,202.5 MB |
| Third scan completed before cache insertion/eviction | 2,739.9 MB | 3,159.7 MB | 3,122.2 MB |
| Third insertion evicts the oldest; two remain cached | 1,827.1 MB | 2,837.6 MB | 2,248.0 MB |
| Cache cleared, then 100 ms allowed to settle | 1.5 MB | 2,597.6 MB | 1,471.3 MB |

Initial malloc usage was approximately 1.1 MB and initial RSS approximately 42.2 MB. After a standalone snapshot is released, the roughly 913 MB of additional live heap allocations disappears even though RSS stays high. The separate VM-map capture after clearing a three-scan cache run identifies most remaining writable resident mappings as `MALLOC_SMALL (empty)` and `MALLOC_LARGE (empty)`. Its default malloc zone reports about 1,272K of allocated bytes against 935.5M of dirty memory, plus separate empty large mappings. This supports allocator retention/fragmentation as the residual-memory explanation in that capture.

Calling `malloc_zone_pressure_relief(nil, 0)` at the final checkpoint reported zero bytes released in every measured process and did not materially change the counters. It is a diagnostic step in the benchmark only. These results provide no basis for adding periodic allocator-purge calls to the app or assuming that freed heap memory immediately reduces RSS.

When each snapshot was released before starting the next scan, all three iterations returned live malloc usage to approximately 1.5 MB. The third retained snapshot still used about 914.3 MB, rather than the cache scenario's 2,739.9 MB with three trees alive. After the third release and settling, median RSS was 1,253.0 MB and footprint 602.1 MB. Residual allocator memory changed across iterations, but these three scans did not leave a growing set of live snapshot allocations. This is a bounded experiment, not a claim about arbitrarily long sessions or behavior under system memory pressure.

The cache behavior is explicit in [CompletedScanCache](/Users/colin/Programming/Radix/Radix/ViewModels/SidebarScanCacheController.swift:18): `store` charges `treeStore.nodeCount`, and eviction stops at the configured minimum snapshot count. [AppModel](/Users/colin/Programming/Radix/Radix/ViewModels/AppModel.swift:301) sets a 250,000-node budget and a two-snapshot minimum. Two million-node stores therefore remain cached despite exceeding that budget. [Starting another scan](/Users/colin/Programming/Radix/Radix/Services/ScanCoordinator.swift:199) clears the coordinator's displayed/completed snapshots, while the sidebar cache survives. The measurements demonstrate intentional retention rather than an unexplained reference cycle in this path.

Logical scopes require different accounting. A 10,001-node folder scope alone retained 914.5 MB of live allocations, essentially the complete million-node parent tree. [Logical scoping](/Users/colin/Programming/Radix/Radix/Models/FileTreeStore.swift:2410) shares node/topology buffers and adds membership, traversal order, and sparse corrections. The cache currently charges only 10,001 nodes for this scope. Parent and scope are shared owners of the same large buffers; counting each as a full independent tree would overstate their combined cost.

In the navigation scenario, the cache held the parent and `WorkspaceNavigationModel` displayed the folder scope and its 10,000 table rows. Together they used 916.2 MB of live allocations. Clearing the parent cache entry left 916.2 MB alive through navigation. Clearing navigation then reduced live malloc usage to roughly 1.5 MB. Cache eviction cannot free storage that the displayed scope still needs.

| Synchronous main-actor operation | Median | Range |
| --- | ---: | ---: |
| Insert third large scan, evicting the oldest | 185.6 ms | 177.5–213.9 ms |
| Clear the two remaining cached large scans | 342.1 ms | 331.3–383.9 ms |
| Clear navigation when it is the last owner of the large backing tree | 178.7 ms | 177.5–183.3 ms |

These timings include the complete synchronous operation, not an isolated destructor trace or SwiftUI frame measurement. In the same navigation scenario, removing the cache entry while navigation still owned the tree took about one microsecond. The ownership-dependent cost is consistent with releasing millions of heap objects. Tightening eviction alone would encounter that cost earlier or more often, so release placement belongs in the follow-up design.

The next focused implementation should:

1. Account for the full backing store retained by a snapshot, deduplicating buffers shared by logical scopes. Keep this identity separate from the current scoped content identity, which changes when a scope is created.
2. Allow oversized independent scans to override the two-snapshot minimum. Preserve parent/folder navigation within the currently retained large tree; returning to an evicted independent scan may require rescanning. Existing tests deliberately preserve oversized scans, so this behavior change needs explicit regression coverage.
3. Release discarded large storage away from the main actor, with a clear ownership handoff and bounded pending disposal. Verify memory reduction and main-actor latency together; avoid merely moving retention into an unbounded release queue.

A cache policy that prevents old independent trees from coexisting addresses measured live memory and may reduce later allocator retention by lowering peak demand. Its exact savings and navigation tradeoffs must be measured after implementation. Reworking the whole tree representation or switching allocators is not justified by this investigation alone.

The new [opt-in benchmark](/Users/colin/Programming/Radix/RadixCoreTests/PerformanceAuditBenchmarkTests.swift:169) uses a separate non-inlined lifetime frame and explicit extended lifetimes to make ownership checkpoints meaningful in Release builds. It verifies completed scans have no warnings, and checks the navigation scope's node count. The runner also checked every scan's 1,000,101 nodes, every scope's 10,001 nodes, and that all memory checkpoints ran on the main thread. No elapsed-time thresholds are test assertions.

Validation passed: 890 core tests, 28 opt-in skips, zero failures, and the complete Debug app build at `.build/xcode-derived-data`. The diff passed whitespace checks. Review kept the instrumentation inside the existing opt-in test file and reused its snapshot fixture builder; no production ownership hooks, caches, or policy fields were added.

The generated filesystem fixture was removed after measurement. Its paths remain in the raw records for provenance.

Reproduce the filesystem fixture and run each scenario separately:

```sh
rtk proxy python3 docs/performance-audit/make-fixtures.py --wide-files 1 --fanout-directories 100 --files-per-directory 10000 --empty
rtk proxy env RADIX_BENCH_RETENTION=1 RADIX_BENCH_RETENTION_PATH=/absolute/path/to/fanout RADIX_BENCH_RETENTION_SCENARIO=single swift test -c release --filter PerformanceAuditBenchmarkTests.testSnapshotRetentionBenchmark
```

Use `repeat`, `cache`, `scope`, or `navigation` for the other scenarios. Omitting the path creates a synthetic flat tree; `RADIX_BENCH_RETENTION_FILES` controls its size. The reported measurements all used the native filesystem fixture. For a VM-map capture, set `RADIX_BENCH_RETENTION_PAUSE_SECONDS=15`, wait for the flushed `allocator_relief` line, then run `rtk proxy vmmap -summary` with the PID printed in that line. That pause occurs after the snapshot owners have been released.

[Raw phase records](/Users/colin/Programming/Radix/docs/performance-audit/retention-results-2026-09-04.json) preserve all 15 invocations, the capture invocation, and measurement definitions. The [VM-map summary](/Users/colin/Programming/Radix/docs/performance-audit/retention-vmmap-2026-09-04.txt) preserves the residual-memory attribution. Allocator API declarations and null-zone semantics were verified in the installed Xcode SDK's `malloc/malloc.h`; VM counter declarations were checked in `mach/task_info.h`.

The ownership probes cover scanner output, the completed-scan cache, and navigation state. They exclude live SwiftUI rendering, browser text-index retention, chart actors, imported archives, incremental checkpoints, long-lived comparison sessions, and memory-pressure notifications. A full application heap graph may reveal additional owners. These boundaries do not change the demonstrated cache-budget and synchronous-release costs.
