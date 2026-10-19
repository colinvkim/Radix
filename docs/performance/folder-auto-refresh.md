# Focused folder automatic refresh

The watcher covers the completed live scan and replays its original FSEvents
checkpoint. Dirty paths survive navigation and replacement of a subtree. Only
the folder being browsed is refreshed when its contents change; selecting a
file does not change that scope. If the focused folder disappears, refresh
targets its nearest existing ancestor in the retained scan. Imported snapshots
do not start a watcher. A volume's root remains manual; the root of a folder
scan can refresh automatically.

Settings → Scanning → “Keep the current folder updated” controls this behavior.
It is enabled by default and persists across launches. Disabling it cancels
automatic work; re-enabling it catches up from the retained scan checkpoint.

Refreshes debounce relevant changes for one second, capped at five seconds
under sustained writes, and run one at a time.
After completion, the next refresh waits at least five seconds, or twice the
previous refresh's elapsed time when that is longer. Old results remain visible
while scanning and merging. Publication waits for active interactions to end.
Cancellation during window closure retains dirty work. Automatic refresh does
not enable the Stop command. Unsafe shared-allocation updates
and scan failures pause that folder and offer an explicit manual rescan.

Manual and automatic folder refreshes preserve expanded folders and their
materialized descendants. Collapsed and newly discovered folders can still use
automatic summaries.
Explicit scan, import, export, comparison, and tour commands preempt background
work. Manual folder refresh acknowledges changes known when it starts, while
events received during that scan stay pending. Native drags also defer publication.

Unchanged subtrees skip retained-tree replacement and volume-capacity queries.
Real changes still rebuild the retained tree off the main actor. The watcher
mailbox and dirty-path collection each cap at 4,096 entries; overflow preserves
a conservative root marker that each refreshed scope acknowledges separately.

## Retained-tree merge measurement

Measured October 4, 2026 in optimized Release tests on the development Apple
Silicon host. Each directory holds 1,000 independent 4 KiB records. Replacing
one directory adds one file: a 1,002-node replacement. Each process performs
one warm-up followed by three measured merges against the same baseline.

| Retained nodes | Median merge | Setup RSS | Process peak RSS |
| ---: | ---: | ---: | ---: |
| 200,201 | 55.38 ms | 187 MiB | 236 MiB |
| 1,001,001 | 258.28 ms | 747 MiB | 979 MiB |

These measurements cover tree replacement only. They exclude filesystem I/O,
snapshot warning/capacity work, browser indexing, chart layout, and publication.
The fixture has short paths and no hard links or clones. Memory figures include
the retained fixture; peaks come from process high-water RSS, with a concurrent
20 ms RSS sampler. Large scans still require memory headroom, and these numbers
are observations rather than performance assertions.

The opt-in test is compiled with the core tests. Run it to reproduce:

```sh
RADIX_BENCH_FOLDER_MERGE=1 RADIX_BENCH_MERGE_DIRECTORIES=200 swift test -c release --scratch-path /private/tmp/radix-folder-merge-benchmark --filter FolderMergeBenchmarkTests
RADIX_BENCH_FOLDER_MERGE=1 RADIX_BENCH_MERGE_DIRECTORIES=1000 swift test -c release --scratch-path /private/tmp/radix-folder-merge-benchmark --skip-build --filter FolderMergeBenchmarkTests
```

The complete core suite and Debug app build passed. Manual testing used this
worktree's exact Debug bundle and covered live folder updates, retained
selection/Discard Pile, navigation, disabling/re-enabling with historical
catch-up, and Quick Look remaining open until its pending update could apply.
