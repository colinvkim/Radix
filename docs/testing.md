# Testing Radix

Radix uses **Swift Testing for core logic and integration tests**. The core test
target is included in the shared `Radix` scheme and `Radix.xctestplan`. Swift
Testing ships with Xcode; there is no additional testing dependency.

## Running tests

Use Xcode 26+ with Swift 6.2+. Run commands from the checkout you want to test.

```sh
# Fast core feedback; parallel execution is the default.
swift test

# One suite or test. The filter is a regular expression.
swift test --filter ScanCoordinatorTests
swift test --filter CancellableSortTests/stableSortPreservesEveryElement

# Build the application and run core tests; also available with Cmd-U.
xcodebuild test -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data \
  -resultBundlePath .build/Tests.xcresult
```

Choose a fresh result-bundle path for each run; Xcode will not overwrite one.
When working through an agent, prefix routine build/test commands with `rtk` as
specified in `AGENTS.md`. CI uses the native commands without requiring that local
output wrapper.

The GitHub Actions workflow runs the SwiftPM suite and the complete Xcode plan on
macOS 26 with Xcode 26.6, and retains `.xcresult` reports and coverage. This checks
both the package source list and the actual app build.

## What belongs where

| Layer | Location | Responsibilities |
| --- | --- | --- |
| Core unit tests | `RadixCoreTests/` | Tree invariants, layout geometry, sorting, filtering, progress, navigation, preferences, and safety policy |
| Core integration tests | `RadixCoreTests/` | Real temporary files, scanning, hard links and clones, descriptors, rescans, archive validation, and cancellation |
| Opt-in benchmarks | `*BenchmarkTests.swift`, `ProgressAccuracyProbeTests.swift` | Timing and memory measurements on explicitly selected workloads |

Exercise observable results and invariants:
selected file paths, preserved bytes, retained snapshot contents, totals, ordering,
and cancellation cleanup. Test a bug's triggering scenario before fixing it. Avoid
catalog-size assertions, arbitrary sleeps, duplicated examples, and assertions
about incidental implementation details. Parameterize cases that share the same
setup and contract; keep separate tests for distinct failure modes and boundaries.

Swift Testing suites are value types with a fresh instance per test. Test cases
run concurrently, including cases within parameterized tests. Use unique fixture
paths and UserDefaults suites, local dependencies, and `defer` or fixture ownership
for cleanup. `@MainActor` models the code's isolation; it does not prevent suspended
tests from interleaving. Do not disable parallel execution to hide shared state.

For asynchronous work, hold and release fake-service responses explicitly, or
await an observable completion. `waitUntil` has a bounded watchdog, propagates
cancellation, and throws on timeout with the caller's source location. Its default
15-second allowance accommodates concurrent runs and coverage instrumentation;
it is not a performance target. An absence assertion needs a completion barrier:
releasing a fake response or calling `Task.yield()` alone does not prove that the
consumer has processed the response. Progress
throttling uses an injected test clock, so tests advance the deadline directly.
Cancellation probes cancel at worker/listing boundaries instead of assuming a
machine will still be busy after a delay. Keep filesystem behavior tests on real
files. Filesystem-dependent name and clone cases have explicit capability traits;
an unexpected fixture error fails the test.

The FSEvents integration test creates its fixture below this checkout's `.build`.
Keep the checkout outside `/tmp`, which macOS excludes from FSEvents reporting.

## Manual application QA

Application interactions are checked manually before release. Cover onboarding,
scan/search commands, navigation and rescan, discard-pile review, trash confirmation
and cancellation, and snapshot import/export restrictions. Also exercise native
folder/save panels, Full Disk Access, Quick Look, Sparkle, drag-and-drop, and layout.
Core tests exercise the underlying models and services; they do not automate the UI.

Follow `AGENTS.md`: stop other Radix instances and open this checkout's exact Debug
app, then use that full path for every Computer Use target.

## Benchmarks

Measurements carry `.tags(.benchmark)` and an `.enabled(if:)` trait naming the
required environment variable. Normal test runs report these as intentionally
skipped. Small correctness checks in benchmark files still run normally. Enabling
a benchmark with an invalid path or workload fails instead of silently skipping.

Run one benchmark at a time with `--no-parallel` to avoid competing measurements.
For example, this small synthetic workload also checks the tree-removal benchmark
harness without scanning user data:

```sh
RADIX_BENCH_TREE_REMOVAL=1 \
RADIX_BENCH_TREE_DIRECTORIES=4 \
RADIX_BENCH_TREE_FILES_PER_DIRECTORY=64 \
swift test --no-parallel --filter ScanBenchmarkTests/testTreeRemovalBenchmark
```

Inspect the relevant test's documented environment variables before enabling a
filesystem benchmark. Use `-c release` for representative timing unless the
measurement requires `#if DEBUG` diagnostic hooks. Do not use machine-dependent
timing thresholds as normal CI correctness gates. The cancellation-latency probe
uses a Swift Testing exit test with a subprocess watchdog so a deadlocked worker
cannot wedge the parent test runner.

## References

- [Apple: Swift Testing](https://developer.apple.com/documentation/testing)
- [GitHub: macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
