# Run the test-audit measurement tools

Use a controlled, readable fixture whose contents stay unchanged during each
comparison. Run each command from the repository root. Replace `/path/to/fixture`
with that fixture's absolute path.

## Measure traversal and metadata

```sh
RADIX_BENCH_TRAVERSAL_PATH=/path/to/fixture \
RADIX_BENCH_TRAVERSAL_WORKERS=1 \
swift test -c release --filter testNativeTraversalBenchmark
```

The measurement includes native directory traversal and metadata loading. It
omits retained-tree construction, sorting, allocation deduplication, and progress
publication. The test rejects incomplete metadata and asserts that traversal
includes at least the root directory. The reported totals have no independently
specified fixture expectation.

Record the fixture, worker count, revision, and complete output. Compare only
runs with the same fixture and worker count.

## Measure complete scans

Run native and Foundation enumeration in separate processes:

```sh
RADIX_BENCH_AUDIT_PATH=/path/to/fixture \
swift test -c release --filter testFilesystemAuditBenchmark

RADIX_BENCH_AUDIT_PATH=/path/to/fixture \
RADIX_BENCH_AUDIT_FOUNDATION=1 \
swift test -c release --skip-build --filter testFilesystemAuditBenchmark
```

The scan includes hidden files and disables automatic directory summaries.
The test requires a finished snapshot. It reports progress-event counts,
finalization timing, memory, allocation totals, and a tree fingerprint. Compare
the fingerprints and totals explicitly when checking parity. Printing a
fingerprint consumes output but does not assert an expected result.

The complete fingerprint includes the file-identity representation. Native leaves
can use a filesystem device/inode identity while Foundation leaves use a resource
identifier. Unequal fingerprints therefore require a field comparison before
attributing the difference to incorrect sizes or topology. Do not treat matching
totals alone as proof that every metadata field matches.

## Compare path-storage representations

Run each representation in a separate Release process for memory comparisons:

```sh
RADIX_BENCH_PATH_STORAGE=records \
swift test -c release --filter testPathStorageBenchmark

RADIX_BENCH_PATH_STORAGE=packed \
swift test -c release --skip-build --filter testPathStorageBenchmark
```

Both representations omit metadata and lookup indexes. Keep
`RADIX_BENCH_PATH_STORAGE_FILES` and `RADIX_BENCH_PATH_STORAGE_DEPTH` equal across
runs. The defaults are 200,000 leaves and depth zero.

## Interpret chart and cancellation measurements

Chart preparation and navigation both use `SunburstLayout.segments`. Chart
preparation adds `ChartReadProbe` instrumentation, so the timings measure
different work. Keep their purposes and results separate.

The browser and chart helpers share a cancellation result containing elapsed
seconds, cancellation status, and whether completion preceded cancellation.
The full-disk scaling benchmark has a separate result that also records worker
and pool shutdown. Its fields protect different lifecycle checks.

Elapsed times and memory reports are observations, not test thresholds. Most
measurement bodies skip unless enabled, but their sources still compile and the
tests remain discoverable. Gates include `RADIX_STARTUP_SCAN_REGRESSION` as well as
`RADIX_BENCH_*` variables.
