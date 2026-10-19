# Rejected auto-summary probe reuse

A rejected descendant probe previously returned only directories it had already
finished listing. If rejection happened inside a directory, ordinary traversal
listed that directory again.

The probe now finishes active, replay-eligible listings within a retained-entry
budget. Ordinary traversal reuses those complete arrays after its existing
identity-checked directory open. The rejected result holds no directory cursor.

## Retention and failure behavior

The shared limit is 65,536 retained entry units. Completed listings and active
prefixes share one per-probe budget. Empty listings cost one unit. The scan's
existing replay cache uses the same limit.

A listing enters the result only after normal exhaustion. A late native error,
unsupported backend, or exceeded budget discards that listing's replay copy.
Ordinary traversal then lists it normally. Cancellation propagates and closes
active cursors. Read-ahead does not classify new descendants or change the
sampled profile, visit count, or `fullyExhausted` decision.

This is an entry limit, not a global memory, byte, or I/O limit. One fetched
batch can transiently exceed it. Filtered raw entries still require I/O.
Concurrent probes, existing work buffers, accepted cursor continuations, and the
preexisting eager listing after 64 active cursors have separate costs. A listing
that exceeds the budget can incur extra read-ahead and still need another walk.

## Complete-scan measurement

Five alternating Release pairs compared baseline `1814e31` with the candidate on
one immutable fixture. The fixture has `projects/node_modules/shard` with 6,000
files of 8,192 bytes. Production defaults reject its descendant probe after
5,000 files because their average size exceeds 4,096 bytes. The measured region
includes engine construction, traversal, node assembly, and the finished event.
Fixture creation, fingerprint calculation, and reporting are outside it.

| Complete scan | Median | Range |
| --- | --- | --- |
| Baseline | 46.099 ms | 45.458 to 48.940 ms |
| Candidate | 41.510 ms | 39.805 to 41.855 ms |

The candidate median is 10.0% lower on this controlled fixture. Full-disk timing remains
unmeasured. Every run produced 6,004 retained nodes, 6,000 files,
four directories, 49,152,000 logical and allocated bytes, and zero warnings.
Full tree, semantic, and warning fingerprints match in all ten measured scans.
The [samples](rejected-probe-scan-samples.json) contain the actual receipts.

The host ran macOS 27.0.1, Xcode 27.0, Swift 6.4, and had ten logical cores.
Builds and full-disk scans had stopped before measurement. The observed load
average before profiling was 4.88, 9.49, and 10.17. Historical build load was
still decaying, so sides alternated after one warmup each. A separate one-second
stack sample showed native metadata enumeration, URL construction, node
construction, and sorting. The sample was excluded from reported timings.
Median system CPU fell from 13.453 to 9.426 ms. Node construction and assembly
remain work that listing reuse cannot remove.

## Mechanism and fallback checks

The opt-in 1,600-file probe-and-replay test uses one partial descendant and no
completed siblings. A zero retention budget reproduces the old replay behavior
for this fixture. Its simplified walker requires one ordinary native listing
without reuse and zero with reuse. Complete node arrays match. The production
scanner still obtains its ordinary directory lease before using cached entries.

Five rotated samples had medians of 4.881 ms without retention, 5.317 ms with a
500-entry budget, and 4.400 ms with the production budget. Their ranges overlap,
so these micro timings alone are inconclusive. The small budget demonstrates
the bounded fallback that still requires an ordinary listing. Probe duration
increases because read-ahead moves work before the rejected outcome returns.

The core suite also exercises multi-batch tails, completed siblings, empty
listings, cancellation, late native failures, held-outcome descriptors,
replacement identities, allowed firmlinks, exclusions, hidden files, hard links,
and existing accepted-probe continuation.

## Reproduce

Build the baseline and candidate in separate checkouts. From each checkout, run:

```sh
swift test -c release --scratch-path .build/rejected-probe-bench \
  --filter FullDiskScanScalingBenchmarkTests/testScenarioMatrixCoversCartesianProduct
```

From the candidate checkout, pass both checkout paths and their scratch paths:

```sh
python3 tools/benchmark-rejected-probe.py /path/to/baseline /path/to/candidate \
  --baseline-scratch /path/to/baseline/.build/rejected-probe-bench \
  --candidate-scratch /path/to/candidate/.build/rejected-probe-bench \
  --output /tmp/radix-rejected-probe-results
```

The script requires at least five alternating pairs and rejects failed scans,
wrong literal totals, or changed fingerprints. It deletes only its own fixture.
To run the synthetic mechanism comparison in the candidate checkout:

```sh
RADIX_BENCH_REJECTED_PROBE=1 swift test -c release \
  --filter AtomicProbeReplayTests/testRejectedProbeReplayBenchmark
```
